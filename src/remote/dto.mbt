///| Qdrant 线上响应 DTO（双类型体系，DEVELOPMENT.md 4.3）。
///
/// 只定义**解析用**的响应形状；请求体在 `convert.mbt` 里用 `Json` 直接构造
/// （请求字段数量多、形状随端点变化，用 Json 构造更接近 §8.1 的映射表）。
/// DTO 用 `derive(@json.FromJson)`，`Option` 字段对 JSON `null` 自动解析为 `None`。

///|
/// 点（存储形态，无 score）：`{"id": .., "payload": .., "vector": ..}`。
priv struct QdrantStoredJson {
  id : @core.PointId
  payload : Map[String, Json]?
  vector : Array[Double]?
} derive(@json.FromJson)

///|
/// 点（检索形态，带 score）：`{"id": .., "score": .., "payload": .., "vector": ..}`。
priv struct QdrantScoredJson {
  id : @core.PointId
  score : Double
  payload : Map[String, Json]?
  vector : Array[Double]?
} derive(@json.FromJson)

///|
/// `scroll` / `query` 的 result 都是 `{"points": [...]}` 形态。
priv struct QdrantPointsResult {
  points : Array[QdrantScoredJson]
} derive(@json.FromJson)

///|
/// `scroll` 的 result 额外带 `next_page_offset`（可为 `null` → `None`）。
///
/// 手写 FromJson（不开 derive）：M3 实测 `derive(@json.FromJson)` 对 `PointId?` 字段
/// **不把 JSON 的显式 `null` 当 `None`**（M1 只验证过「缺 key → None」），而 Qdrant 的
/// scroll 末页必然返回 `"next_page_offset": null`。
priv struct QdrantScrollResult {
  points : Array[QdrantStoredJson]
  next_page_offset : @core.PointId?
}

///|
/// 手写 FromJson。逻辑内联（不能在签名里写出 `@json.JsonPath`，它是包私有类型，
/// 见 M1 坑 #8 / 13.4），靠 impl 方法入参 `path` 推断。
impl @json.FromJson for QdrantScrollResult with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "scroll result: expected object"))
  }
  guard fields.get("points") is Some(points_json) else {
    raise @json.JsonDecodeError((path, "scroll result: missing points"))
  }
  let points_parsed : Array[QdrantStoredJson] = @json.from_json(
    points_json,
    path=path.add_key("points"),
  )
  let offset = match fields.get("next_page_offset") {
    None => None
    Some(Json::Null) => None
    Some(value) =>
      Some(@json.from_json(value, path=path.add_key("next_page_offset")))
  }
  { points: points_parsed, next_page_offset: offset, }
}

///|
/// `upsert` / `delete` 的 result：`{"status": "ok"}`。
priv struct QdrantStatusResult {
  status : String
} derive(@json.FromJson)

///|
/// `describe_collection` 的 result：`{"config": {"params": {"vectors": ..}}}`。
priv struct QdrantDescribeResult {
  config : QdrantConfigJson
} derive(@json.FromJson)

///|
priv struct QdrantConfigJson {
  params : QdrantParamsJson
} derive(@json.FromJson)

///|
priv struct QdrantParamsJson {
  vectors : QdrantVectorsJson
} derive(@json.FromJson)

///|
/// 只取我们用得到的三个字段；Qdrant 实际的 `vectors` 可能是对象（多向量）或数组，
/// 本项目只支持单向量配置，遇到不匹配的形状在转换层报 `Decode`。
priv struct QdrantVectorsJson {
  size : Int32
  distance : String
  on_disk : Bool?
} derive(@json.FromJson)

///|
/// 从完整响应里取 `result` 字段（`{"result": .., "status": "ok", "time": ..}`）。
fn result_of(body : Json) -> Json raise @core.VectorStoreError {
  if body is Object(fields) {
    if fields.get("result") is Some(result) {
      return result
    }
  }
  raise @core.VectorStoreError::Decode(message="响应缺少 result 字段")
}

///|
/// 从完整响应里取 `result` 并解析为 `T`。
///
/// 不传 path：`@json.JsonPath` 是包私有类型，外部包无法写出其类型名（M1 坑 #8，
/// 见 13.4），故依赖默认 path，靠异常消息定位。
fn[T : @json.FromJson] parse_result(
  body : Json,
) -> T raise @core.VectorStoreError {
  let json = result_of(body)
  @json.from_json(json) catch {
    _ =>
      raise @core.VectorStoreError::Decode(
        message="响应 result 解析失败：\{json.stringify()}",
      )
  }
}
