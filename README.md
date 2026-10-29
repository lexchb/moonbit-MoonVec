# MoonVec

基于 MoonBit 的类型安全向量检索库：统一的 `VectorStore` 抽象层、基于 Qdrant REST v2 的远端后端，以及零依赖的纯内存本地后端。

MoonBit 生态此前没有任何向量检索客户端。要在 MoonBit 中构建 RAG、语义搜索或推荐类应用，开发者只能手写 JSON 请求并自行处理 HTTP 错误与重试。本库把「建集合 → 写入 → 相似度检索 → 条件过滤 → 分页 → 删除」变成一套静态可检查的 API，且不绑定任何具体应用：抽象层不暴露 Qdrant 特有的数据结构，任何需要向量检索的 MoonBit 项目都可以直接复用。

## 特性

- **统一抽象层**：[`VectorStore`](#vectorstore-抽象层) trait 提供 11 个 async 方法，local / remote 两个后端共用同一契约，调用方不改代码即可切换后端；`pub(open)` 允许外部实现自定义后端。
- **类型安全的过滤条件 DSL**：`must` / `should` / `must_not` 嵌套、`match`（value / any / except / text）、`range`、`geo`（矩形 / 半径）、`values_count`、`is_empty` / `is_null`、`has_id`，全部由代数数据类型表达，无需手写 JSON。
- **本地内存后端**：暴力 kNN，四种度量（cosine / euclid / dot / manhattan），统一「分数越小越近」语义；`@async.Mutex` 内部串行化保证并发写安全；零外部依赖，可在 native / js / wasm 上运行。
- **远端后端**：Qdrant REST v2，支持 HTTPS 与 api-key，内置超时、指数退避重试与具名错误映射。
- **具名错误体系**：`VectorStoreError`（Timeout / Transport / Http / Server / Decode / NotFound / Conflict / Auth / RateLimited / InvalidArgument / Unsupported），两个后端共用。
- **一致性测试套件 C1–C16**：对任意 `VectorStore` 实现都通过的共享断言，保证两个后端行为不漂移；单元测试 native 50 / js 48 / wasm 48 项全部通过，0 warning。

## 安装

```sh
moon add lexchb/moon_vector
```

依赖 `moonbitlang/async@0.22.1`。

### 工具链版本

- **本机开发版本（固定）**：`moon 0.1.20261023 (3778465)` / `moonc v0.10.17+d971670cd`。项目按此版本开发与验证，升级工具链前须跑全量测试。
- **CI（无法固定版本）**：MoonBit 官方 CDN（cli.moonbitlang.com）只提供 `latest` / `nightly` 两个下载键，无版本化路径（实测 403），故 CI 安装 `latest` 并在日志中打印 `moon version --all` 供追溯。若 CI 与本地版本漂移导致失败，以 [DEVELOPMENT.md 11.1](DEVELOPMENT.md#111-模块配置) 的 known-good 配对表为排查基准。

## 运行示例（无需 Docker）

仓库自带一个完整可运行的本地后端示例（建集合 → 写入 → 检索 → 过滤 → 分页 → 删除 + 批量写入门面），不依赖任何外部服务：

```sh
moon run examples/local_demo
```

示例源码见 [examples/local_demo/main.mbt](examples/local_demo/main.mbt)，下方「快速开始」即其核心流程摘录。

## 快速开始（本地后端，无需 Docker）

以下示例用 `MemoryStore` 跑通「建集合 → 写入 → 检索 → 过滤」完整流程，不依赖任何外部服务：

```moonbit
fn main {
  // 1. 构造纯内存后端
  let store = @local.MemoryStore::new()

  // 2. 建集合：3 维，Cosine 度量
  store.create_collection(
    "demo",
    @core.VectorConfig::new(size=3, distance=@core.Cosine),
  )

  // 3. 写入带 payload 的点
  store.upsert(
    "demo",
    [
      @core.Point::new(
        id=@core.PointId::of_int(1UL),
        vector=[1.0, 0.0, 0.0],
        payload=Map([("tag", @json.Json::string("rust")), ("n", @json.Json::number(1.0))]),
      ),
      @core.Point::new(
        id=@core.PointId::of_int(2UL),
        vector=[0.9, 0.1, 0.0],
        payload=Map([("tag", @json.Json::string("go")), ("n", @json.Json::number(2.0))]),
      ),
      @core.Point::new(
        id=@core.PointId::of_int(3UL),
        vector=[0.0, 1.0, 0.0],
        payload=Map([("tag", @json.Json::string("rust")), ("n", @json.Json::number(3.0))]),
      ),
    ],
    true,
  )

  // 4. 带过滤的 top-2 检索
  let hits = store.search(
    "demo",
    @core.SearchRequest::new(
      vector=[1.0, 0.1, 0.0],
      limit=2,
      filter=@core.Filter::new(
        must=[
          @core.Clause::from_condition(
            @core.Condition::match_str("tag", "rust"),
          ),
        ],
      ),
    ),
  )
  for hit in hits {
    println("score=\{hit.score}")
  }
}
```

过滤条件确保命中的点 `tag` 均为 `rust`，`score` 越小表示越相似（Cosine 度量下本库 `score = 1 - cos`）。

## API 概览

### `VectorStore` 抽象层

`pub(open) trait VectorStore` 定义 11 个 async 方法，local / remote 两个后端都实现它：

| 类别 | 方法 | 说明 |
| --- | --- | --- |
| 集合管理 | `create_collection` / `delete_collection` / `collection_exists` / `describe_collection` | 建删查集合；同名且配置一致则幂等成功，不一致报 `Conflict` |
| 数据写入 | `upsert` / `delete_points` / `delete_by_filter` | 批量写入（按 ID 覆盖）、按 ID 删除、按过滤条件删除 |
| 数据读取 | `retrieve` / `search` / `scroll` | 按 ID 读取、相似度检索、游标分页遍历 |
| 索引 | `create_payload_index` | 本地后端为 no-op 成功（暴力检索无需索引） |

### 核心类型

- `Vector = Array[Double]`：dense 向量，Double 精度。
- `Payload = Map[String, Json]`：与向量同存的任意 JSON 元数据，用于过滤。
- `PointId = Num(UInt64) | Uuid(String)`：用 **UInt64** 而非 Int64——Qdrant 自动生成的随机 ID 会超出 `2^63-1`。
- `VectorConfig { size, distance, on_disk }`：集合向量配置。
- `Point` / `StoredPoint` / `ScoredPoint`：待写入点 / 分页存储点 / 带分检索点。
- `SearchRequest { vector, filter?, limit, score_threshold?, with_payload, with_vector }`。
- `ScrollRequest { filter?, limit, offset?, with_payload, with_vector }` 与 `ScrollPage { points, next_offset }`。
- `Distance = Cosine | Euclid | Dot | Manhattan`。
- `UpsertResult = All | Partial(Array[PointId])`。

### 过滤条件 DSL

`Filter { must?, should?, must_not? }` 的子句可以是单条件（`Clause::from_condition`）或嵌套 Filter（`Clause::from_filter`）。条件覆盖：

- `Condition::match_value / match_str / match_int / match_bool / match_any / match_except / match_text`
- `Condition::range(key, gt?, gte?, lt?, lte?)`
- `Condition::GeoBoundingBox(key, box)` / `Condition::GeoRadius(key, spec)`（radius 单位为米）
- `Condition::is_empty(key, value)` / `Condition::is_null(key, value)` / `Condition::has_id(ids)` / `Condition::values_count(key, gt?, ...)` / `Condition::nested(key, filter)`

### 错误体系

所有方法 `raise VectorStoreError`。`Timeout` / `Transport` / `Http` / `Server` / `Decode` / `NotFound` / `Conflict` / `Auth` / `RateLimited` / `InvalidArgument` / `Unsupported` 两个后端共用，切换后端时 catch 逻辑无需修改。

## 远端后端（QdrantStore）

`QdrantStore` 将 `VectorStore` 的 11 个方法翻译为 Qdrant REST 调用序列：

```moonbit
let store = @remote.QdrantStore::new(
  url="http://localhost:6333",
  api_key="your-api-key", // 可选，经 HTTPS 时放入 api-key 头
)
```

传输层可配置项 `TransportOptions`（`@remote`）：`timeout_ms`（默认 5000）、`max_retry`（默认 3）、`retry_initial_ms`（20）、`retry_factor`（2.0）、`retry_max_ms`（1000）、`max_concurrency`（默认 4）。

重试策略遵循幂等性红线：只读操作与按 ID 覆盖的 upsert 启用重试；`create_collection` / `delete_collection` / `delete_by_filter` 不重试。响应体上限硬编码 32MB，超限报 `Decode`。

### 最低 Qdrant 版本

**Qdrant 1.10+**。本库只实现 `points/query`，不实现已弃用的 `points/search`。

## 已知差异

本地后端与 Qdrant 的行为对齐已由一致性测试套件钉住，但存在以下刻意差异，使用前请知悉：

1. **分数换算**：本库统一「分数越小越近」。Cosine 度量 `score = 1 - cos`（Qdrant 返回 `cos`）；Dot 度量 `score = -Σ(a·b)`（Qdrant 返回内积）；Euclid / Manhattan 与 Qdrant 相同。
2. **`Match::Text` 是子串近似**：本库按「字符串包含、不区分大小写」求值；Qdrant 的 `text` 基于分词全文索引。一致性测试只使用「分词与子串结论一致」的样本。
3. **过滤路径语义限定**：支持点号与 `[]` 路径形式；不支持的路径形式显式报 `Unsupported`。
4. **Cosine 零向量约定**：任一侧模长为 0 时 `score` 固定为 `1.0`（不产生 NaN，语义为「正交 / 无相似度」）。该分支未经真实 Qdrant 复测，若不一致将在此声明。
5. **`create_payload_index`**：本地后端为 no-op 成功（暴力检索不需要索引）。
6. **`scroll` 顺序**：游标基于插入序，不承诺全局顺序，只承诺「不重不漏」。
7. **`scroll` 的 `offset` 指向已删除的点时报 `InvalidArgument`**：Qdrant 对已删点采用软删除位图、`offset` 按 id 续扫不报错；本库本地后端为物理删除 + 插入序，无法从已删点之后定位「下一个插入位置」，故显式报错。翻页中途删除上页 `next_offset` 对应的点后继续翻页会触发该错误（Q15 定稿，2026-10-25）。
8. **wasm-gc 目标**：只保证可编译，不承诺运行时行为。本项目承诺的**三目标为 `native` / `js` / `wasm`**（三者均全量执行测试）；`wasm-gc` 是独立的第四个目标，其下 `async test` 不执行——2026-10-29 实测 `moon test --target wasm-gc` 为 **35 项同步测试通过、13 项 async 测试未执行**（`wasm` 目标为 48 项），且**退出码仍为 0**，故不能只看退出码判断该目标绿灯。根因是上游 `moonbitlang/async@0.22.1` 未提供 wasm-gc 的事件循环驱动器（`run_async_main` 仅覆盖 `native` / `js` / `wasm`），**非本项目缺陷**。

行为对齐说明（与 Qdrant 一致，非差异）：`retrieve` 按传入 ids 顺序返回能取到的点，缺失 ID 静默跳过；写入时无 payload 的点在 `with_payload=true` 下返回 `Some(空 Map)` 而非 `None`。

## 并发说明

- **本地后端**：`MemoryStore` 内部持有 `@async.Mutex`，11 个方法统一 `acquire` + `defer release`，临界区内不含 `suspend` 点，因此写路径可直接用于 `@async.all(max_concurrent=n)` 的并发批量写入，无需调用方额外加锁。
- **远端后端**：批量并发由 `TransportOptions.max_concurrency` 控制（`@async.all` 有界并发），失败可整组取消。
- **wasm-gc**：无法验证并发行为，只承诺可编译。

## 测试

- 一致性测试套件 **C1–C16**：对任意 `VectorStore` 实现通过的共享断言，local / remote 两端共用，防止行为漂移。
- 单元测试：native **50** / js **48** / wasm **48** 项全部通过，0 warning（wasm-gc 下 async 测试静默跳过）。
- 远端后端通过 `tests/stub` 的本地桩验证（native-only）；CI 另跑真实 Qdrant 容器（v1.14.0）集成作业。

## 参考与规范来源

- 参考规范：Qdrant REST API / OpenAPI 3.0（https://github.com/qdrant/qdrant），REST v2 语义，以 v1.14 系列 OpenAPI 为准。
- 本项目为原创实现，不复制 Qdrant 源码；仅声明 API 规范来源。
- 详细设计决策、ADR 与已知差异登记见 `DEVELOPMENT.md`。

## License

本项目采用 Apache-2.0 许可证，详见 [LICENSE](LICENSE)。
