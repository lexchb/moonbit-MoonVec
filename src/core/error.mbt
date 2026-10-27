///|
/// 本库统一错误类型。
///
/// local 与 remote 两个后端都必须能用这套错误表达失败，以保证调用方的 catch
/// 在切换后端时无需修改（DEVELOPMENT.md 8.4）。
pub(all) suberror VectorStoreError {
  /// 单次请求超时（超时上限，毫秒）
  Timeout(timeout_ms~ : Int32)
  /// 连接层失败：连接被拒、DNS、TLS、读取中断等
  Transport(message~ : String)
  /// 非 2xx 且语义明确的客户端错误（4xx）
  Http(status~ : Int32, message~ : String)
  /// 服务端错误（5xx）
  Server(status~ : Int32, message~ : String)
  /// 响应体解析失败
  Decode(message~ : String)
  /// 目标资源不存在
  NotFound(resource~ : String)
  /// 状态冲突，例如同名集合已存在但配置不同
  Conflict(message~ : String)
  /// 鉴权失败
  Auth(message~ : String)
  /// 被限流；若响应带 Retry-After 则填入毫秒数（当前 transport 层不解析该头，恒为 None）
  RateLimited(retry_after_ms~ : Int32?)
  /// 调用方参数非法（如向量维度不匹配）
  InvalidArgument(message~ : String)
  /// 该能力未实现或本后端不支持
  Unsupported(feature~ : String)
}

///|
/// suberror 不会自动获得 Show，补齐以便在错误插值与日志中可读。
pub impl Show for VectorStoreError with fn output(self, logger) {
  match self {
    Timeout(timeout_ms~) => logger <+ "Timeout(after \{timeout_ms}ms)"
    Transport(message~) => logger <+ "Transport(\{message})"
    Http(status~, message~) => logger <+ "Http(\{status}: \{message})"
    Server(status~, message~) => logger <+ "Server(\{status}: \{message})"
    Decode(message~) => logger <+ "Decode(\{message})"
    NotFound(resource~) => logger <+ "NotFound(\{resource})"
    Conflict(message~) => logger <+ "Conflict(\{message})"
    Auth(message~) => logger <+ "Auth(\{message})"
    RateLimited(retry_after_ms~) =>
      match retry_after_ms {
        Some(ms) => logger <+ "RateLimited(retry_after=\{ms}ms)"
        None => logger <+ "RateLimited"
      }
    InvalidArgument(message~) => logger <+ "InvalidArgument(\{message})"
    Unsupported(feature~) => logger <+ "Unsupported(\{feature})"
  }
}
