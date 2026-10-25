///| MoonVec 快速开始示例：本地内存后端，无需 Docker / 外部服务。
///
/// 运行方式（native，示例使用 async 运行时）：
///   moon run examples/local_demo
///
/// 覆盖流程：建集合 → 写入 → 相似度检索 → 过滤 → 分页 → 删除，
/// 与 README「快速开始」一致，另演示批量写入门面 `batch_write`。

///|
/// 构造一条点：id、3 维向量、可选 payload。
fn point(id : UInt64, tag : String, n : Double) -> @core.Point {
  @core.Point::new(
    id=@core.PointId::of_int(id),
    vector=[1.0, 0.0, 0.0],
    payload=Map([("tag", Json::string(tag)), ("n", Json::number(n))]),
  )
}

///|
/// PointId 没有 Show 实现（core 只 derive Eq/Hash），这里手写可读文本。
fn id_text(id : @core.PointId) -> String {
  match id {
    @core.Num(n) => "num:\{n}"
    @core.Uuid(s) => "uuid:\{s}"
  }
}

///|
async fn main {
  // 1. 构造纯内存后端（零依赖，跨 native / js / wasm）
  let store = @local.MemoryStore::new()

  // 2. 建集合：3 维，Cosine 度量；同名且配置一致则幂等成功
  store.create_collection(
    "demo",
    @core.VectorConfig::new(size=3, distance=@core.Cosine),
  )
  println("collection exists: \{store.collection_exists("demo")}")

  // 3. 写入一批带 payload 的点
  let result = store.upsert(
    "demo",
    [point(1UL, "rust", 1.0), point(2UL, "go", 2.0), point(3UL, "rust", 3.0)],
    true,
  )
  let result_text = match result {
    @core.All => "All"
    @core.Partial(_) => "Partial"
  }
  println("upsert result: \{result_text}")

  // 4. 相似度检索：top-2，无过滤
  let hits = store.search(
    "demo",
    @core.SearchRequest::new(vector=[1.0, 0.1, 0.0], limit=2),
  )
  for hit in hits {
    println("hit id=\{id_text(hit.id)} score=\{hit.score}")
  }

  // 5. 过滤检索：tag = "rust"
  let filtered = store.search(
    "demo",
    @core.SearchRequest::new(
      vector=[1.0, 0.1, 0.0],
      limit=10,
      filter=@core.Filter::new(must=[
        @core.Clause::from_condition(@core.Condition::match_str("tag", "rust")),
      ]),
    ),
  )
  println("filtered (tag=rust): \{filtered.length()}")

  // 6. 分页遍历（不承诺全局顺序，只承诺不重不漏）
  let page = store.scroll("demo", @core.ScrollRequest::new(limit=2))
  println("scroll first page: \{page.points.length()} points")

  // 7. 批量写入门面：120 个点分 3 批、最多 2 并发
  let batch : Array[@core.Point] = []
  for i = 0; i < 120; i = i + 1 {
    batch.push(
      @core.Point::new(id=@core.PointId::of_int((100 + i).to_uint64()), vector=[
        0.0, 1.0, 0.0,
      ]),
    )
  }
  @core.batch_write(store, "demo", batch, batch_size=40, max_concurrent=2)

  // 8. 按过滤条件删除
  store.delete_by_filter(
    "demo",
    @core.Filter::new(must=[
      @core.Clause::from_condition(@core.Condition::match_str("tag", "go")),
    ]),
  )

  let left = store.scroll("demo", @core.ScrollRequest::new(limit=500))
  println("remaining points: \{left.points.length()}")
}
