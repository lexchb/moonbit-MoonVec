///| 与后端无关的向量检索契约（DEVELOPMENT.md 6.4）。
///
/// local 与 remote 两个后端都实现本 trait；调用方只依赖本 trait，即可在不改代码的
/// 前提下切换后端。所有方法都是 async，因此实现侧可以安全地使用异步原语
/// （如 MemoryStore 的 @async.Mutex）而不会污染同步 API。
///
/// 注意：实现方必须额外写 `pub extend X with VectorStore::{..}`，否则用户无法使用
/// 方法语法（本工具链已弃用 trait 方法的隐式提升），只能写
/// `VectorStore::search(store, ..)`。见 DEVELOPMENT.md 6.4 / ADR-10。

///|
/// 注意：必须是 `pub(open) trait`。裸的 `pub trait` 是 readonly 的，**外部包无法实现它**
/// （编译报 `Cannot implement trait ... because it is readonly`）。若写成 `pub`，
/// local / remote 以及用户自定义后端都将无法实现本契约，抽象层直接失效。
pub(open) trait VectorStore {
  // 集合管理
  async fn create_collection(Self, name : String, config : VectorConfig) -> Unit raise VectorStoreError
  async fn delete_collection(Self, name : String) -> Unit raise VectorStoreError
  async fn collection_exists(Self, name : String) -> Bool raise VectorStoreError
  async fn describe_collection(Self, name : String) -> VectorConfig raise VectorStoreError

  // 数据写入
  async fn upsert(Self, collection : String, points : Array[Point], wait : Bool) -> UpsertResult raise VectorStoreError
  async fn delete_points(Self, collection : String, ids : Array[PointId]) -> Unit raise VectorStoreError
  async fn delete_by_filter(Self, collection : String, filter : Filter) -> Unit raise VectorStoreError

  // 数据读取
  async fn retrieve(
    Self,
    collection : String,
    ids : Array[PointId],
    with_payload : Bool,
    with_vector : Bool,
  ) -> Array[StoredPoint] raise VectorStoreError
  async fn search(Self, collection : String, req : SearchRequest) -> Array[
    ScoredPoint,
  ] raise VectorStoreError
  async fn scroll(Self, collection : String, req : ScrollRequest) -> ScrollPage raise VectorStoreError

  // 索引
  async fn create_payload_index(
    Self,
    collection : String,
    field : String,
    schema : PayloadSchema,
  ) -> Unit raise VectorStoreError
}
