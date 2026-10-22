///|
/// 向量：dense，Double 精度。
pub type Vector = Array[Double]

///|
/// Payload：与向量同存的任意 JSON 元数据，用于过滤（DEVELOPMENT.md Q3）。
pub type Payload = Map[String, Json]

///|
/// 点 ID。Qdrant 的 ID 是 **无符号 64 位整数** 或 UUID 字符串，线上表示为裸值。
///
/// 用 UInt64 而非 Int64 是刻意的：Qdrant 自动生成的随机 ID 会超出 2^63-1，
/// 若用 Int64 将无法读取这些已存在的点（DEVELOPMENT.md 6.1）。
pub(all) enum PointId {
  Num(UInt64)
  Uuid(String)
} derive(Eq, Hash)

///|
pub fn PointId::of_int(n : UInt64) -> PointId {
  Num(n)
}

///|
pub fn PointId::of_uuid(s : String) -> PointId {
  Uuid(s)
}

///|
/// 集合的向量配置。
pub(all) struct VectorConfig {
  size : Int32
  distance : Distance
  on_disk : Bool
} derive(Eq)

///|
pub fn VectorConfig::new(
  size~ : Int32,
  distance~ : Distance,
  on_disk~ : Bool = false,
) -> VectorConfig {
  { size, distance, on_disk, }
}

///|
/// payload 索引的类型（对应 Qdrant 的 field_schema）。
///
/// 变体名用 `Boolean` 而非 `Bool`：后者会遮蔽内建类型 Bool 的构造器解析，
/// 在本包内做 Json 模式匹配时会把 `Bool(x)` 误解析为本枚举的变体。
pub(all) enum PayloadSchema {
  Keyword
  Integer
  Float
  Boolean
  Geo
  Text
} derive(Eq)

///|
/// 检索结果条目：带相关性分数。
pub(all) struct ScoredPoint {
  id : PointId
  score : Double
  payload : Payload?
  vector : Vector?
} derive(Eq)

///|
pub fn ScoredPoint::new(
  id~ : PointId,
  score~ : Double,
  payload? : Payload,
  vector? : Vector,
) -> ScoredPoint {
  { id, score, payload, vector, }
}

///|
/// 分页条目的存储形态：无相关性分数。
/// scroll 不返回相关性分数，故不复用 ScoredPoint（DEVELOPMENT.md 6.1 / Q5）。
pub(all) struct StoredPoint {
  id : PointId
  payload : Payload?
  vector : Vector?
} derive(Eq)

///|
pub fn StoredPoint::new(
  id~ : PointId,
  payload? : Payload,
  vector? : Vector,
) -> StoredPoint {
  { id, payload, vector, }
}

///|
/// 待写入的点。
pub(all) struct Point {
  id : PointId
  vector : Vector
  payload : Payload?
} derive(Eq)

///|
pub fn Point::new(id~ : PointId, vector~ : Vector, payload? : Payload) -> Point {
  { id, vector, payload, }
}

///|
/// 批量写入的结果。
/// 当前 Qdrant REST 的 upsert 是整批原子返回，故没有部分失败的信息可用；
/// 保留该枚举以便将来切换到逐条写入时扩展（DEVELOPMENT.md 6.3）。
pub(all) enum UpsertResult {
  All
  Partial(Array[PointId])
} derive(Eq)

///|
/// 相似度检索请求。
pub(all) struct SearchRequest {
  vector : Vector
  filter : Filter?
  limit : Int32
  score_threshold : Double?
  with_payload : Bool
  with_vector : Bool
} derive(Eq)

///|
pub fn SearchRequest::new(
  vector~ : Vector,
  limit~ : Int32,
  filter? : Filter,
  score_threshold? : Double,
  with_payload~ : Bool = true,
  with_vector~ : Bool = false,
) -> SearchRequest {
  { vector, filter, limit, score_threshold, with_payload, with_vector, }
}

///|
/// 分页遍历请求。不承诺全局顺序，只承诺「不重不漏」（DEVELOPMENT.md Q5）。
pub(all) struct ScrollRequest {
  filter : Filter?
  limit : Int32
  offset : PointId?
  with_payload : Bool
  with_vector : Bool
} derive(Eq)

///|
pub fn ScrollRequest::new(
  limit~ : Int32,
  filter? : Filter,
  offset? : PointId,
  with_payload~ : Bool = true,
  with_vector~ : Bool = false,
) -> ScrollRequest {
  { filter, limit, offset, with_payload, with_vector, }
}

///|
/// 分页结果，持有下一页游标。
pub(all) struct ScrollPage {
  points : Array[StoredPoint]
  next_offset : PointId?
} derive(Eq)
