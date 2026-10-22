///| M4 批次并发门面黑盒测试（DEVELOPMENT.md 6.6）。
///
/// 批次门面是 core 的自由函数（`@core.batch_write` / `@core.batch_search`），
/// 被测 `VectorStore` 用本地 `MemoryStore`（core 不得依赖 local，故测试放在 local 包）。
///
/// 覆盖：并发批量写条数正确、并发批量检索结果同序、失败传播（混入维度不符的点 →
/// 上抛 `InvalidArgument`）、并发度/批次参数校验、空输入。

///|
/// 造一批维度 2、id 从 `start` 起的点（payload 带索引）。
fn points_from(start : Int32, count : Int32) -> Array[@core.Point] {
  let out : Array[@core.Point] = []
  for i = 0; i < count; i = i + 1 {
    out.push(
      @core.Point::new(
        id=@core.PointId::of_int((start + i).to_uint64()),
        vector=[1.0, 0.0],
        payload={ "i": Json::number((start + i).to_double()) },
      ),
    )
  }
  out
}

///|
/// 收集集合内所有点的 ID（size=100 足够覆盖测试数据）。
async fn all_ids(
  store : &@core.VectorStore,
  collection : String,
) -> Array[@core.PointId] raise @core.VectorStoreError {
  let page = store.scroll(collection, @core.ScrollRequest::new(limit=200))
  let out : Array[@core.PointId] = []
  for point in page.points {
    out.push(point.id)
  }
  out
}

///|
async test "batch_write: 并发批量写入 120 点分 3 批，条数与去重正确" {
  let store = @local.MemoryStore::new()
  store.create_collection(
    "c",
    @core.VectorConfig::new(size=2, distance=@core.Euclid),
  )
  let points = points_from(0, 120)
  @core.batch_write(store, "c", points, batch_size=40, max_concurrent=3)
  let ids = all_ids(store, "c")
  inspect(ids.length(), content="120")
  // 无重复
  let keys : Array[Int32] = []
  for id in ids {
    match id {
      @core.Num(n) => keys.push(n.to_int())
      @core.Uuid(_) => ()
    }
  }
  keys.sort()
  inspect(keys[0], content="0")
  inspect(keys[119], content="119")
  inspect(keys.length(), content="120")
}

///|
async test "batch_write: 覆盖写同 ID 只保留最新值（串行化正确）" {
  let store = @local.MemoryStore::new()
  store.create_collection(
    "c",
    @core.VectorConfig::new(size=2, distance=@core.Euclid),
  )
  // 同一批里两个点 id 相同 → 后写覆盖前写，条数不增
  let overwritten = @core.Point::new(
    id=@core.PointId::of_int(7UL),
    vector=[2.0, 0.0],
    payload={ "v": Json::number(2.0) },
  )
  @core.batch_write(
    store,
    "c",
    points_from(0, 10),
    batch_size=3,
    max_concurrent=4,
  )
  @core.batch_write(store, "c", [overwritten], batch_size=1)
  let page = store.scroll("c", @core.ScrollRequest::new(limit=200))
  inspect(page.points.length(), content="10")
  let fetched = store.retrieve("c", [@core.PointId::of_int(7UL)], true, true)
  inspect(fetched.length(), content="1")
  inspect(fetched[0].vector == Some([2.0, 0.0]), content="true")
}

///|
async test "batch_search: 并发批量检索结果与请求同序" {
  let store = @local.MemoryStore::new()
  store.create_collection(
    "c",
    @core.VectorConfig::new(size=2, distance=@core.Euclid),
  )
  // 距离 [1,0] 不同的三点
  ignore(
    store.upsert(
      "c",
      [
        @core.Point::new(id=@core.PointId::of_int(1UL), vector=[1.0, 0.0]),
        @core.Point::new(id=@core.PointId::of_int(2UL), vector=[2.0, 0.0]),
        @core.Point::new(id=@core.PointId::of_int(3UL), vector=[3.0, 0.0]),
      ],
      true,
    ),
  )
  let req1 = @core.SearchRequest::new(vector=[1.0, 0.0], limit=1)
  let req2 = @core.SearchRequest::new(vector=[2.0, 0.0], limit=1)
  let results = @core.batch_search(store, "c", [req1, req2], max_concurrent=2)
  inspect(results.length(), content="2")
  inspect(results[0][0].id == @core.PointId::of_int(1UL), content="true")
  inspect(results[1][0].id == @core.PointId::of_int(2UL), content="true")
}

///|
async test "batch_write: 混入维度不符的点 → 上抛第一个 InvalidArgument，且不影响已成功子批" {
  let store = @local.MemoryStore::new()
  store.create_collection(
    "c",
    @core.VectorConfig::new(size=2, distance=@core.Euclid),
  )
  let good1 = @core.Point::new(id=@core.PointId::of_int(1UL), vector=[1.0, 0.0])
  let bad = @core.Point::new(id=@core.PointId::of_int(2UL), vector=[
    1.0, 2.0, 3.0,
  ]) // 维度 3
  let good2 = @core.Point::new(id=@core.PointId::of_int(3UL), vector=[1.0, 0.0])
  let kind = try {
    @core.batch_write(
      store,
      "c",
      [good1, bad, good2],
      batch_size=1,
      max_concurrent=3,
    )
    "no-error"
  } catch {
    @core.VectorStoreError::InvalidArgument(_) => "InvalidArgument"
    @core.VectorStoreError::Transport(_) => "Transport"
    _ => "other"
  }
  inspect(kind, content="InvalidArgument")
  // 其余子批次仍已写入（batch 不整体原子）
  let ids = all_ids(store, "c")
  inspect(ids.length(), content="2")
}

///|
async test "batch_write/batch_search: 参数校验与空输入" {
  let store = @local.MemoryStore::new()
  store.create_collection(
    "c",
    @core.VectorConfig::new(size=2, distance=@core.Euclid),
  )

  let bad_size = try {
    @core.batch_write(store, "c", points_from(0, 3), batch_size=0)
    "no-error"
  } catch {
    @core.VectorStoreError::InvalidArgument(_) => "InvalidArgument"
    _ => "other"
  }
  inspect(bad_size, content="InvalidArgument")

  let bad_conc = try {
    @core.batch_write(
      store,
      "c",
      points_from(0, 3),
      batch_size=2,
      max_concurrent=0,
    )
    "no-error"
  } catch {
    @core.VectorStoreError::InvalidArgument(_) => "InvalidArgument"
    _ => "other"
  }
  inspect(bad_conc, content="InvalidArgument")

  // 空输入：直接成功
  @core.batch_write(store, "c", [], batch_size=10)
  let empty = @core.batch_search(store, "c", [])
  inspect(empty.length(), content="0")
}
