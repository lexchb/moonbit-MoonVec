///| M2 公共 API 守门测试（黑盒）。
///
/// 与 M1 的 `core/store_test.mbt` 同一条纪律（12.1 纪律 4）：**在独立包**里用
/// `@local.` / `@core.` 限定名把公共面构造、调用、匹配一遍。MoonBit 的默认可见性是
/// readonly，同包内一切正常、只有跨包使用才暴露问题，所以这层测试不能省。
///
/// 本文件覆盖 M2 新增的公共面：`MemoryStore` 的构造、11 个方法的方法语法（ADR-10 的
/// `extend` 声明是否真的生效）、以及一致性套件的入口。

///|
/// 把失败列表拼成一段文本，便于在测试输出里一次看全。
fn join_lines(lines : Array[String]) -> String {
  let mut out = ""
  for line in lines {
    out = out + line + "\n"
  }
  out
}

///|
async test "MemoryStore：11 个方法都能用方法语法调用" {
  let store = @local.MemoryStore::new()
  store.create_collection(
    "docs",
    @core.VectorConfig::new(size=2, distance=@core.Cosine),
  )
  inspect(store.collection_exists("docs"), content="true")
  inspect(store.describe_collection("docs").size, content="2")

  let payload : @core.Payload = Map([
    ("k", Json::string("v")),
    ("n", Json::number(1.0)),
  ])
  let result = store.upsert(
    "docs",
    [
      @core.Point::new(
        id=@core.PointId::of_int(1UL),
        vector=[1.0, 0.0],
        payload~,
      ),
    ],
    true,
  )
  inspect(result == @core.All, content="true")

  let hits = store.search(
    "docs",
    @core.SearchRequest::new(vector=[1.0, 0.0], limit=1),
  )
  inspect(hits.length(), content="1")
  // 只有写入的向量被要求返回时才填充
  inspect(hits[0].vector == None, content="true")

  let page = store.scroll("docs", @core.ScrollRequest::new(limit=10))
  inspect(page.points.length(), content="1")
  inspect(page.next_offset == None, content="true")

  let fetched = store.retrieve("docs", [@core.PointId::of_int(1UL)], true, true)
  inspect(fetched.length(), content="1")
  inspect(fetched[0].vector == Some([1.0, 0.0]), content="true")

  store.create_payload_index("docs", "k", @core.PayloadSchema::Keyword)
  store.delete_by_filter("docs", @core.Filter::empty())
  // 空 Filter 语义为「匹配全部」（7.3）
  inspect(
    store.scroll("docs", @core.ScrollRequest::new(limit=10)).points.length(),
    content="0",
  )

  store.delete_points("docs", [@core.PointId::of_int(1UL)])
  store.delete_collection("docs")
  inspect(store.collection_exists("docs"), content="false")
}

///|
async test "MemoryStore：错误可用具名 suberror 精确分辨" {
  let store = @local.MemoryStore::new()
  let kind = try {
    ignore(store.describe_collection("nope"))
    "no-error"
  } catch {
    @core.VectorStoreError::NotFound(resource~) => "NotFound:\{resource}"
    @core.VectorStoreError::InvalidArgument(message~) =>
      "InvalidArgument:\{message}"
    _ => "other"
  }
  inspect(kind, content="NotFound:collection:nope")
}

///|
async test "一致性套件 C1–C16：local 后端全绿" {
  let store : &@core.VectorStore = @local.MemoryStore::new()
  let failures = @conformance.run_conformance(store, "local_conformance")
  if failures.length() > 0 {
    fail(join_lines(failures))
  }
  inspect(failures.length(), content="0")
}
