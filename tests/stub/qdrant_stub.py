#!/usr/bin/env python3
"""Qdrant 本地 HTTP 桩（DEVELOPMENT.md 12.2 / ADR-12）。

用于在无 Docker 的开发机上验证远端后端（M3），复刻 Qdrant 的响应形状：
- 三种 `result` 包裹层（数组 / {points,..} / {points,next_page_offset}）
- 404 错误体 `{"status":{"error":..}}`
- 503 / 慢响应（供重试 / 超时测试）

只实现 `tests/integration/` 真正断言用到的端点；其余端点一律 501。

运行：`python tests/stub/qdrant_stub.py [port]`（默认 6333）。

注意：本桩是**内存态**，重启即清空；且只在单线程 basehttp 下工作，响应体内若含
`next_page_offset` 用与 Qdrant 相同的键名。
"""

import json
import math
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 内存：collection -> {"config":.., "points": {id_str: {"id":..,"vector":..,"payload":..}}}
COLLECTIONS = {}

# 慢响应路径（供超时测试）：路径前缀 -> 延迟毫秒
SLOW_MS = 1500


def _metric_to_name(d):
    # 我们发的是 "Cosine"/"Euclid"/...（@json.to_json(Distance)），直接透传
    return d


def _collection_or_404(handler, name):
    col = COLLECTIONS.get(name)
    if col is None:
        # 模拟真实 Qdrant：请求 Accept-Encoding 含 gzip 时，错误响应声明
        # Content-Encoding: gzip 但 body 未压缩（Qdrant 错误路径不压缩）。
        # @http 若启用自动解压会对明文 inflate → InvalidBlock("empty huffman tree")。
        ae = handler.headers.get("Accept-Encoding", "")
        declared = "gzip" in ae
        handler._send(404, {"status": {"error": f"Collection `{name}` doesn't exist!"}, "time": time.time(), "result": None}, gzip_declared=declared)
        return None
    return col


class Handler(BaseHTTPRequestHandler):
    # 真实 Qdrant 用 HTTP/1.1（keep-alive）。BaseHTTPRequestHandler 默认 HTTP/1.0 会在
    # 每次响应后关闭连接，MoonBit 客户端写请求体时对此处理不佳（M3 实测，PUT/POST 会
    # ReaderClosed）。用 HTTP/1.1 更贴近真实端，也让客户端读写行为与真实 Qdrant 一致。
    protocol_version = "HTTP/1.1"

    def _send(self, code, payload, gzip_declared=False):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        if gzip_declared:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        """读取请求体，同时支持 Content-Length 与 chunked Transfer-Encoding。

        MoonBit 的 @http 客户端写请求体时默认走 chunked（write 后 end_request，
        Content-Length/Transfer-Encoding 由库自动管理，见 async/client.mbt）。"""
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks = []
            while True:
                size_line = self.rfile.readline().strip()
                size = int(size_line.split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline()  # 吃掉尾部空行
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)  # \r\n
            return b"".join(chunks)
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b""

    def _read_json(self):
        raw = self._read_body()
        try:
            return json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return {}

    def _path_parts(self):
        return [p for p in self.path.split("?")[0].split("/") if p]

    # 所有方法统一走 _route
    def do_GET(self): self._route("GET")
    def do_PUT(self): self._route("PUT")
    def do_POST(self): self._route("POST")
    def do_DELETE(self): self._route("DELETE")

    def _route(self, method):
        # 慢响应：命中路径前缀则先自旋
        if self.path.startswith("/slow"):
            time.sleep(SLOW_MS / 1000.0)
            self._send(503, {"status": {"error": "simulated slowness"}, "time": time.time(), "result": None})
            return

        # 503 通道：POST /_fail503 之后，下一个请求返回 503（供重试测试）
        parts = self._path_parts()
        if method == "POST" and parts == ["_fail503"]:
            setattr(self.server, "_fail_next", True)
            self._send(200, {"status": "ok", "time": time.time(), "result": None})
            return
        if getattr(self.server, "_fail_next", False):
            setattr(self.server, "_fail_next", False)
            self._send(503, {"status": {"error": "simulated 503"}, "time": time.time(), "result": None})
            return

        # 集合 CRUD
        if parts and parts[0] == "collections":
            if len(parts) == 1:
                self._send(200, {"status": "ok", "time": time.time(), "result": {}})
                return
            name = parts[1]
            if len(parts) == 2:
                return self._collection_ops(method, name)
            if parts[2] == "index":
                return self._index_ops(method, name)
            if parts[2] == "points":
                return self._points_ops(method, name, parts[3:])
            self._send(501, {"status": {"error": "not implemented"}, "time": time.time(), "result": None})
            return
        self._send(501, {"status": {"error": "not implemented"}, "time": time.time(), "result": None})

    def _collection_ops(self, method, name):
        if method == "PUT":
            # create_collection：同配置幂等，异配置 409（Q4 定稿：配置不一致报 Conflict）
            body = self._read_json()
            size = body["vectors"]["size"]
            dist = body["vectors"]["distance"]
            if name in COLLECTIONS:
                cfg = COLLECTIONS[name]["config"]
                if cfg["size"] != size or cfg["distance"] != dist:
                    self._send(409, {"status": {"error": "Collection already exists!"}, "time": time.time(), "result": None})
                    return
                self._send(200, {"status": "ok", "time": time.time(), "result": False})
                return
            COLLECTIONS[name] = {"config": {"size": size, "distance": dist, "on_disk": body["vectors"].get("on_disk", False)}, "points": {}}
            self._send(200, {"status": "ok", "time": time.time(), "result": True})
        elif method == "GET":
            col = _collection_or_404(self, name)
            if col is None: return
            self._send(200, {
                "status": "ok",
                "time": time.time(),
                "result": {
                    "config": {
                        "params": {
                            "vectors": {
                                "size": col["config"]["size"],
                                "distance": col["config"]["distance"],
                                "on_disk": col["config"]["on_disk"],
                            }
                        }
                    }
                },
            })
        elif method == "DELETE":
            _collection_or_404(self, name)
            if name in COLLECTIONS:
                del COLLECTIONS[name]
            self._send(200, {"status": "ok", "time": time.time(), "result": True})
        else:
            self._send(405, {"status": {"error": "method not allowed"}, "time": time.time(), "result": None})

    def _index_ops(self, method, name):
        _collection_or_404(self, name)
        if method == "PUT":
            self._send(200, {"status": "ok", "time": time.time(), "result": True})
        else:
            self._send(405, {"status": {"error": "method not allowed"}, "time": time.time(), "result": None})

    def _points_ops(self, method, name, sub):
        col = _collection_or_404(self, name)
        if col is None: return
        body = self._read_json()

        # PUT /points?wait=.. → upsert
        if method == "PUT":
            size = col["config"]["size"]
            for point in body["points"]:
                if len(point.get("vector", [])) != size:
                    self._send(400, {"status": {"error": f"Vector dimension does not match collection dimension {size}"}, "time": time.time(), "result": None})
                    return
            for point in body["points"]:
                pid = point["id"]
                point.setdefault("payload", {})  # 与 Qdrant 一致：无 payload 存为 {}
                col["points"][str(pid)] = point
            self._send(200, {"status": "ok", "time": time.time(), "result": {"status": "ok"}})
            return

        if method == "POST":
            if sub == ["delete"]:
                # delete by ids 或 by filter（有 filter/points 键区分）
                if "points" in body:
                    for pid in body["points"]:
                        col["points"].pop(str(pid), None)
                elif "filter" in body:
                    doomed = []
                    f = body["filter"]
                    for pid, p in col["points"].items():
                        if _matches(f, p):
                            doomed.append(pid)
                    for pid in doomed:
                        col["points"].pop(pid, None)
                self._send(200, {"status": "ok", "time": time.time(), "result": {"status": "ok"}})
                return
            if sub == ["query"]:
                # search：先按 filter 过滤，再算距离、排序、阈值、截断
                vec = [float(x) for x in body["query"]]
                metric = col["config"]["distance"]
                filt = body.get("filter")
                hits = []
                for pid, p in col["points"].items():
                    if filt and not _matches(filt, p):
                        continue
                    pv = [float(x) for x in p["vector"]]
                    if metric == "Cosine":
                        score = _cosine(vec, pv)
                    elif metric == "Dot":
                        score = _dot(vec, pv)
                    elif metric == "Manhattan":
                        score = sum(abs(a - b) for a, b in zip(vec, pv))
                    else:
                        score = _dist(vec, pv)
                    if "score_threshold" in body:
                        # 与 Qdrant 一致：阈值严格比较（恰等于阈值的点被排除，2026-10-22 实测）
                        if metric in ("Euclid", "Manhattan"):
                            if score >= body["score_threshold"]:
                                continue
                        else:
                            if score <= body["score_threshold"]:
                                continue
                    hit = {"id": p["id"], "score": score}
                    if body.get("with_payload", True):
                        hit["payload"] = _payload_of(p)
                    if body.get("with_vector", False):
                        hit["vector"] = p["vector"]
                    hits.append(hit)
                hits.sort(key=lambda h: h["score"])
                limit = body.get("limit", 10)
                self._send(200, {"status": "ok", "time": time.time(), "result": {"points": hits[:limit]}})
                return
            if sub == ["scroll"]:
                ids = list(col["points"].keys())
                # 插入序：points dict 保持写入顺序（Python 3.7+），filter 后仍需保持
                filtered = [i for i in ids if _matches(body.get("filter", {}), col["points"][i]) or not body.get("filter")]
                start = 0
                if "offset" in body:
                    off = str(body["offset"])
                    for j, i in enumerate(filtered):
                        if i == off:
                            start = j + 1
                            break
                limit = body.get("limit", 10)
                page_ids = filtered[start:start + limit]
                points_out = []
                for i in page_ids:
                    p = col["points"][i]
                    sp = {"id": p["id"]}
                    if body.get("with_payload", True):
                        sp["payload"] = _payload_of(p)
                    if body.get("with_vector", False):
                        sp["vector"] = p["vector"]
                    points_out.append(sp)
                nxt = (col["points"][page_ids[-1]]["id"] if (start + limit) < len(filtered) and page_ids else None)
                self._send(200, {"status": "ok", "time": time.time(), "result": {"points": points_out, "next_page_offset": nxt}})
                return
            if sub == []:
                # retrieve
                out = []
                for pid in body.get("ids", []):
                    p = col["points"].get(str(pid))
                    if p is None:
                        continue
                    sp = {"id": p["id"]}
                    if body.get("with_payload", True):
                        sp["payload"] = _payload_of(p)
                    if body.get("with_vector", False):
                        sp["vector"] = p["vector"]
                    out.append(sp)
                self._send(200, {"status": "ok", "time": time.time(), "result": out})
                return
        self._send(501, {"status": {"error": "not implemented"}, "time": time.time(), "result": None})


def _dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def _payload_of(p):
    # 与 Qdrant 一致：无 payload 的点持久化为空对象 {}，响应不再出现 null
    return p.get("payload") or {}


def _dist(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


def _cosine(a, b):
    la = sum(x * x for x in a) ** 0.5
    lb = sum(x * x for x in b) ** 0.5
    if la == 0 or lb == 0:
        return 0.0
    return _dot(a, b) / (la * lb)


def _values_at(payload, key):
    """路径取值：点号嵌套 + `[]` 展开一层（与 local/path.mbt 一致的子集）。"""
    cur = [payload]
    for seg in key.split("."):
        expand = seg.endswith("[]")
        name = seg[:-2] if expand else seg
        nxt = []
        for v in cur:
            if isinstance(v, dict) and name in v:
                nxt.append(v[name])
        if expand:
            exp = []
            for v in nxt:
                if isinstance(v, list):
                    exp.extend(v)
            nxt = exp
        cur = nxt
    return cur


def _scalars(v):
    return v if isinstance(v, list) else [v]


def _any_equals(candidates, expected):
    for c in candidates:
        for s in _scalars(c):
            if s == expected:
                return True
    return False


def _matches(f, point):
    """复刻 local/filter_eval.mbt 的过滤语义（9.6），供一致性套件 C7–C11、C13 通过。"""
    if not f:
        return True
    payload = point.get("payload", {})
    if "must" in f:
        for c in f["must"]:
            if not _clause(c, payload):
                return False
    if "should" in f and f["should"]:
        matched = False
        for c in f["should"]:
            if _clause(c, payload):
                matched = True
        if not matched:
            return False
    if "must_not" in f:
        for c in f["must_not"]:
            if _clause(c, payload):
                return False
    return True


def _matches_string(candidates, needle):
    needle = needle.lower()
    for c in candidates:
        if isinstance(c, str) and needle in c.lower():
            return True
    return False


def _within_bounds(v, spec):
    if "gt" in spec and v <= spec["gt"]: return False
    if "gte" in spec and v < spec["gte"]: return False
    if "lt" in spec and v >= spec["lt"]: return False
    if "lte" in spec and v > spec["lte"]: return False
    return True


def _clause(c, payload):
    if "has_id" in c:
        return True  # has_id 由调用方用 retrieve/ids 校验，桩不深究（本地也不看 payload）
    # 嵌套 Filter（Clause::Group）：元素自带 must/should/must_not。
    # 注意：_matches 期望「点」结构（含 payload 字段），这里已有 payload，
    # 故内联求值而不是调用 _matches（否则 payload 被当 point 取不到 → 恒 False）。
    if "must" in c or "should" in c or "must_not" in c:
        if "must" in c:
            for cc in c["must"]:
                if not _clause(cc, payload):
                    return False
        if "should" in c and c["should"]:
            if not any(_clause(cc, payload) for cc in c["should"]):
                return False
        if "must_not" in c:
            for cc in c["must_not"]:
                if _clause(cc, payload):
                    return False
        return True
    key = c.get("key")
    if "match" in c:
        m = c["match"]
        cands = _values_at(payload, key)
        if not cands:
            return False
        if "value" in m:
            return _any_equals(cands, m["value"])
        if "any" in m:
            return any(_any_equals(cands, e) for e in m["any"])
        if "except" in m:
            return not any(_any_equals(cands, e) for e in m["except"])
        if "text" in m:
            return _matches_string(_values_at(payload, key), m["text"])
        return False
    if "range" in c:
        cands = _values_at(payload, key)
        if not cands:
            return False
        spec = c["range"]
        for cand in cands:
            for s in _scalars(cand):
                if isinstance(s, (int, float)) and _within_bounds(float(s), spec):
                    return True
        return False
    if "is_null" in c:
        expect = c["is_null"]
        cands = _values_at(payload, key)
        if not cands:
            # 与 Qdrant 对齐（2026-10-22）：缺字段 is_null(true) 不命中、(false) 命中
            return not expect
        nullish = any(s is None for s in _scalars(cands))
        return nullish == expect
    if "is_empty" in c:
        expect = c["is_empty"]
        cands = _values_at(payload, key)
        if not cands:
            # 与 Qdrant 对齐：缺字段视为「空」，is_empty(true) 命中
            return expect
        empty = any((isinstance(s, list) and len(s) == 0) or
                    (isinstance(s, dict) and len(s) == 0) or
                    (s is None) for s in _scalars(cands))
        return empty == expect
    if "values_count" in c:
        spec = c["values_count"]
        cands = _values_at(payload, key)
        if not cands:
            return False
        for cand in cands:
            n = len(cand) if isinstance(cand, (list, dict)) else None
            if n is not None and _within_bounds(n, spec):
                return True
        return False
    if "geo_bounding_box" in c or "geo_radius" in c:
        cands = _values_at(payload, key)
        if not cands:
            return False
        for cand in cands:
            for s in _scalars(cand):
                gp = s if (isinstance(s, dict) and "lat" in s and "lon" in s) else None
                if gp is None:
                    continue
                geolat = float(gp["lat"]); geolon = float(gp["lon"])
                if "geo_bounding_box" in c:
                    bb = c["geo_bounding_box"]
                    tl = bb["top_left"]; br = bb["bottom_right"]
                    # 与 local/filter_eval.mbt 一致：br.lat<=lat<=tl.lat, tl.lon<=lon<=br.lon
                    if br["lat"] <= geolat <= tl["lat"] and tl["lon"] <= geolon <= br["lon"]:
                        return True
                else:
                    r = c["geo_radius"]
                    ct = r["center"]
                    if _haversine(float(ct["lat"]), float(ct["lon"]), geolat, geolon) <= r["radius"]:
                        return True
        return False
    return True


def _haversine(lat1, lon1, lat2, lon2):
    # 与 local 的 haversine 一致（地球半径 6371000 m）
    to_rad = math.pi / 180.0
    half_dlat = (lat2 - lat1) * to_rad / 2.0
    half_dlon = (lon2 - lon1) * to_rad / 2.0
    a = math.sin(half_dlat) ** 2 + math.cos(lat1 * to_rad) * math.cos(lat2 * to_rad) * math.sin(half_dlon) ** 2
    a = min(1.0, a)
    return 2.0 * 6371000.0 * math.atan2(a ** 0.5, (1.0 - a) ** 0.5)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 6333
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"qdrant stub listening on 127.0.0.1:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()