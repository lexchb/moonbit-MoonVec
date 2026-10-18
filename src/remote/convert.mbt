///| 双类型体系的转换层（DEVELOPMENT.md 4.3）：请求体 Json 构造 + 响应 DTO → core 类型。
///
/// 分数换算依据 9.2 的表格：Qdrant 对 Cosine 返回 cos（越大越好）、Dot 返回内积
/// （越大越好）、Euclid/Manhattan 返回距离（越小越好）；本库统一「越小越近」，故
/// Cosine 侧取 `1 - score`、Dot 侧取负、距离型度量原样通过。

///|
/// 度量名（Qdrant 返回的裸字符串）→ 本库枚举。
fn metric_from_name(
  name : String,
) -> @core.Distance raise @core.VectorStoreError {
  match name {
    "Cosine" => @core.Cosine
    "Euclid" => @core.Euclid
    "Dot" => @core.Dot
    "Manhattan" => @core.Manhattan
    _ =>
      raise @core.VectorStoreError::Decode(
        message="未知的 distance 度量：\{name}",
      )
  }
}

///|
/// Qdrant score → 本库 score（9.2 换算表）。
fn to_our_score(metric : @core.Distance, qdrant_score : Double) -> Double {
  match metric {
    @core.Cosine => 1.0 - qdrant_score
    @core.Dot => -qdrant_score
    @core.Euclid | @core.Manhattan => qdrant_score
  }
}

///|
/// 本库阈值 → Qdrant 阈值（换算方向与 score 相反）。
fn to_qdrant_threshold(
  metric : @core.Distance,
  our_threshold : Double,
) -> Double {
  match metric {
    @core.Cosine => 1.0 - our_threshold
    @core.Dot => -our_threshold
    @core.Euclid | @core.Manhattan => our_threshold
  }
}

///|
/// 请求体：批量写入。
fn upsert_body(points : Array[@core.Point]) -> Json {
  let items : Array[Json] = []
  for point in points {
    let fields : Map[String, Json] = Map([
      ("id", @json.to_json(point.id)),
      ("vector", Json::array(point.vector.map(v => Json::number(v)))),
    ])
    if point.payload is Some(payload) {
      fields.set("payload", Json::object(payload))
    }
    items.push(Json::object(fields))
  }
  Json::object({ "points": Json::array(items) })
}

///|
/// 请求体：按 ID 删除。
fn delete_ids_body(ids : Array[@core.PointId]) -> Json {
  Json::object({ "points": Json::array(ids.map(id => @json.to_json(id))) })
}

///|
/// 请求体：按过滤器删除。
fn delete_filter_body(filter : @core.Filter) -> Json {
  Json::object({ "filter": @json.to_json(filter) })
}

///|
/// 请求体：按 ID 取点。
fn retrieve_body(
  ids : Array[@core.PointId],
  with_payload : Bool,
  with_vector : Bool,
) -> Json {
  Json::object({
    "ids": Json::array(ids.map(id => @json.to_json(id))),
    "with_payload": Json::boolean(with_payload),
    "with_vector": Json::boolean(with_vector),
  })
}

///|
/// 请求体：相似度检索（query 端点）。
fn search_body(req : @core.SearchRequest, metric : @core.Distance) -> Json {
  let fields : Map[String, Json] = Map([
    ("query", Json::array(req.vector.map(v => Json::number(v)))),
    ("limit", Json::number(req.limit.to_double())),
    ("with_payload", Json::boolean(req.with_payload)),
    ("with_vector", Json::boolean(req.with_vector)),
  ])
  if req.filter is Some(filter) {
    fields.set("filter", @json.to_json(filter))
  }
  if req.score_threshold is Some(threshold) {
    fields.set(
      "score_threshold",
      Json::number(to_qdrant_threshold(metric, threshold)),
    )
  }
  Json::object(fields)
}

///|
/// 请求体：分页遍历。
fn scroll_body(req : @core.ScrollRequest) -> Json {
  let fields : Map[String, Json] = Map([
    ("limit", Json::number(req.limit.to_double())),
    ("with_payload", Json::boolean(req.with_payload)),
    ("with_vector", Json::boolean(req.with_vector)),
  ])
  if req.filter is Some(filter) {
    fields.set("filter", @json.to_json(filter))
  }
  if req.offset is Some(id) {
    fields.set("offset", @json.to_json(id))
  }
  Json::object(fields)
}

///|
/// 响应 DTO → core `StoredPoint`。
fn stored_point_of(json : QdrantStoredJson) -> @core.StoredPoint {
  { id: json.id, payload: json.payload, vector: json.vector, }
}

///|
/// 响应 DTO → core `ScoredPoint`（含分数换算）。
fn scored_point_of(
  json : QdrantScoredJson,
  metric : @core.Distance,
) -> @core.ScoredPoint {
  {
    id: json.id,
    score: to_our_score(metric, json.score),
    payload: json.payload,
    vector: json.vector,
  }
}

///|
/// `describe_collection` 的 DTO → `VectorConfig`。
fn config_of(
  dto : QdrantDescribeResult,
) -> @core.VectorConfig raise @core.VectorStoreError {
  @core.VectorConfig::new(
    size=dto.config.params.vectors.size,
    distance=metric_from_name(dto.config.params.vectors.distance),
    on_disk=match dto.config.params.vectors.on_disk {
      Some(value) => value
      None => false
    },
  )
}
