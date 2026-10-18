///| 传输层：`TransportOptions`、单次请求、超时、显式重试循环、状态码映射、响应体上限。
///
/// 设计依据 DEVELOPMENT.md 8.2 / 8.3：
/// - **重试必须手写显式循环**，不用 `@async.retry`（它会擦除错误类型、且无法按 suberror
///   甄别「4xx 不重试」——M0 实测，见 13.2）；
/// - 幂等性红线：带副作用且非天然幂等的操作（create/delete 集合、delete_by_filter）
///   不重试；只读操作与 upsert（按 ID 覆盖）才启用重试；
/// - 响应体上限硬编码 32MB（Q12 定稿），超限报 `Decode`。

///|
/// 传输层可配置项。**只含原始类型**，不暴露任何 `@http` 类型（ADR-5）。
pub(all) struct TransportOptions {
  base_url : String
  api_key : String?
  timeout_ms : Int
  max_retry : Int
  retry_initial_ms : Int
  retry_factor : Double
  retry_max_ms : Int
  max_concurrency : Int
}

///|
/// `api_key` 是带标签的 `String?` 参数（`~` 使调用方可以写 `api_key=值`），
/// 且值本身是 `Option`，便于直接把已有的 `String?` 原样传入。
pub fn TransportOptions::new(
  base_url~ : String,
  api_key~ : String?,
  timeout_ms? : Int = 5000,
  max_retry? : Int = 3,
  retry_initial_ms? : Int = 20,
  retry_factor? : Double = 2.0,
  retry_max_ms? : Int = 1000,
  max_concurrency? : Int = 4,
) -> TransportOptions {
  {
    base_url,
    api_key,
    timeout_ms,
    max_retry,
    retry_initial_ms,
    retry_factor,
    retry_max_ms,
    max_concurrency,
  }
}

///|
pub fn TransportOptions::default() -> TransportOptions {
  TransportOptions::new(base_url="", api_key=None)
}

///|
/// 响应体上限（Q12 定稿，硬编码）：超过视为异常响应，报 `Decode`。
fn max_body_bytes() -> Int {
  32 * 1024 * 1024
}

///|
/// 请求头：仅当配置了 api-key 时放入 `api-key` 头（Q9 定稿）。
fn headers_of(
  options : TransportOptions,
) -> Map[@http.CaseInsensitiveString, String] {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  if options.api_key is Some(key) {
    headers.set(@http.CaseInsensitiveString("api-key"), key)
  }
  headers
}

///|
/// 从响应体提取可读的错误消息：优先取 Qdrant 错误体 `status.error`（M0 实测能取到整句），
/// 取不到退回整段文本。
fn error_message(body : Json, fallback : String) -> String {
  if body is Object(fields) {
    if fields.get("status") is Some(Object(status)) {
      if status.get("error") is Some(String(message)) {
        return message
      }
    }
  }
  fallback
}

///|
/// HTTP 状态码 → 具名错误（8.3 映射表）。`None` 表示成功。
///
/// 400 需要按错误消息细分（Q4 定稿）：真实 Qdrant 对「重复建集合」返回 400 且错误体
/// 含 `already exists` / `exists`，此时映射 `Conflict`（与本地一致），否则 `InvalidArgument`。
fn map_status_code(code : Int, message : String) -> @core.VectorStoreError? {
  match code {
    200 | 201 | 202 => None
    400 =>
      if message.contains("already exists") || message.contains("exists") {
        Some(@core.VectorStoreError::Conflict(message~))
      } else {
        Some(@core.VectorStoreError::InvalidArgument(message~))
      }
    401 | 403 => Some(@core.VectorStoreError::Auth(message~))
    404 => Some(@core.VectorStoreError::NotFound(resource=message))
    409 => Some(@core.VectorStoreError::Conflict(message~))
    429 => Some(@core.VectorStoreError::RateLimited(retry_after_ms=None))
    _ =>
      if code >= 500 {
        Some(@core.VectorStoreError::Server(status=code, message~))
      } else {
        Some(@core.VectorStoreError::Http(status=code, message~))
      }
  }
}

///|
/// 单次 HTTP 往返（用 `@http.request` 自由函数，它返回 `(Response, &Data)`，body 已读好）。
/// 不包含超时与重试（那是 `send` 的职责）。
///
/// `@http` 的底层错误（连接失败、DNS、读响应失败）统一转成 `Transport`，
/// 交给 `send` 的重试判定处理（Transport 可重试）。
async fn send_once(
  base_url : String,
  verb : @http.RequestMethod,
  path : String,
  body : Json?,
  headers : Map[@http.CaseInsensitiveString, String],
) -> Json raise @core.VectorStoreError {
  let (resp, data) = try {
    // body 用 String（impl Data）序列化：直接传 Json 值会被当空 body（M3 实测，
    // 桩日志显示请求体为空 → KeyError），stringify 成文本最可靠。
    match body {
      Some(payload) =>
        @http.request(base_url + path, verb, headers, payload.stringify())
      None => @http.request(base_url + path, verb, headers, b"")
    }
  } catch {
    e =>
      raise @core.VectorStoreError::Transport(
        message="HTTP 调用失败：\{@debug.to_string(e)}",
      )
  }
  let text = data.text() catch {
    _ =>
      raise @core.VectorStoreError::Decode(
        message="响应体读取失败（HTTP \{resp.code}）",
      )
  }
  if text.length() > max_body_bytes() {
    raise @core.VectorStoreError::Decode(
      message="响应体超过 \{max_body_bytes()} 字节上限",
    )
  }
  let parsed = @json.parse(text) catch {
    _ =>
      raise @core.VectorStoreError::Decode(
        message="响应不是合法 JSON（HTTP \{resp.code}）",
      )
  }
  match map_status_code(resp.code, error_message(parsed, text)) {
    Some(error) => raise error
    None => parsed
  }
}

///|
/// 指数退避（带初始值、倍数与上限）。
fn backoff_ms(attempt : Int, options : TransportOptions) -> Int {
  let mut ms = options.retry_initial_ms
  let mut i = 1
  while i < attempt {
    ms = (ms.to_double() * options.retry_factor).to_int()
    i = i + 1
  }
  if ms > options.retry_max_ms {
    options.retry_max_ms
  } else {
    ms
  }
}

///|
/// 带超时与显式重试的请求入口。
///
/// `base_url` 来自 `QdrantStore.options`。`retryable` 控制是否启用重试（幂等性红线：
/// 非幂等操作传 false，见 8.2）。可重试错误 = 超时、连接层失败、429、502/503/504；
/// 4xx（除 429）与 Decode 等不重试。
async fn send(
  base_url : String,
  verb : @http.RequestMethod,
  path : String,
  body : Json?,
  options : TransportOptions,
  retryable : Bool,
) -> Json raise @core.VectorStoreError {
  let headers = headers_of(options)
  let attempts = if retryable { options.max_retry } else { 0 }
  let mut last : @core.VectorStoreError? = None
  let mut attempt = 0
  while attempt <= attempts {
    try {
      return @async.with_timeout(
        options.timeout_ms,
        () => send_once(base_url, verb, path, body, headers),
        error=@core.VectorStoreError::Timeout(timeout_ms=options.timeout_ms),
      )
    } catch {
      // 值得重试的错误：超时、连接层失败、限流
      @core.VectorStoreError::Timeout(_) as e => last = Some(e)
      @core.VectorStoreError::Transport(_) as e => last = Some(e)
      @core.VectorStoreError::RateLimited(_) as e => last = Some(e)
      // 5xx 只有 502/503/504 可重试（8.2），其余 5xx 立即上抛
      @core.VectorStoreError::Server(status~, ..) as e =>
        if status == 502 || status == 503 || status == 504 {
          last = Some(e)
        } else {
          raise e
        }
      // 429 可重试；其余 4xx 是语义错误，立刻上抛
      @core.VectorStoreError::Http(status~, ..) as e =>
        if status == 429 {
          last = Some(e)
        } else {
          raise e
        }
      // 不可重试的错误（解码失败、资源不存在、冲突、鉴权、参数非法、未支持）
      // 逐个显式列出并原样上抛，保证错误类型不被转换（8.4 契约）。
      @core.VectorStoreError::Decode(_) as e => raise e
      @core.VectorStoreError::NotFound(_) as e => raise e
      @core.VectorStoreError::Conflict(_) as e => raise e
      @core.VectorStoreError::Auth(_) as e => raise e
      @core.VectorStoreError::InvalidArgument(_) as e => raise e
      @core.VectorStoreError::Unsupported(_) as e => raise e
      // 兜底：不应到达（with_timeout 的错误 union 里的其他成员，如取消信号），
      // 按不可重试的连接层失败处理，避免静默。
      _ =>
        raise @core.VectorStoreError::Transport(
          message="重试循环捕到未预期的错误种类",
        )
    }
    attempt = attempt + 1
    if attempt <= attempts {
      @async.sleep(backoff_ms(attempt, options))
    }
  }
  match last {
    Some(e) => raise e
    None =>
      raise @core.VectorStoreError::Transport(
        message="重试耗尽但无错误记录",
      )
  }
}
