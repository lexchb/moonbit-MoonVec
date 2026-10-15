///| 纯内存向量后端（DEVELOPMENT.md 9）。零外部依赖，可在 native / js / wasm 上运行。

///|
/// 单个集合的内存表示。
/// `points` 自身承载插入序（scroll 的游标语义依赖它），`index` 提供 O(1) 定位。
priv struct MemCollection {
  config : @core.VectorConfig
  points : Array[@core.Point]
  index : Map[@core.PointId, Int]
}

///|
fn MemCollection::new(config : @core.VectorConfig) -> MemCollection {
  { config, points: [], index: Map([]), }
}

///|
/// 重建 ID → 下标索引。删除点会打乱其后所有点的下标，故删除后必须重建（9.1）。
/// 只改 Map 内部，不重新赋值字段，因此不需要 `mut self`。
fn MemCollection::reindex(self : MemCollection) -> Unit {
  self.index.clear()
  for i = 0; i < self.points.length(); i = i + 1 {
    self.index.set(self.points[i].id, i)
  }
}

///|
/// 纯内存后端。
///
/// 字段是 `priv`：外部只能通过 `MemoryStore::new()` 构造，碰不到锁与内部集合。
/// 内部持有 `@async.Mutex`，11 个方法统一 `acquire` + `defer release`（9.4）。
pub(all) struct MemoryStore {
  priv lock : @async.Mutex
  priv collections : Map[String, MemCollection]
}

///|
/// 构造一个空后端。**不引入任何 IO 依赖**，因此可在 `js` / `wasm` 下实例化（4.2 / 9.4）。
pub fn MemoryStore::new() -> MemoryStore {
  { lock: @async.Mutex(), collections: Map([]), }
}

///|
fn collection_not_found(name : String) -> @core.VectorStoreError {
  @core.VectorStoreError::NotFound(resource="collection:\{name}")
}

///|
/// 求值用 payload：点没带 payload 时给一个空 Map，而不是 `None`，
/// 这样过滤求值只需处理一种形态。
fn payload_or_empty(point : @core.Point) -> @core.Payload {
  if point.payload is Some(payload) {
    payload
  } else {
    Map([])
  }
}

///|
/// `with_payload = false` → `None`；`true` → `Some(自身 payload，缺省为空 Map)`。
/// 缺省返回空 Map 而不是 `None`：与 Qdrant 返回 `{}` 的行为一致（9.3）。
fn payload_field(point : @core.Point, with_payload : Bool) -> @core.Payload? {
  if with_payload {
    Some(payload_or_empty(point))
  } else {
    None
  }
}

///|
fn vector_field(point : @core.Point, with_vector : Bool) -> @core.Vector? {
  if with_vector {
    Some(point.vector)
  } else {
    None
  }
}

///|
fn scored_point_of(
  point : @core.Point,
  score : Double,
  with_payload : Bool,
  with_vector : Bool,
) -> @core.ScoredPoint {
  {
    id: point.id,
    score,
    payload: payload_field(point, with_payload),
    vector: vector_field(point, with_vector),
  }
}

///|
fn stored_point_of(
  point : @core.Point,
  with_payload : Bool,
  with_vector : Bool,
) -> @core.StoredPoint {
  {
    id: point.id,
    payload: payload_field(point, with_payload),
    vector: vector_field(point, with_vector),
  }
}

///|
/// 检索排序的中间表示。用具名结构体而不是裸 tuple：字段名可读，也便于在调试器里看。
priv struct Ranked {
  point : @core.Point
  score : Double
}

///|
fn compare_double(a : Double, b : Double) -> Int {
  if a < b {
    -1
  } else if a > b {
    1
  } else {
    0
  }
}

///|
/// ID 的确定性次序：数字在前（按数值升序），UUID 在后（按字典序）。
/// 仅在分数相同、需要打破并列时使用（9.3），使本地后端的结果完全可复现。
fn compare_point_id(a : @core.PointId, b : @core.PointId) -> Int {
  match (a, b) {
    (@core.Num(x), @core.Num(y)) =>
      if x < y {
        -1
      } else if x > y {
        1
      } else {
        0
      }
    (@core.Uuid(x), @core.Uuid(y)) => x.compare(y)
    (@core.Num(_), @core.Uuid(_)) => -1
    (@core.Uuid(_), @core.Num(_)) => 1
  }
}

///|
fn compare_ranked(a : Ranked, b : Ranked) -> Int {
  let by_score = compare_double(a.score, b.score)
  if by_score != 0 {
    by_score
  } else {
    compare_point_id(a.point.id, b.point.id)
  }
}

///|
/// `MemoryStore` 对 `VectorStore` 的实现。
///
/// 每个方法都是 `acquire` + `defer release`：`defer` 在临界区抛错展开时**确实会**
/// 释放锁，这一点由 `lock_wbtest.mbt` 实测锁死（ADR-18）；否则一次失败的调用就会
/// 永久占住锁，症状是后续操作挂死。
///
/// 另一个硬要求：**临界区内不含 `suspend` 点**（不调用任何 async 函数），因此协作式
/// 调度下临界区是原子的；需要「先校验后落盘」的方法都把校验放在变更之前，
/// 以免失败的调用留下写了一半的状态。
pub impl @core.VectorStore for MemoryStore with fn create_collection(
  self,
  name,
  config,
) {
  self.lock.acquire()
  defer self.lock.release()
  if config.size < 1 {
    raise @core.VectorStoreError::InvalidArgument(
      message="集合维度必须 ≥ 1，收到 \{config.size}",
    )
  }
  if self.collections.get(name) is Some(existing) {
    // Q4 定稿：配置一致则幂等成功，不一致才算冲突
    guard existing.config == config else {
      raise @core.VectorStoreError::Conflict(
        message="集合 \{name} 已存在且配置不同",
      )
    }
  } else {
    self.collections.set(name, MemCollection::new(config))
  }
}

///|
pub impl @core.VectorStore for MemoryStore with fn delete_collection(self, name) {
  self.lock.acquire()
  defer self.lock.release()
  guard self.collections.contains(name) else {
    raise collection_not_found(name)
  }
  self.collections.remove(name)
}

///|
pub impl @core.VectorStore for MemoryStore with fn collection_exists(self, name) {
  self.lock.acquire()
  defer self.lock.release()
  self.collections.contains(name)
}

///|
pub impl @core.VectorStore for MemoryStore with fn describe_collection(
  self,
  name,
) {
  self.lock.acquire()
  defer self.lock.release()
  match self.collections.get(name) {
    Some(collection) => collection.config
    None => raise collection_not_found(name)
  }
}

///|
pub impl @core.VectorStore for MemoryStore with fn upsert(
  self,
  collection,
  points,
  _wait,
) {
  self.lock.acquire()
  defer self.lock.release()
  let target = self.collections.get(collection)
  guard target is Some(stored) else { raise collection_not_found(collection) }
  // 先全量校验再落盘：「维度不符」这类失败绝不能留下写了一半的集合。
  // 本地的 wait 语义不存在（无远端刷新动作），故忽略该参数并恒返回 All（9.5）。
  for point in points {
    if point.vector.length() != stored.config.size {
      raise @core.VectorStoreError::InvalidArgument(
        message="点向量维度 \{point.vector.length()} 与集合 \{collection} 的维度 \{stored.config.size} 不一致",
      )
    }
  }
  for point in points {
    match stored.index.get(point.id) {
      Some(index) => stored.points[index] = point // 原位覆盖：插入序不变（9.1）
      None => {
        stored.points.push(point)
        stored.index.set(point.id, stored.points.length() - 1)
      }
    }
  }
  @core.All
}

///|
pub impl @core.VectorStore for MemoryStore with fn delete_points(
  self,
  collection,
  ids,
) {
  self.lock.acquire()
  defer self.lock.release()
  let target = self.collections.get(collection)
  guard target is Some(stored) else { raise collection_not_found(collection) }
  for id in ids {
    if stored.index.get(id) is Some(index) {
      ignore(stored.points.remove(index))
      stored.reindex()
    }
  }
}

///|
pub impl @core.VectorStore for MemoryStore with fn delete_by_filter(
  self,
  collection,
  filter,
) {
  self.lock.acquire()
  defer self.lock.release()
  let target = self.collections.get(collection)
  guard target is Some(stored) else { raise collection_not_found(collection) }
  // 两阶段：先在纯计算阶段求出「要删哪些 ID」，再统一删除。
  // 这样即使过滤求值中途抛 Unsupported，也不会留下「删了一半」的集合。
  let doomed : Array[@core.PointId] = []
  for point in stored.points {
    if eval_filter(filter, payload_or_empty(point), point.id) {
      doomed.push(point.id)
    }
  }
  for id in doomed {
    if stored.index.get(id) is Some(index) {
      ignore(stored.points.remove(index))
      stored.reindex()
    }
  }
}

///|
pub impl @core.VectorStore for MemoryStore with fn retrieve(
  self,
  collection,
  ids,
  with_payload,
  with_vector,
) {
  self.lock.acquire()
  defer self.lock.release()
  let target = self.collections.get(collection)
  guard target is Some(stored) else { raise collection_not_found(collection) }
  let out : Array[@core.StoredPoint] = []
  // 按传入 ids 的顺序返回，取不到的静默跳过（与 Qdrant 一致，9.3）
  for id in ids {
    if stored.index.get(id) is Some(index) {
      out.push(stored_point_of(stored.points[index], with_payload, with_vector))
    }
  }
  out
}

///|
pub impl @core.VectorStore for MemoryStore with fn search(self, collection, req) {
  self.lock.acquire()
  defer self.lock.release()
  let target = self.collections.get(collection)
  guard target is Some(stored) else { raise collection_not_found(collection) }
  // 校验顺序固定为「集合 → limit → 维度」（9.3），错误种类见 9.5
  if req.limit < 1 {
    raise @core.VectorStoreError::InvalidArgument(
      message="limit 必须 ≥ 1，收到 \{req.limit}",
    )
  }
  if req.vector.length() != stored.config.size {
    raise @core.VectorStoreError::InvalidArgument(
      message="查询向量维度 \{req.vector.length()} 与集合 \{collection} 的维度 \{stored.config.size} 不一致",
    )
  }
  // 先过滤再算距离：暴力后端下这是唯一有意义的优化，也省掉被排除点的距离计算
  let ranked : Array[Ranked] = []
  for point in stored.points {
    let hit = match req.filter {
      Some(filter) => eval_filter(filter, payload_or_empty(point), point.id)
      None => true
    }
    if hit {
      ranked.push(Ranked::{
        point,
        score: distance_score(stored.config.distance, req.vector, point.vector),
      })
    }
  }
  ranked.sort_by(compare_ranked)
  let out : Array[@core.ScoredPoint] = []
  for item in ranked {
    if out.length() >= req.limit {
      break
    }
    if req.score_threshold is Some(threshold) {
      if item.score > threshold {
        continue // Q7：保留 score <= threshold 的点
      }
    }
    out.push(
      scored_point_of(item.point, item.score, req.with_payload, req.with_vector),
    )
  }
  out
}

///|
pub impl @core.VectorStore for MemoryStore with fn scroll(self, collection, req) {
  self.lock.acquire()
  defer self.lock.release()
  let target = self.collections.get(collection)
  guard target is Some(stored) else { raise collection_not_found(collection) }
  if req.limit < 1 {
    raise @core.VectorStoreError::InvalidArgument(
      message="scroll 的 limit 必须 ≥ 1，收到 \{req.limit}",
    )
  }
  // 游标只在插入序里定位：即使 offset 那个点被 filter 排除，也照此定位，
  // 这样游标不会因 filter 的变化而漂移（9.3）。
  let start = match req.offset {
    None => 0
    Some(id) =>
      match stored.index.get(id) {
        Some(index) => index + 1
        None =>
          raise @core.VectorStoreError::InvalidArgument(
            message="scroll 的 offset 指向集合 \{collection} 中不存在的点",
          )
      }
  }
  let matches : Array[@core.StoredPoint] = []
  let mut cursor = start
  while cursor < stored.points.length() {
    let point = stored.points[cursor]
    let hit = match req.filter {
      Some(filter) => eval_filter(filter, payload_or_empty(point), point.id)
      None => true
    }
    if hit {
      matches.push(stored_point_of(point, req.with_payload, req.with_vector))
    }
    cursor = cursor + 1
  }
  let page : Array[@core.StoredPoint] = []
  for i = 0; i < matches.length() && i < req.limit; i = i + 1 {
    page.push(matches[i])
  }
  // 只有「后面还有满足 filter 的点」时才给游标，否则必须是 None（9.3）
  let next = if matches.length() > req.limit {
    Some(matches[req.limit - 1].id)
  } else {
    None
  }
  { points: page, next_offset: next, }
}

///|
pub impl @core.VectorStore for MemoryStore with fn create_payload_index(
  self,
  collection,
  _field,
  _schema,
) {
  self.lock.acquire()
  defer self.lock.release()
  // 暴力检索不需要索引，因此本地是 no-op 成功；但集合不存在仍要报 NotFound，
  // 否则调用方在切后端时会得到不一致的错误行为（9.5）。
  guard self.collections.contains(collection) else {
    raise collection_not_found(collection)
  }
}

///|
/// 显式声明方法语法可用（ADR-10）。不写这行，用户只能写
/// `@core.VectorStore::search(store, ..)` 而不能写 `store.search(..)`。
pub extend MemoryStore with @core.VectorStore::{
  create_collection,
  delete_collection,
  collection_exists,
  describe_collection,
  upsert,
  delete_points,
  delete_by_filter,
  retrieve,
  search,
  scroll,
  create_payload_index,
}
