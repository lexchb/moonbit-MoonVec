///| 批次与并发门面（DEVELOPMENT.md 6.6）。
///
/// 对任意 `VectorStore` 通用的「有界并发批量写入 / 检索」。
///
/// 并发用 `@async.all`（有界并发可控）。子任务的错误**不**靠 task group 传导——
/// M4 实测（corporative 与 `@async.retry` 同一坑）：task group / `@async.all` 会把子任务的
/// 错误类型擦除为抽象 `Error`，与门面的 `raise VectorStoreError` 不匹配。因此每个子任务
/// 自行 `catch` 自身错误，返回 `(结果, VectorStoreError?)`；`@async.all` 正常跑完所有子任务
/// 后，门面扫描结果数组，遇到第一个 `Some(e)` 就 `raise e`（错误精确传播）。
///
/// 代价：**不保证 fail-fast**——失败时不中断其余并发子任务，而是全部完成后统一上抛。
/// 这是 M4 的取舍（保证并发度 + 错误精确 + 实现最简）；「失败立即取消其余」登记为 M5 优化。

///|
/// 把数组按 `size` 切成子数组（最后一个子数组可能不足 size）。仅供本文件。
fn[T] chunk(xs : Array[T], size : Int32) -> Array[Array[T]] {
  let out : Array[Array[T]] = []
  let mut i = 0
  while i < xs.length() {
    let slice : Array[T] = []
    let mut j = i
    while j < xs.length() && j < i + size {
      slice.push(xs[j])
      j = j + 1
    }
    out.push(slice)
    i = i + size
  }
  out
}

///|
/// 有界并发批量 upsert（6.6）。
///
/// `points` 按 `batch_size` 切块，每个子块一次 upsert，最多 `max_concurrent` 个子块并发。
/// 任一子块失败 → 全部跑完后上抛**第一个** `VectorStoreError`；已成功写入的子块保留
/// （batch_write 不保证整体原子，见 19 节）。
///
/// 对 local：并发子块会被 `MemoryStore` 的 `@async.Mutex` 串行化（正确但无性能增益）；
/// 对 remote：并发 = 同时进行的 HTTP 请求数。
pub async fn batch_write(
  store : &VectorStore,
  collection : String,
  points : Array[Point],
  batch_size~ : Int32,
  max_concurrent~ : Int32 = 4,
  wait~ : Bool = true,
) -> Unit raise VectorStoreError {
  if batch_size < 1 {
    raise VectorStoreError::InvalidArgument(
      message="batch_size 必须 ≥ 1，收到 \{batch_size}",
    )
  }
  if max_concurrent < 1 {
    raise VectorStoreError::InvalidArgument(
      message="max_concurrent 必须 ≥ 1，收到 \{max_concurrent}",
    )
  }
  if points.length() == 0 {
    return
  }
  let jobs : Array[async () -> (UpsertResult, VectorStoreError?)] = []
  for block in chunk(points, batch_size) {
    jobs.push(async fn() -> (UpsertResult, VectorStoreError?) {
      (store.upsert(collection, block, wait), None) catch {
        e => (All, Some(e))
      }
    })
  }
  let results = @async.all(jobs, max_concurrent~) catch {
    // @async.all 内部 task group 被静态推断可抛抽象 Error；把这类「并发基础设施」
    // 错误转成 Transport（正常运行时不触发，子任务错误经返回元组传递而非抛出）。
    _ =>
      raise VectorStoreError::Transport(message="批次并发运行时异常")
  }
  raise_first_error(results)
}

///|
/// 有界并发批量检索（6.6）。一次跑多个查询，返回与 `requests` 同序的结果数组。
///
/// 任一请求失败 → 全部跑完后上抛**第一个** `VectorStoreError`。
pub async fn batch_search(
  store : &VectorStore,
  collection : String,
  requests : Array[SearchRequest],
  max_concurrent~ : Int32 = 4,
) -> Array[Array[ScoredPoint]] raise VectorStoreError {
  if max_concurrent < 1 {
    raise VectorStoreError::InvalidArgument(
      message="max_concurrent 必须 ≥ 1，收到 \{max_concurrent}",
    )
  }
  if requests.length() == 0 {
    return []
  }
  let jobs : Array[async () -> (Array[ScoredPoint], VectorStoreError?)] = []
  for request in requests {
    jobs.push(async fn() -> (Array[ScoredPoint], VectorStoreError?) {
      (store.search(collection, request), None) catch {
        e => ([], Some(e))
      }
    })
  }
  let results = @async.all(jobs, max_concurrent~) catch {
    _ =>
      raise VectorStoreError::Transport(message="批次并发运行时异常")
  }
  raise_first_error(results)
  // 到这里必然无错误（否则 raise_first_error 已抛出），可安全取结果
  let out : Array[Array[ScoredPoint]] = []
  for (ok, _) in results {
    out.push(ok)
  }
  out
}

///|
/// 扫描结果数组，遇第一个 `Some(e)` 即 `raise e`。供两个 batch 共用。
fn[T] raise_first_error(
  results : Array[(T, VectorStoreError?)],
) -> Unit raise VectorStoreError {
  for (_, err) in results {
    if err is Some(e) {
      raise e
    }
  }
}
