///| M3 远端后端黑盒测试（DEVELOPMENT.md 8）。
///
/// 依赖一个运行中的 Qdrant 桩或真实 Qdrant：地址来自 `QDRANT_URL` 环境变量，
/// 缺省 `http://127.0.0.1:6333`（本地桩 `tests/stub/qdrant_stub.py`）。
/// 若地址不可连（无桩、无 Docker），本地测试**跳过**（12.2：集成测试可跳过）；
/// CI 拉真实 Qdrant 容器并设置 `QDRANT_URL`。
///
/// 原生目标专用：remote 是 `supported_targets="native"`，此文件在 js/wasm 下被
/// 构建排除，不会造成跨目标阻塞。

///|
/// 目标 URL：优先 `QDRANT_URL`，缺省本地桩默认端口。
fn qdrant_url() -> String {
  match @env.get_env_var("QDRANT_URL") {
    Some(url) => url
    None => "http://127.0.0.1:6333"
  }
}

///|
/// 连通性探测：用一个无害的 `collection_exists` 在随机集合名上试连。
/// 只有 `Transport` / `Timeout` 表明服务不可达（404 / 5xx 都说明服务在）。
async fn reachable(url : String) -> Bool {
  let store = @remote.QdrantStore::new(url~)
  let probed_name = "__probe_\{@env.now().to_string()}"
  let kind = try {
    ignore(store.collection_exists(probed_name))
    "reachable"
  } catch {
    @core.VectorStoreError::Transport(_) => "unreachable"
    @core.VectorStoreError::Timeout(_) => "unreachable"
    _ => "reachable"
  }
  kind == "reachable"
}

///|
/// 把失败列表拼成一段错误信息。
fn join_lines(lines : Array[String]) -> String {
  let mut out = ""
  for line in lines {
    out = out + line + "\n"
  }
  out
}

///|
async test "remote：一致性套件 C1–C15" {
  let url = qdrant_url()
  // 无桩 / 无 Qdrant 时跳过（12.2：集成测试可跳过），保证本地无 Docker 也能跑 `moon test`
  if false == reachable(url) {
    return
  }
  let store : &@core.VectorStore = @remote.QdrantStore::new(url~)
  let failures = @conformance.run_conformance(store, "remote")
  if failures.length() > 0 {
    fail(join_lines(failures))
  }
  inspect(failures.length(), content="0")
}

///|
/// Q15 实测（方案 A）：`scroll` 的 `offset` 指向**已被删除**的点时，
/// Qdrant 的真实行为是「软删除位图 + 按 id 续扫，不报错」。
/// 本用例在桩（tests/stub）与真实 Qdrant（CI integration）上都跑，
/// 断言 Qdrant 侧行为，用于回写 README 第 7 条已知差异声明。
///
/// 注意：本用例是 remote 专属。local 后端按 Q15 定稿报 `InvalidArgument`，
/// 因此不能放进共享一致性套件（否则两端强制一致会让 local 失败）。
async test "remote：Q15 实测——offset 指向已删除点的续扫行为" {
  let url = qdrant_url()
  if false == reachable(url) {
    return
  }
  let store : &@core.VectorStore = @remote.QdrantStore::new(url~)
  let name = "__q15_\{@env.now().to_string()}"
  ignore(store.create_collection(name, @core.VectorConfig::new(size=2, distance=@core.Euclid)))
  defer { ignore(store.delete_collection(name) catch { _ => () }) }
  let points : Array[@core.Point] = [
    @core.Point::new(id=@core.PointId::of_int(1UL), vector=[0.0, 0.0]),
    @core.Point::new(id=@core.PointId::of_int(2UL), vector=[1.0, 1.0]),
    @core.Point::new(id=@core.PointId::of_int(3UL), vector=[2.0, 2.0]),
    @core.Point::new(id=@core.PointId::of_int(4UL), vector=[3.0, 3.0]),
  ]
  ignore(store.upsert(name, points, true))
  // 第 1 页 limit=2：应返回 id 1、2，next_offset 指向 id 2
  let first = store.scroll(name, @core.ScrollRequest::new(limit=2))
  let first_nonempty = first.points.length() == 2
  // 删除 offset 指向的 id 2，再用原 offset 续扫
  ignore(store.delete_points(name, [@core.PointId::of_int(2UL)]))
  let second = store.scroll(name, @core.ScrollRequest::new(limit=2, offset=@core.PointId::of_int(2UL)))
  // Qdrant 行为断言：续扫不报错，从「id 大于 offset」的第一个存活点（id 3）继续。
  // 若此断言失败，说明 Qdrant 实际行为与 README 第 7 条声明不符，需回写声明。
  let second_ids = {
    let mut acc = ""
    for p in second.points {
      match p.id {
        @core.PointId::Num(n) => acc = acc + n.to_string() + ","
        @core.PointId::Uuid(s) => acc = acc + s + ","
      }
    }
    acc
  }
  let continued_from_3 = second.points.length() == 2 && second.points[0].id == @core.PointId::of_int(3UL)
  if first_nonempty == false || continued_from_3 == false {
    fail("Q15 实测：offset 指向已删除点后续扫与 README 声明不符：first_nonempty=\{first_nonempty} second_ids=\{second_ids}")
  } else {
    inspect(second_ids, content="3,4,")
  }
}
