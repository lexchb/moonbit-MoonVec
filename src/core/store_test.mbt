///| M1 trait 可实现性与可调用性冒烟测试（黑盒）。
///
/// 目的：在还没写任何真实后端之前，先证明 `VectorStore` 这套契约是**可从外部包实现**、
/// **可用泛型约束**、**可用 trait object 泛化**的。否则抽象层是否成立要拖到 M2 才发现。
///
/// 因为是黑盒测试（独立包），本文件同时充当「公共 API 是否真的对外可用」的守门测试，
/// 并且刻意使用外部用户视角的 `@core.` 限定名：
/// - 若把 trait 写成 `pub trait`（readonly），则无法实现 → 本文件编译失败；
/// - 若把枚举写成 `pub enum`（readonly），则无法构造其变体 → 本文件编译失败。

///|
/// 测试替身：只记录最近一次调用的集合名
struct EchoStore {
  mut last_collection : String
}

///|
fn EchoStore::new() -> EchoStore {
  { last_collection: "", }
}

///|
impl @core.VectorStore for EchoStore with fn create_collection(
  self,
  name,
  _config,
) {
  self.last_collection = name
}

///|
impl @core.VectorStore for EchoStore with fn delete_collection(self, name) {
  self.last_collection = name
}

///|
impl @core.VectorStore for EchoStore with fn collection_exists(_self, _name) {
  true
}

///|
impl @core.VectorStore for EchoStore with fn describe_collection(_self, _name) {
  @core.VectorConfig::new(size=4, distance=@core.Cosine)
}

///|
impl @core.VectorStore for EchoStore with fn upsert(
  self,
  collection,
  _points,
  _wait,
) {
  self.last_collection = collection
  @core.All
}

///|
impl @core.VectorStore for EchoStore with fn delete_points(
  self,
  collection,
  _ids,
) {
  self.last_collection = collection
}

///|
impl @core.VectorStore for EchoStore with fn delete_by_filter(
  self,
  collection,
  _filter,
) {
  self.last_collection = collection
}

///|
impl @core.VectorStore for EchoStore with fn retrieve(
  _self,
  _collection,
  ids,
  _wp,
  _wv,
) {
  let out : Array[@core.StoredPoint] = []
  for id in ids {
    out.push(@core.StoredPoint::new(id~))
  }
  out
}

///|
impl @core.VectorStore for EchoStore with fn search(self, collection, req) {
  self.last_collection = collection
  [
    @core.ScoredPoint::new(
      id=@core.PointId::of_int(1UL),
      score=0.0,
      vector=req.vector,
    ),
  ]
}

///|
impl @core.VectorStore for EchoStore with fn scroll(_self, _collection, req) {
  { points: [], next_offset: req.offset, }
}

///|
impl @core.VectorStore for EchoStore with fn create_payload_index(
  _self,
  _collection,
  _field,
  _schema,
) {
  ()
}

///|
/// 显式声明方法语法可用（ADR-10）。不写这行只能写
/// `@core.VectorStore::describe_collection(store, ..)`。
pub extend EchoStore with @core.VectorStore::{
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

///|
/// 用泛型约束调用：调用方只需知道 VectorStore，不知道具体后端
async fn[T : @core.VectorStore] run_via_generic(
  store : T,
  name : String,
) -> Int raise @core.VectorStoreError {
  store.create_collection(
    name,
    @core.VectorConfig::new(size=4, distance=@core.Cosine),
  )
  ignore(
    store.upsert(
      name,
      [
        @core.Point::new(id=@core.PointId::of_int(1UL), vector=[
          1.0, 2.0, 3.0, 4.0,
        ]),
      ],
      true,
    ),
  )
  let hits = store.search(
    name,
    @core.SearchRequest::new(vector=[1.0, 2.0, 3.0, 4.0], limit=1),
  )
  hits.length()
}

///|
/// 用 trait object 调用同一个后端
async fn run_via_dyn(
  store : &@core.VectorStore,
  name : String,
) -> Bool raise @core.VectorStoreError {
  store.collection_exists(name)
}

///|
async test "VectorStore 可被外部包实现：泛型约束调用" {
  let store = EchoStore::new()
  let n = run_via_generic(store, "docs")
  inspect(n, content="1")
  inspect(store.last_collection, content="docs")
}

///|
async test "VectorStore 可被外部包实现：trait object 调用" {
  let store : &@core.VectorStore = EchoStore::new()
  let exists = run_via_dyn(store, "docs")
  inspect(exists, content="true")
}

///|
async test "公共 API 对外可用：构造请求、过滤条件与错误类型" {
  let store = EchoStore::new()
  let config = store.describe_collection("docs")
  inspect(config.size, content="4")
  inspect(config.on_disk, content="false")

  let filter = @core.Filter::new(
    must=[
      @core.Clause::from_condition(
        @core.Condition::match_str("tenant_id", "acme"),
      ),
    ],
    must_not=[
      @core.Clause::from_condition(
        @core.Condition::is_null("deleted_at", false),
      ),
    ],
  )
  let page = store.scroll("docs", @core.ScrollRequest::new(limit=10, filter~))
  inspect(page.points.length(), content="0")

  // 用户必须能用具名错误精确分辨失败种类
  let kind = try {
    raise @core.VectorStoreError::Http(status=404, message="no such collection")
  } catch {
    @core.VectorStoreError::Http(status~, ..) => "http:\{status}"
    @core.VectorStoreError::Timeout(timeout_ms~) => "timeout:\{timeout_ms}"
    _ => "other"
  }
  inspect(kind, content="http:404")
}
