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
