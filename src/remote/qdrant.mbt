///| 基于 Qdrant REST v2 的远端后端（DEVELOPMENT.md 8）。native-only。
///
/// 传输层与错误映射在 `transport.mbt`；端点与 DTO 在 `endpoints.mbt` / `dto.mbt`；
/// 本文件只负责把 `VectorStore` 的 11 个方法翻译成 REST 调用序列。
/// 幂等性红线（8.2）：create/delete 集合、delete_by_filter 不重试；其余启用重试。

///|
/// 远端后端。字段全部 `priv`：外部只能通过 `QdrantStore::new` 构造。
/// 每次请求用 `@http.request` 自由函数（内部管连接），不暴露任何 `@http` 类型
/// （ADR-5：不在公共 API 暴露第三方类型）。
pub(all) struct QdrantStore {
  priv options : TransportOptions
}

///|
/// 构造远端后端。
///
/// `url` 是 base URL（如 `http://localhost:6333`，也可带 `https://`，Q9 定稿）；
/// `api_key` 显式传入时覆盖 `options.api_key`；`options` 缺省时使用默认值（8.2）。
pub fn QdrantStore::new(
  url~ : String,
  api_key? : String,
  options? : TransportOptions,
) -> QdrantStore {
  let defaults = match options {
    Some(o) => o
    None => TransportOptions::default()
  }
  let key = match api_key {
    Some(k) => Some(k)
    None => defaults.api_key
  }
  {
    options: TransportOptions::new(
      base_url=url,
      api_key=key,
      timeout_ms=defaults.timeout_ms,
      max_retry=defaults.max_retry,
      retry_initial_ms=defaults.retry_initial_ms,
      retry_factor=defaults.retry_factor,
      retry_max_ms=defaults.retry_max_ms,
      max_concurrency=defaults.max_concurrency,
    ),
  }
}

///|
/// 集合不存在时的 GET 属于正常分支（`collection_exists` 用），单独处理：
/// 404 → `false`，其余错误原样上抛。
pub impl @core.VectorStore for QdrantStore with fn collection_exists(self, name) {
  let exists = try {
    ignore(
      send(
        self.options.base_url,
        @http.Get,
        collection_path(name),
        None,
        self.options,
        true,
      ),
    )
    true
  } catch {
    @core.VectorStoreError::NotFound(_) => false
    e => raise e
  }
  exists
}

///|
pub impl @core.VectorStore for QdrantStore with fn create_collection(
  self,
  name,
  config,
) {
  let body = Json::object({
    "vectors": Json::object({
      "size": Json::number(config.size.to_double()),
      "distance": @json.to_json(config.distance),
      "on_disk": Json::boolean(config.on_disk),
    }),
  })
  ignore(
    send(
      self.options.base_url,
      @http.Put,
      collection_path(name),
      Some(body),
      self.options,
      false,
    ),
  ) catch {
    // 幂等语义（README 特性声明 / Q4 定稿）：真实 Qdrant 对已存在集合一律返回
    // 400/409「already exists」；同名且配置一致时视为创建成功，不一致才报 Conflict。
    @core.VectorStoreError::Conflict(_) => {
      let existing = self.describe_collection(name)
      if existing.size == config.size &&
        existing.distance == config.distance &&
        existing.on_disk == config.on_disk {
        ()
      } else {
        raise @core.VectorStoreError::Conflict(
          message="collection `\{name}` already exists with a different config",
        )
      }
    }
    e => raise e
  }
}

///|
pub impl @core.VectorStore for QdrantStore with fn delete_collection(self, name) {
  ignore(
    send(
      self.options.base_url,
      @http.Delete,
      collection_path(name),
      None,
      self.options,
      false,
    ),
  )
}

///|
pub impl @core.VectorStore for QdrantStore with fn describe_collection(
  self,
  name,
) {
  let body = send(
    self.options.base_url,
    @http.Get,
    collection_path(name),
    None,
    self.options,
    true,
  )
  let dto : QdrantDescribeResult = parse_result(body)
  config_of(dto)
}

///|
pub impl @core.VectorStore for QdrantStore with fn upsert(
  self,
  collection,
  points,
  wait,
) {
  let body = send(
    self.options.base_url,
    @http.Put,
    points_path(collection) + "?wait=\{wait}",
    Some(upsert_body(points)),
    self.options,
    true,
  )
  // Qdrant 的 upsert 整批原子返回（§6.3 / 13.4），无部分失败信息，恒 All
  let status : QdrantStatusResult = parse_result(body)
  ignore(status.status)
  @core.All
}

///|
pub impl @core.VectorStore for QdrantStore with fn delete_points(
  self,
  collection,
  ids,
) {
  ignore(
    send(
      self.options.base_url,
      @http.Post,
      delete_points_path(collection, true),
      Some(delete_ids_body(ids)),
      self.options,
      true,
    ),
  )
}

///|
pub impl @core.VectorStore for QdrantStore with fn delete_by_filter(
  self,
  collection,
  filter,
) {
  ignore(
    send(
      self.options.base_url,
      @http.Post,
      delete_points_path(collection, true),
      Some(delete_filter_body(filter)),
      self.options,
      false,
    ),
  )
}

///|
pub impl @core.VectorStore for QdrantStore with fn retrieve(
  self,
  collection,
  ids,
  with_payload,
  with_vector,
) {
  let body = send(
    self.options.base_url,
    @http.Post,
    points_path(collection),
    Some(retrieve_body(ids, with_payload, with_vector)),
    self.options,
    true,
  )
  let dtos : Array[QdrantStoredJson] = parse_result(body)
  let out : Array[@core.StoredPoint] = []
  for dto in dtos {
    out.push(stored_point_of(dto))
  }
  out
}

///|
pub impl @core.VectorStore for QdrantStore with fn search(self, collection, req) {
  // 与 local 一致的入参校验（9.5 契约：limit<1 → InvalidArgument），
  // 在发请求前拦截，避免把非法输入发给 Qdrant 得到不一致的错误种类。
  if req.limit < 1 {
    raise @core.VectorStoreError::InvalidArgument(
      message="limit 必须 ≥ 1，收到 \{req.limit}",
    )
  }
  // 需要集合的度量来做 score 双向换算（9.2），故先 describe 再 query（两跳）。
  let config = self.describe_collection(collection)
  let body = send(
    self.options.base_url,
    @http.Post,
    query_path(collection),
    Some(search_body(req, config.distance)),
    self.options,
    true,
  )
  let result : QdrantPointsResult = parse_result(body)
  let out : Array[@core.ScoredPoint] = []
  for dto in result.points {
    out.push(scored_point_of(dto, config.distance))
  }
  out
}

///|
pub impl @core.VectorStore for QdrantStore with fn scroll(self, collection, req) {
  // 入参校验与 local 一致（9.5）
  if req.limit < 1 {
    raise @core.VectorStoreError::InvalidArgument(
      message="scroll 的 limit 必须 ≥ 1，收到 \{req.limit}",
    )
  }
  let body = send(
    self.options.base_url,
    @http.Post,
    scroll_path(collection),
    Some(scroll_body(req)),
    self.options,
    true,
  )
  let result : QdrantScrollResult = parse_result(body)
  let points : Array[@core.StoredPoint] = []
  for dto in result.points {
    points.push(stored_point_of(dto))
  }
  { points, next_offset: result.next_page_offset, }
}

///|
pub impl @core.VectorStore for QdrantStore with fn create_payload_index(
  self,
  collection,
  field,
  schema,
) {
  let body = Json::object({
    "field_name": Json::string(field),
    "field_schema": @json.to_json(schema),
  })
  ignore(
    send(
      self.options.base_url,
      @http.Put,
      payload_index_path(collection),
      Some(body),
      self.options,
      false,
    ),
  )
}

///|
/// 显式声明方法语法可用（ADR-10）。不写这行，用户只能写
/// `@core.VectorStore::search(store, ..)` 而不能写 `store.search(..)`。
pub extend QdrantStore with @core.VectorStore::{
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
