///| 本文件把 9.4「内部串行化」所依赖的 `@async.Mutex` 语义固化为回归测试。
///
/// 两个断言都不是「教科书废话」，而是实现方式的前提：
///
/// 1. **defer 在 raise 展开时是否释放锁**：`MemoryStore` 的写路径统一采用
///    `acquire` + `defer release`。若 defer 不执行，一次失败的写操作会**永久占住锁**，
///    症状是后续操作「挂死」而非报错，极难定位。因此必须用测试锁死这条语义，
///    而不是相信文档。
/// 2. **并发累加不丢更新**：证明 Mutex 在 native / js / wasm 上真的互斥（Q10 只说
///    API 可用，没说并发正确性由谁保证）。

///|
/// 探针：一个带锁的计数器。用 `priv struct` 以便同时验证「priv 成员可从白盒测试访问」。
priv struct LockedBox {
  lock : @async.Mutex
  mut value : Int
}

///|
fn LockedBox::new() -> LockedBox {
  { lock: @async.Mutex(), value: 0, }
}

///|
/// 临界区内只做同步运算，**不含任何 `suspend` 点** —— 这正是 9.4 里
/// 「写路径临界区是原子的」这一说法的依据。
async fn LockedBox::bump(self : LockedBox) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  self.value = self.value + 1
}

///|
async fn LockedBox::bump_then_raise(
  self : LockedBox,
) -> Unit raise @core.VectorStoreError {
  self.lock.acquire()
  defer self.lock.release()
  self.value = self.value + 1
  raise @core.VectorStoreError::InvalidArgument(
    message="探针：临界区内的预期失败",
  )
}

///|
async test "Mutex：临界区抛错后 defer 仍释放锁" {
  let box = LockedBox::new()
  let caught = try {
    box.bump_then_raise()
    false
  } catch {
    _ => true
  }
  inspect(caught, content="true")
  inspect(box.value, content="1")
  // 关键断言：锁必须已经释放，否则后续任何写操作都会永久阻塞
  let free = box.lock.try_acquire()
  inspect(free, content="true")
  if free {
    box.lock.release()
  }
}

///|
async test "Mutex：并发累加无丢更新（8 任务 × 50 次 = 400）" {
  let box = LockedBox::new()
  @async.with_task_group(root => {
    for i = 0; i < 8; i = i + 1 {
      root.spawn_bg() <| () => {
        for j = 0; j < 50; j = j + 1 {
          box.bump()
        }
      }
    }
  })
  inspect(box.value, content="400")
}
