# MoonVec 开发文档

> 本文档是 MoonVec 项目的**开发基准（baseline）**，后续所有实现、评审与验收均以本文档为准。
> 与 [PROPOSAL.md](./PROPOSAL.md) 的关系：申报书定义「做什么、为什么做」；本文档定义「怎么做、做到什么程度算完成」。
> 若两者冲突，以本文档为实现依据，并回写申报书。

| 元信息 | 值 |
| --- | --- |
| 文档版本 | v1.4 |
| 文档日期 | 2026-10-15 |
| 对应申报书 | PROPOSAL.md |
| 模块名 | `lexchb/moon_vector`（Q2 已定稿，见 15 节） |
| 许可证 | Apache-2.0 |
| 已验证工具链 | `moon 0.1.20260920` / `moonc 0.10.14` + `moonbitlang/async 0.22.1`（详见 13.2） |
| 已验证目标 | `native` / `js` / `wasm`（`wasm-gc` 仅能编译，`async test` 不执行，见 13.3） |
| 当前进度 | M0、M1、M2 已完成（M2 见 13.5；`src/core` + `src/local` + `conformance` 三目标全绿） |

> 包路径勘误（v1.4）：MoonBit 的包名是「模块名 + 目录路径」，因此 `src/core` 的真实包名是
> **`lexchb/moon_vector/src/core`**（而不是 v1.3 里写的 `lexchb/moon_vector/core`）。
> 依据是 `moon info` 生成的 `src/core/pkg.generated.mbti` 第 2 行。跨包 `import` 必须用完整包名。

---

## 1. 文档使用规则

1. **单一事实来源**：公共 API 的形状、错误语义、跨后端行为，只在本文档描述。代码是实现，本文件是契约。
2. **先改文档，再改代码**：任何公共接口变更（新增/改名/改签名/改语义），必须先修改本文档对应小节并在「变更记录」留痕，然后才能提交实现代码。
3. **接口冻结**：每个里程碑结束时执行 `moon info`，生成并提交 `.mbti` 接口文件；`.mbti` 的 diff 视同 API 变更，需走第 2 条流程。
4. **不确定项**：未决问题统一登记在第 15 节「开放问题」，不允许在代码里留隐式约定。

### 变更记录

| 版本 | 日期 | 变更内容 | 作者 |
| --- | --- | --- | --- |
| v1.0 | 2026-10-14 | 初版，由申报书展开 | — |
| v1.1 | 2026-10-14 | M0 技术验证完成，按实测回填第 2.3 / 6 / 7 / 8 / 11 / 13 / 14 / 15 / 16 节；新增 13.2 验证记录 | — |
| v1.2 | 2026-10-14 | 定稿 Q2（模块名改为 `lexchb/moon_vector`）与 Q10（`@async.Mutex` 可用）；发现 `wasm-gc` 下 `async test` 不执行，可运行目标修正为 `wasm`；新增 13.3 | — |
| v1.3 | 2026-10-14 | M1 完成：`src/core` 落地并三目标全绿；定稿 Q3/Q4/Q5/Q7/Q11；修正 API 声明（`pub(open) trait` / `pub(all) enum`）与 `PointId` 位宽；新增约束 5 与 13.4 | — |
| v1.4 | 2026-10-15 | M2 完成：`src/local` 与 `conformance` 落地并三目标全绿；定稿 Q6（Cosine 零向量 → 固定分 1.0）与 Q8（强类型 payload 顺延出 M2）；**勘误两处**：`retrieve` 返回 `Array[StoredPoint]`（v1.3 误写 `ScoredPoint`）、包名为 `lexchb/moon_vector/src/core`；新增 9.5 错误语义表、9.6 过滤求值细则与 13.5 | — |

> **M0 已验证的关键结论（一句话）**：trait 可以声明 `async fn`；JSON 手写编解码可行且 struct 的 `Option` 字段由 `derive` 自动省略；`@http` 在 native 下连通、超时与显式重试均可行，但**库自带 `@async.retry` 会把错误类型擦除为抽象 `Error`**，故重试改为显式循环。

---

## 2. 目标与非目标

### 2.1 目标（可验收）

| 编号 | 目标 | 验收方式 |
| --- | --- | --- |
| G1 | 提供与后端无关的向量检索抽象层（`VectorStore`） | 存在公共 trait，且 `remote` / `local` 两个实现均可替换注入 |
| G2 | 提供基于 Qdrant REST v2 的远端后端 | 对真实 Qdrant 容器跑通「建集合→写入→检索→过滤→分页→删除」全流程 |
| G3 | 提供纯内存本地后端 | 无任何外部依赖，在 `native` / `js` / `wasm` 三个目标下均可运行并通过一致性测试 |
| G4 | 过滤条件用类型安全构造器表达，而非手写 JSON | 过滤 DSL 覆盖 `must` / `should` / `must_not` 嵌套与 `match` / `range` / `geo` / `nested` / `has_id` 等条件 |
| G5 | 传输层具备超时、重试退避、错误映射 | 有可配置策略；HTTP 4xx/5xx 映射为具名错误，可被 `catch` 精确分辨 |
| G6 | 支持并发批量写入与检索 | 基于 `@async.all(jobs, max_concurrent=n)`（实测内置有界并发），并发度可配置，失败可整组取消 |
| G7 | 两个后端行为一致 | 同一套一致性测试（conformance suite）对两后端都通过 |
| G8 | 可发布 | `moon add` 可用，发布至 mooncakes.io，README + 至少一个可运行示例 |

### 2.2 非目标（明确不做）

- gRPC / HTTP-2 / protobuf 传输。
- embedding 生成、LLM 调用、rerank。
- 集群运维 API（快照、分片迁移、集群管理、租户管理）。
- 服务端实现与高级索引算法（本地后端只做暴力检索，不实现 HNSW/IVF）。
- 其他向量引擎（Milvus / Weaviate 等）；仅在抽象层保留语义，不提供实现。
- 本地后端支持 Query API 的 `prefetch` / 多阶段融合（fusion、rerank）。

### 2.3 与技术现实对齐的五条约束（重要，均已实测）

这五条会直接改变实现方式，作为设计前提写入基准（证据见 13.2 / 13.3 / 13.4）：

1. **只有 IO 是 native-only，`async` 本身可跨目标。** `moonbitlang/async` 的 http/https/fs/socket 等 IO API 不支持 JS 后端，但 task group / `sleep` / `all` / `Mutex` / `Semaphore` 等非 IO API 在 `js` 与 `wasm`（Wasm1）上可用（实测 `async test` 在 `js` 与 `wasm` 目标下正常执行）。因此：
   - **远端后端必须 native-only**（`supported_targets = "native"`，实测该声明会使该包从 js/wasm 构建中被正确排除）；
   - **`core` 与 `local` 可以跨 `native` / `js` / `wasm`**——因为 `VectorStore` 契约是 `async` 的（非 IO），在这些目标上完全成立。申报书中「纯 MoonBit 可编译到 native/js/wasm」据此成立。
   - **但 `wasm-gc` 例外**：`async test` 在该目标下**不会被测试运行器执行**（实测：包能编译，但只跑同步测试，异步测试静默不跑）。故**可运行验证目标定为 `native` / `js` / `wasm`**；`wasm-gc` 仅作为编译面保证（详见 13.3）。
2. **`@async` 仍标注 experimental，且版本与工具链强耦合。** 实测：`async` 最新版（0.22.5，2026-10-14 发布）的 `moon.pkg` 含本机工具链（2026-09-20）不认识的键 `max_concurrent_tests`，**直接无法构建**；回退到 0.22.1 后一切正常。故工具链与 `async` 必须**成对锁定**并写入 CI（见 11.1）。这正是传输层要做薄、不对外暴露 `@http` 类型的原因。
3. **`derive` 只覆盖结构体，联合类型必须手写。** Qdrant 多处使用**非外部标签（untagged）**的联合类型（`PointId` 是裸数字或裸字符串；`match` 是 `{"value":..}` / `{"any":..}` / `{"except":..}` / `{"text":..}`）。默认 `derive(ToJson, FromJson)` 生成外部标签形式 `{"CaseName": ...}`，**语义不兼容**。实测结论（7.3）：
   - 联合类型（`PointId` / `MatchValue` / `Clause`）→ **必须手写**；
   - 结构体（含 `Double?` 这类可空字段）→ `derive` 即可，**实测会自动省略值为 `None` 的字段**，与 Qdrant 期望一致。
4. **MoonBit 没有字段默认值，也没有部分记录。** 实测 `field : T? = None` 解析失败，结构体字面量必须给全部字段。因此凡有「可省略字段」的结构体，都必须额外提供**可选参数构造器**（如 `RangeSpec::new(gte=0.5, lt=0.9)`），否则调用方体验不可接受。同理，枚举的具名字段必须写成 `Name(field~ : T)`，且构造时必须带标签。
5. **可见性修饰符决定抽象层生死（M1 实测，最容易踩）。** MoonBit 的默认可见性是「readonly」，必须显式放宽，否则外部包连构造都做不到：
   - **`pub(open) trait`**：裸 `pub trait` 是 readonly 的，**外部包无法实现它**（编译报 `Cannot implement trait ... because it is readonly`）。`VectorStore` 若写成 `pub`，local / remote 与用户自定义后端全都无法实现，抽象层直接失效。
   - **`pub(all) enum`**：裸 `pub enum` 的构造器对外不可见，外部包报 `Cannot create values of the read-only type: X`。所有面向用户构造的枚举（`Distance` / `PointId` / `MatchValue` / `Condition` / `Clause` / `PayloadSchema` / `UpsertResult`）都必须 `pub(all)`。
   - **`pub(all) suberror`**：同理，否则用户的 `catch` 无法用构造器模式精确分辨错误。
   - 这类错误只在**跨包使用时**才会暴露；同包内（含白盒测试 `_wbtest.mbt`）一切正常，很容易漏检。因此 12.1 要求每个公共类型都要有**黑盒测试**覆盖其构造。

---

## 3. 术语与版本约定

| 术语 | 含义 |
| --- | --- |
| Point | Qdrant 中的一条记录：`id` + `vector` + `payload` |
| Payload | 与向量同存的任意 JSON 元数据，用于过滤 |
| Collection | 一组同维度、同距离度量的 Point |
| Distance | 距离度量：`Cosine` / `Euclid` / `Dot` / `Manhattan` |
| Clause | `must` / `should` / `must_not` 数组中的一个元素，可以是单条件，也可以是嵌套 Filter |
| Condition | 单个过滤条件，如 `match` / `range` / `geo_bounding_box` |
| ScoredPoint | 检索结果：`id` + `score` + 可选 `payload` / `vector` |
| 一致性测试 | 对任意 `VectorStore` 实现都应通过的同一套行为断言 |

版本约定：

- Qdrant REST API：以 **v1.14 系列** 的 OpenAPI 为准，锁定为 `REST v2` 语义；`points/search` 视为**已弃用**，主路径走 `points/query`。README 须声明最低 Qdrant 版本（1.10+，因 `query` 端点）。
- MoonBit 工具链：**锁定 `moon 0.1.20260920` / `moonc 0.10.14`**（本机实测可用版本），写入 CI 配置；版本变更必须先跑全量测试。
- `moonbitlang/async`：**锁定 `0.22.1`**。已实测 0.22.5（晚于本机工具链 20 余天）无法构建，故**不得使用 `moon add` 的默认最新版**，必须在 `moon.mod` 中显式写死版本。升级 `async` 必须与工具链同批升级并跑全量测试。
- 语义化版本：本库自身遵循 SemVer 2.0.0（mooncakes 要求）。

---

## 4. 总体架构

### 4.1 分层

```
┌─────────────────────────────────────────────┐
│  examples/               用户代码 / 示例      │
├─────────────────────────────────────────────┤
│  core/    抽象层（跨目标，零依赖外部服务）     │
│   ├─ types     向量、ID、配置、结果           │
│   ├─ filter    过滤 DSL（ADT + JSON 编解码）  │
│   ├─ error     错误类型                       │
│   └─ store     VectorStore trait（契约）      │
├──────────────────┬──────────────────────────┤
│  local/          │  remote/                 │
│  纯内存暴力 kNN   │  Qdrant REST 后端         │
│  可跨 js/wasm    │  native-only             │
│                  │   ├─ endpoints  路径/请求体映射
│                  │   ├─ transport  Client/超时/重试
│                  │   └─ convert    线上 DTO ⇄ core 类型
├──────────────────┴──────────────────────────┤
│  @async / @http / @json   （第三方，仅被 remote 引用）│
└─────────────────────────────────────────────┘
```

### 4.2 依赖方向（硬约束）

- `core` **不得**依赖 `@http`、`@async` 的 IO 部分、`local`、`remote`。
- `local` 只依赖 `core` + `@async`（**M2 实测修正**：`MemoryStore` 内部持有 `@async.Mutex`，故 `async` 是 local 的**正式运行时依赖**，与 core 的 `for "test"` 不同）。local 不使用 `@json` 的函数式 API（`Json` 类型与其智能构造器来自内建，无需 import）。
- `remote` 依赖 `core` + `@async` + `@async/http`，且 `supported_targets = "native"`。
- `core` 与 `local` 不做 target 限制，须在 `js` / `wasm` / `native` 全部通过测试（`wasm-gc` 只要求 `moon check` 通过）。
- 禁止反向依赖，禁止 `core` 里出现任何 Qdrant 专有字段名。
- 包名一律按「模块名 + 目录路径」书写，即 `lexchb/moon_vector/src/core`、`lexchb/moon_vector/src/local`、`lexchb/moon_vector/conformance`（见元信息勘误）。

> 这条约束是「抽象层不暴露 Qdrant 特有数据结构」的项目通用性承诺在工程上的落地方式。

### 4.3 双类型体系（core 类型 vs 线上 DTO）

`core` 用**面向使用者的、后端无关的**类型（如 `SearchRequest`）；`remote` 内部另有一套**紧贴 Qdrant JSON 的** DTO（如 `QdrantSearchRequest`）。二者在 `convert.mbt` 中显式转换，**不做零成本复用**。

理由：复用同一套结构体会导致 Qdrant 字段名（`with_payload`、`score_threshold`、`next_page_offset`）泄漏到公共 API，一旦将来接入其他引擎就无法兼容。多写一层转换的成本，换取抽象层的可扩展性。

---

## 5. 包结构

```
moonbit-Qdrant/
├── moon.mod                 # 模块配置（lexchb/moon_vector）
├── LICENSE                  # Apache-2.0
├── README.md
├── DEVELOPMENT.md           # 本文档
├── .gitignore / .gitattributes
├── src/
│   ├── core/                # lexchb/moon_vector/src/core
│   │   ├── moon.pkg
│   │   ├── types.mbt
│   │   ├── distance.mbt
│   │   ├── filter.mbt
│   │   ├── json_codec.mbt
│   │   ├── error.mbt
│   │   └── store.mbt
│   ├── local/               # lexchb/moon_vector/src/local   (M2)
│   │   ├── moon.pkg
│   │   ├── memory.mbt          # MemoryStore + MemCollection + VectorStore 实现
│   │   ├── distance.mbt        # 四度量 + 零向量约定
│   │   ├── filter_eval.mbt     # Filter 求值
│   │   └── path.mbt            # payload 路径解析（点号 + `[]`）
│   └── remote/              # lexchb/moon_vector/src/remote   (M3, supported_targets = "native")
│       ├── moon.pkg
│       ├── dto.mbt
│       ├── convert.mbt
│       ├── endpoints.mbt
│       ├── transport.mbt
│       └── qdrant.mbt
├── conformance/             # lexchb/moon_vector/conformance    (M2)
│   ├── moon.pkg
│   └── suite.mbt            # run_conformance(store, prefix) -> Array[String]
├── examples/
│   ├── local_search/        # 纯本地，js/wasm 可跑
│   └── qdrant_rag/          # native，需要 Qdrant 服务
├── tests/
│   └── integration/         # Docker 集成测试
└── .github/workflows/ci.yml
```

测试文件放置（MoonBit 约定，就近）：

- `xxx_test.mbt`：**黑盒测试**，位于对应包目录内，只能访问 `pub` 成员。
- `xxx_wbtest.mbt`：**白盒测试**，可访问包内非 `pub` 成员（仅用于算法内部验证，如距离函数、路径解析）。

---

## 6. 抽象层核心类型（`core`）

以下为**目标形状**，非最终实现；签名允许在 M0/M1 期间调整，但调整后必须更新本文档。

### 6.1 基础类型

> **语法约束（实测）**：结构体字面量必须写全所有字段（无部分记录），枚举的具名字段必须写成 `field~ : T`。凡字段可省略的类型，一律附带可选参数构造器。

```moonbit
///| 距离度量，与 Qdrant 的 Distance 枚举一一对应
pub(all) enum Distance {
  Cosine
  Euclid
  Dot
  Manhattan
} derive(Eq, Show)

///| 向量
pub type Vector = Array[Double]

///| 点 ID：Qdrant 支持无符号整数或 UUID 字符串
///  用 UInt64：Qdrant 的随机 ID 会超出 2^63-1，Int64 会读不回来
///  ToJson / FromJson 手写（裸值 + 大整数保精度），见 7.3
pub(all) enum PointId {
  Num(UInt64)
  Uuid(String)
} derive(Eq, Hash)

pub fn PointId::of_int(n : UInt64) -> PointId {
  Num(n)
}

pub fn PointId::of_uuid(s : String) -> PointId {
  Uuid(s)
}

///| Payload：任意 JSON 对象
pub type Payload = Map[String, Json]

///| 集合的向量配置
pub(all) struct VectorConfig {
  size : Int            // 向量维度
  distance : Distance   // 距离度量
  on_disk : Bool        // 是否落盘（仅远端生效）
} derive(Eq)

pub fn VectorConfig::new(
  size~ : Int,
  distance~ : Distance,
  on_disk? : Bool = false,
) -> VectorConfig {
  { size, distance, on_disk }
}

///| 检索结果
pub(all) struct ScoredPoint {
  id : PointId
  score : Double
  payload : Payload?
  vector : Vector?
} derive(Eq)

pub fn ScoredPoint::new(
  id~ : PointId,
  score~ : Double,
  payload? : Payload,
  vector? : Vector,
) -> ScoredPoint

///| 分页条目的存储形态（无相关性分数）
pub(all) struct StoredPoint {
  id : PointId
  payload : Payload?
  vector : Vector?
} derive(Eq)

pub fn StoredPoint::new(
  id~ : PointId,
  payload? : Payload,
  vector? : Vector,
) -> StoredPoint

///| payload 索引的类型（对应 Qdrant 的 field_schema）
///  变体名用 Boolean 而非 Bool：后者会遮蔽内建 Bool 的构造器解析
pub(all) enum PayloadSchema {
  Keyword
  Integer
  Float
  Boolean
  Geo
  Text
} derive(Eq)
```

> 说明：`VectorConfig` / `ScoredPoint` / `StoredPoint` 等含可选字段的结构体都提供可选参数构造器（约束 4）。`derive(Eq)` 便于一致性与往返测试；`PointId` 额外 `derive(Hash)` 以便 M2 用它做 `Map` 键（9.1）。

### 6.2 检索与分页请求

```moonbit
///| 相似度检索请求
pub(all) struct SearchRequest {
  vector : Vector
  filter : Filter?
  limit : Int
  score_threshold : Double?
  with_payload : Bool
  with_vector : Bool
}

pub fn SearchRequest::new(
  vector~ : Vector,
  limit~ : Int,
  filter? : Filter,
  score_threshold? : Double,
  with_payload? : Bool = true,
  with_vector? : Bool = false,
) -> SearchRequest {
  { vector, filter, limit, score_threshold, with_payload, with_vector }
}

///| 分页遍历请求（不依赖相似度）
pub(all) struct ScrollRequest {
  filter : Filter?
  limit : Int
  offset : PointId?
  with_payload : Bool
  with_vector : Bool
}

pub fn ScrollRequest::new(
  limit~ : Int,
  filter? : Filter,
  offset? : PointId,
  with_payload? : Bool = true,
  with_vector? : Bool = false,
) -> ScrollRequest {
  { filter, limit, offset, with_payload, with_vector }
}

///| 分页结果，持有下一页游标（scroll 无相关性分数，故用 StoredPoint）
pub(all) struct ScrollPage {
  points : Array[StoredPoint]
  next_offset : PointId?
}
```

### 6.3 写入与批量

```moonbit
///| 待写入点
pub(all) struct Point {
  id : PointId
  vector : Vector
  payload : Payload?
}

///| 批量写入的结果（逐条或整体）
pub(all) enum UpsertResult {
  All              // 全部成功
  Partial(failed : Array[PointId])  // 部分失败
}
```

### 6.4 `VectorStore` 契约

```moonbit
///| 必须是 pub(open)：裸 pub trait 是 readonly 的，外部包无法实现
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
  async fn retrieve(Self, collection : String, ids : Array[PointId], with_payload : Bool, with_vector : Bool) -> Array[StoredPoint] raise VectorStoreError
  async fn search(Self, collection : String, req : SearchRequest) -> Array[ScoredPoint] raise VectorStoreError
  async fn scroll(Self, collection : String, req : ScrollRequest) -> ScrollPage raise VectorStoreError

  // 索引
  async fn create_payload_index(Self, collection : String, field : String, schema : PayloadSchema) -> Unit raise VectorStoreError
}
```

> **v1.4 勘误**：`retrieve` 的返回类型是 `Array[StoredPoint]`（v1.3 误写为 `ScoredPoint`）。按 ID 取点没有相关性，不应凭空造一个 `score` 字段；M1 的实现（`core/types.mbt` 的 `StoredPoint`）与本节现已一致。
>
> **Q1 已定稿（实测通过）**：MoonBit **支持** trait 中声明 `async fn`。已在本机工具链上验证四种用法全部可用：
> ① 作为泛型上界 `fn[T : VectorStore] f(s : T, ..)`；② 以 trait object 动态派发 `s : &VectorStore` 并调用其方法；③ 不同实现可互换；④ **可实现性跨包成立**（须 `pub(open)`，见约束 5）。
> **不采用**原备选方案（函数字段记录）。
>
> **配套要求（M1 已实测生效，47 → 0 告警）**：本工具链已弃用「trait 实现的方法被隐式提升为普通方法」（告警 `implicit_impl_as_method`）。因此每个实现方都必须显式声明：
>
> ```moonbit
> pub extend MemoryStore with VectorStore::{
>   create_collection, delete_collection, collection_exists, describe_collection,
>   upsert, delete_points, delete_by_filter, retrieve, search, scroll,
>   create_payload_index,
> }
> ```
>
> 否则只能写 `VectorStore::search(store, ...)`。此声明是**公共 API 易用性的一部分**，须随 `.mbti` 一起评审。
> 注意：同一份 `extend` 也适用于本库**自身为内建 trait 写的实现**（`Eq` / `Hash` / `Show` / `ToJson` / `FromJson`），因此 `core/extends.mbt` 集中列出了所有声明（这是 M1 消除 47 个告警的唯一手段，见 13.4）。

### 6.5 门面类型

远端与本地后端各自是一个持有连接/状态的结构体，并提供构造器：

```moonbit
pub(all) struct QdrantStore { /* private */ }

pub fn QdrantStore::new(
  url~ : String,
  api_key? : String,
  options? : TransportOptions = TransportOptions::default(),
) -> QdrantStore

pub(all) struct MemoryStore { /* private */ }

pub fn MemoryStore::new() -> MemoryStore
```

`MemoryStore::new()` 必须**不引入任何 IO 依赖**，以保证能在 `js` / `wasm` 下实例化（已实测 `async` 的非 IO 部分在这些目标下可运行，见 13.3）。

---

## 7. 过滤 DSL 与 JSON 编解码（核心工程量之一）

### 7.1 设计目标

用户应能这样写过滤，而不是手拼 JSON：

```moonbit
let f = Filter::new(
  must= [
    Condition::match_str("tenant_id", "acme"),
    Condition::range("score", gte=0.5, lt=0.9),
  ],
  must_not= [
    Condition::match_any("doc_type", ["draft", "trash"]),
  ],
)
```

### 7.2 类型定义

Qdrant 的 Filter 结构：三个子句数组，**每个元素既可以是单条件，也可以是嵌套的 Filter**。用 ADT 精确建模：

```moonbit
pub(all) struct Filter {
  must : Array[Clause]?
  should : Array[Clause]?
  must_not : Array[Clause]?
}

///| 注意：具名字段必须写 field~ : T，构造时必须带标签；枚举必须 pub(all)
pub(all) enum Clause {
  Cond(condition~ : Condition)
  Group(filter~ : Filter)
} derive(Eq)

pub(all) enum Condition {
  Match(key~ : String, value~ : MatchValue)
  Range(key~ : String, spec~ : RangeSpec)
  GeoBoundingBox(key~ : String, box~ : GeoBox)
  GeoRadius(key~ : String, spec~ : GeoRadiusSpec)
  ValuesCount(key~ : String, spec~ : ValuesCountSpec)
  IsEmpty(key~ : String, value~ : Bool)
  IsNull(key~ : String, value~ : Bool)
  HasId(ids~ : Array[PointId])
  Nested(key~ : String, filter~ : Filter)
} derive(Eq)

pub(all) enum MatchValue {
  Value(Json)          // {"value": <scalar>}
  Any(Array[Json])     // {"any": [...]}
  Except(Array[Json])  // {"except": [...]}
  Text(String)         // {"text": "..."}
} derive(Eq)

///| derive 即可：实测 Double? 字段值为 None 时会被自动省略
pub(all) struct RangeSpec {
  gt : Double?
  gte : Double?
  lt : Double?
  lte : Double?
} derive(Eq, ToJson, @json.FromJson)

///| 必须提供可选参数构造器（结构体字面量不能部分赋值）
pub fn RangeSpec::new(
  gt? : Double,
  gte? : Double,
  lt? : Double,
  lte? : Double,
) -> RangeSpec {
  { gt, gte, lt, lte }
}
```

> **务必使用上述构造器**：`RangeSpec::new(gte=0.5, lt=0.9)` 可读且不易错；直接写结构体字面量必须写全 `{ gt: None, gte: Some(0.5), lt: Some(0.9), lte: None }`，冗长且容易漏字段。

### 7.3 JSON 编解码：derive 与手写的分工（M0 实测结论）

| 类型 | 方式 | 输出形状（实测） |
| --- | --- | --- |
| `RangeSpec`、`GeoBox`、`ValuesCountSpec` 等**结构体**（含 `Double?` 字段） | `derive(ToJson, FromJson)` | 字段名直接映射；**值为 `None` 的字段被自动省略**（实测 `{ gte: None, lt: Some(0.9) }` → `{"lt":0.9}`） |
| `Filter` | `derive`（三个子句都是 `Array[Clause]?`，省略语义天然正确） | `{"must":[...]}`，空子句省略 |
| `PointId` | **手写** | `42` 或 `"uuid-str"`（裸值，非 `{"Num":42}`） |
| `MatchValue` | **手写** | `{"value":..}` / `{"any":[..]}` / `{"except":[..]}` / `{"text":..}` |
| `Condition` | **手写** | 展平为 `{"key":.., "<子对象名>": {..}}`，例如 `{"key":"c","match":{"value":"x"}}` |
| `Clause` | **手写** | `Cond` 内联 Condition；`Group` 内联嵌套 Filter |

理由：`derive` 只能生成外部标签（`{"Cond": {...}}`），与 Qdrant 期望的**内联/展平**形状不符；而结构体字段的 `None` 省略语义恰好与 Qdrant 一致，无需手写。

**手写编解码的四条强制写法（实测踩坑）**：

1. **不能直接构造 `Json` 的变体**。`Number` / `String` / `Object` / `Array` 是只读类型，`Json(42)` 之类的变体构造会报 `Cannot create values of the read-only type`。必须用智能构造器：`Json::number(d)`、`Json::string(s)`、`Json::object(map)`、`Json::array(arr)`、`Json::null()`、`Json::boolean(b)`。**模式匹配（`json is Object(m)`）不受影响，仍可正常使用**。
2. **整数类型的默认 `ToJson` 输出的是字符串**（`impl ToJson for Int64/UInt64 { self.to_string() }`），并非数字。因此 Qdrant 的整数 ID 必须用 `Json::number(n.to_double(), repr=n.to_string())` —— `repr` 用于保留精确数字字面量，避免大于 2^53 的 ID 丢失精度（M1 实测 `9007199254740993` 与 u64 满量程 `18446744073709551615` 都能原样编解码）。**反序列化同理**：必须优先读 `Number(n, repr~)` 的 `repr` 并自己精确解析十进制，退回 `n.to_uint64()` 只对 ≤ 2^53 的值安全（M1 为此实现了私有 helper `parse_decimal_uint64`）。
3. **`@json.decode_error` 是私有函数**，不可调用。抛错必须显式构造：`raise @json.JsonDecodeError((path, "消息"))`，其中 `path` 来自 `from_json` 的入参，可用 `path.add_key("match")` 逐层加深。
4. **`ToJson` / `FromJson` 都是 `pub(open)` trait**，可以为本库自定义类型实现，但实现后同样受 `implicit_impl_as_method` 告警约束（见 6.4）。

**约束**：手写编解码只允许出现在 `core/json_codec.mbt` 一个文件内（该文件现有 6 个手写编解码：`PointId` / `Distance` / `PayloadSchema` / `MatchValue` / `Condition` / `Clause`，外加一个精确解析 u64 的私有 helper），且必须有双向往返测试（M1 实测：往返测试确实抓到了 `Clause` 判别逻辑把 `{"has_id":[..]}` 误判为嵌套 Filter 的真实 bug）：

```moonbit
test "filter json roundtrip" {
  let f = /* ... */
  let json = @json.to_json(f)
  let back : Filter = @json.from_json(json) catch { _ => Filter::empty() }
  if back != f { fail("roundtrip 失败") }
}
```

> 注：断言建议直接比较**线上 JSON 字符串**（`@json.to_json(x).stringify()`），而不是比较结构体。一是能直接看到线上格式，二是在同时导入 `core/json` 的包中 `inspect` 会发生重载歧义（内置 `inspect` 与 `json_inspect` 同别名）。

### 7.4 本地后端的过滤求值

`local/filter_eval.mbt` 需把同一套 Filter 应用于 `Map[String, Json]`。语义与 Qdrant 对齐的部分：

- `must`：全部为真才通过；`should`：至少一个为真（若 `should` 非空，则**恒定**要求至少一个为真，即使 `must` 非空）；`must_not`：全部为假才通过。
- 缺失 key 的条件一律判定为 **不匹配**（与 Qdrant 一致）——**唯一例外见 9.6 的 `is_null(value=true)`**。

**路径语义的范围限定（明确划线）**：

- 支持：点号嵌套路径 `a.b.c`。
- 支持：数组展开后缀 `a.b[].c`（展开后任一元素满足即视为满足）。
- 不支持：`[0]` 之类的显式下标、通配符、空段（`a..b`、前后点号）。遇到不支持形式返回 `VectorStoreError::Unsupported`，**不得静默返回不匹配**。
- 该差异必须在共享 README 的「已知差异」小节中公开，避免用户误判。

> 逐个 Condition 的完整求值规则（含数组元素语义、geo 是否实现、`is_empty` / `is_null` 的缺失 key 例外）在 **9.6** 定稿；本节只声明路径语义的边界。

---

## 8. 远端后端（`remote`，native-only）

### 8.1 端点映射表（REST v2）

| 抽象操作 | HTTP | 路径 | 关键请求字段 | 关键响应字段 |
| --- | --- | --- | --- | --- |
| `create_collection` | PUT | `/collections/{c}` | `vectors.size`、`vectors.distance`、`vectors.on_disk` | — |
| `describe_collection` | GET | `/collections/{c}` | — | `result.config.params.vectors.{size,distance}` |
| `delete_collection` | DELETE | `/collections/{c}` | — | — |
| `collection_exists` | GET | `/collections/{c}` | — | 200 存在 / 404 不存在 |
| `create_payload_index` | PUT | `/collections/{c}/index` | `field_name`、`field_schema` | — |
| `upsert` | PUT | `/collections/{c}/points?wait={bool}` | `points[]{id,vector,payload}` | `result.status` |
| `delete_points` | POST | `/collections/{c}/points/delete?wait={bool}` | `points[]`（ID 列表） | `result.status` |
| `delete_by_filter` | POST | `/collections/{c}/points/delete?wait={bool}` | `filter` | `result.status` |
| `retrieve` | POST | `/collections/{c}/points` | `ids[]`、`with_payload`、`with_vector` | `result[]` |
| `search` | POST | `/collections/{c}/points/query` | `query`（裸向量或 `{"nearest": ...}`）、`filter`、`limit`、`score_threshold`、`with_payload`、`with_vector` | `result.points[]` |
| `scroll` | POST | `/collections/{c}/points/scroll` | `limit`、`offset`、`filter`、`with_payload`、`with_vector` | `result.points[]`、`result.next_page_offset` |

**必须注意的两个形状陷阱**（M0 已用本地桩验证解析可行，见 13.2）：

1. **响应包裹层不一致**：`retrieve` 的 `result` 是**数组**、`scroll` 的 `result` 是**对象** `{points, next_page_offset}`、`query` 的 `result` 又是**对象** `{points: [...]}`。`convert.mbt` 需分别处理，禁止一套反序列化代码通吃。
2. **scroll 无相关性分数**：故 `scroll` 结果不复用 `ScoredPoint`，另定义 `StoredPoint`（无 score），见 6.1。

> 说明：`points/search` 端点已被 `points/query` 取代（`query` 覆盖 search/recommend/discover 的全部能力），本项目**只实现 `query`**，不实现已弃用的 `search` 端点，以降低维护面。

### 8.2 传输层设计（API 已按实测的 `@http` 签名校正）

```moonbit
pub(all) struct TransportOptions {
  base_url : String             // 如 "http://localhost:6333"
  api_key : String?             // 放入 api-key 头
  timeout_ms : Int              // 单次请求超时，默认 5000
  max_retry : Int               // 重试次数上限，默认 3
  retry_initial_ms : Int        // 指数退避初值，默认 20
  retry_factor : Double         // 退避倍数，默认 2.0
  retry_max_ms : Int            // 退避上限，默认 1000
  max_concurrency : Int         // 批量操作并发上限，默认 4
}

pub fn TransportOptions::default() -> TransportOptions
```

**实测确认的可用 API**（`moonbitlang/async 0.22.1`，逐条来自 `pkg.generated.mbti`）：

| 需求 | 可用 API |
| --- | --- |
| 连接复用 | `@http.Client::Client(base_url)`；`QdrantStore` 持有一个实例，`defer client.close()` |
| 发请求 + 收响应 | `client.request(verb, path, extra_headers=headers)` 返回 `Unit`，随后 `client.end_request()` 得 `Response` |
| 读响应体 | `client.read_all()` → `&Data`，再 `&Data::text()` 得 `String`；`Response` 有 `code` / `reason` / `headers` |
| HTTP 方法 | `@http.RequestMethod` 枚举：`Get` / `Post` / `Put` / `Delete` 等 |
| 请求头 | `Map[@http.CaseInsensitiveString, String]`，键用 `@http.CaseInsensitiveString("api-key")` 构造；实测自定义头能正确透传 |
| 超时 | `@async.with_timeout(ms, fn)`；实测 300ms 对 3s 慢响应能正确触发 |
| 并发批量 | `@async.all(jobs, max_concurrent=n)` —— **内置有界并发，无需手搓 TaskGroup 分片** |
| 互斥锁 | `@async.Mutex::{Mutex, acquire, release, try_acquire}`（`acquire` 是 async） |
| 限流 | `@async.Semaphore::Semaphore(n)` |

**重试：采用显式重试循环，不用 `@async.retry`（M0 关键结论）**。

实测发现 `@async.retry(...)` 的签名是 `retry(RetryMethod, max_retry?, fatal_error? : (Error) -> Bool, async () -> X) -> X`，会带来两个无法回避的问题：

1. **错误类型被擦除**：整个表达式的错误类型变成抽象 `Error`，与函数声明 `-> T raise VectorStoreError` 冲突（编译报 `The error type is mismatched: wanted VectorStoreError, has Error`）。
2. **`fatal_error` 无法甄别错误**：其参数是抽象 `Error`，而抽象 `Error` **不支持 suberror 构造器模式匹配**（编译报 `The type Error is a abstract type and not an enum`）。也就是说，无法实现「4xx 不重试」这条必需策略。

因此重试逻辑手写为一个显式循环（实测通过：对连续两次 503 的端点，第三次成功）：

```moonbit
async fn send_with_retry(client : @http.Client, verb : @http.RequestMethod, path : String) -> Json raise VectorStoreError {
  let mut attempt = 0
  let mut last : VectorStoreError? = None
  while attempt <= options.max_retry {
    try {
      return send_once(client, verb, path)
    } catch {
      Http(status~, message~) as e => {
        // 4xx（429 除外）是语义错误，重试无意义，立刻上抛
        if status >= 400 && status < 500 && status != 429 {
          raise e
        }
        last = Some(e)
      }
      e => last = Some(e)
    }
    attempt = attempt + 1
    if attempt <= options.max_retry {
      @async.sleep(backoff_ms(attempt))   // 指数退避，带上限
    }
  }
  match last {
    Some(e) => raise e
    None => raise Transport(message="重试耗尽但无错误记录")
  }
}
```

**其余实现要点**：

- **幂等性红线**：`create_collection` / `delete_collection` / `delete_by_filter` 这类带副作用且**非天然幂等**的操作默认不重试（把 `max_retry` 视为 0）；`upsert`（按 ID 覆盖，幂等）、`retrieve` / `search` / `scroll`（只读）才启用重试。
- **可重试判定**：仅连接失败、读超时、`429` / `502` / `503` / `504`。
- **响应体上限**：`read_all()` 是一次性读入，大响应存在内存风险，故须在解析前检查 `Content-Length` 或读入后校验长度上限（默认 32MB，超限报 `Decode`）。
- **不在公共 API 暴露 `@http` 类型**：`TransportOptions` 只含原始类型，`QdrantStore` 的内部 client 字段私有。

### 8.3 HTTP 状态码到错误的映射

| 状态码 | 映射 |
| --- | --- |
| 200 / 201 / 202 | 成功 |
| 400 | `InvalidArgument(message)` |
| 401 / 403 | `Auth(message)` |
| 404 | `NotFound(resource)` |
| 409 | `Conflict(message)` |
| 429 | `RateLimited(retry_after_ms?)`，可重试 |
| 5xx | `Server(status, message)`，502/503/504 可重试 |
| 解码失败 | `Decode(message)` |

Qdrant 错误体形如 `{"status":{"error":"..."},"time":..,"result":null}`。实测确认：`message` 应优先取 `status.error`（桩返回 `{"status":{"error":"Collection \`missing\` doesn't exist!"}}` 时能精确取到整句），取不到再退回 `body.stringify()`。

### 8.4 错误类型（`core/error.mbt`，全后端共用）

```moonbit
///| pub(all)：否则用户的 catch 无法用构造器模式精确分辨错误
pub(all) suberror VectorStoreError {
  // 传输类
  Timeout(timeout_ms~ : Int)
  Transport(message~ : String)
  // 协议类
  Http(status~ : Int, message~ : String)
  Server(status~ : Int, message~ : String)
  Decode(message~ : String)
  // 领域类
  NotFound(resource~ : String)
  Conflict(message~ : String)
  Auth(message~ : String)
  RateLimited(retry_after_ms~ : Int?)
  // 契约类
  InvalidArgument(message~ : String)
  Unsupported(feature~ : String)   // 含本地后端不支持的过滤路径
}
```

> 注意：**suberror 的构造器字段也要写 `field~ : T`**，并且 suberror **不会自动获得 `Show`**，需要显式 `impl Show for VectorStoreError` 才能在 `\{e}` 插值中打印。

约束：**两个后端都必须能用这套错误表达失败**，以保证 `catch` 的用户代码在切换后端时不用改。本地后端不该抛 `Http` / `Decode`；远端后端抛 `Unsupported` 仅限真正的未实现能力。

---

## 9. 本地内存后端（`local`）

### 9.1 数据结构

```moonbit
// local 包内部（priv，不对外暴露）
priv struct MemCollection {
  config : VectorConfig
  points : Array[Point]           // 插入序；scroll 的游标语义依赖它
  index : Map[PointId, Int]       // ID → points 下标，O(1) retrieve / upsert
}

pub(all) struct MemoryStore {
  priv lock : @async.Mutex
  priv collections : Map[String, MemCollection]
}
```

- `Map[PointId, Int]`（ID → 下标）做 O(1) `retrieve` / upsert 覆盖；`PointId` 已 `derive(Eq, Hash)`。
- **插入序由 `points` 数组本身承载**，不额外维护 order 数组：upsert 覆盖同 ID 时**原位替换**（交替赋值），不改动插入位置，因此 `scroll` 游标在「覆盖写」下依然稳定。
- 删除点会打乱下标，故删除后**重建 index**（O(n)）；本地后端本就是 O(n) 暴力检索，可接受。
- 字段是 `priv`：外部只能通过 `MemoryStore::new()` 构造，无法触碰锁与内部集合（跨包时 `priv` 成员不可见，见 16.1）。

### 9.2 距离实现

| 度量 | 公式 | 本库 `score`（越小越近） | Qdrant 返回的 `score` | 二者关系 |
| --- | --- | --- | --- | --- |
| Cosine | `1 - cos(a,b)` | `1 - cos` | `cos`（越大越好） | 本库 = `1 - qdrant` |
| Euclid | 欧氏距离 | `sqrt(Σ(a-b)²)` | 距离（越小越好） | **相同** |
| Dot | 负内积 | `-Σ(a·b)` | `Σ(a·b)`（越大越好） | 本库 = `-qdrant` |
| Manhattan | L1 距离 | `Σabs(a-b)` | 距离（越小越好） | **相同** |

- **本库统一「越小越近」**（Q7 定稿）：Cosine / Dot 属「相似度型」度量，必须做一次单调变换（Cosine 取 `1 - cos`，Dot 取负）；Euclid / Manhattan 本身就是距离，直接使用。
- **零向量约定（Q6 定稿，M2）**：Cosine 度量下，只要**任一侧**（查询向量或已存点）模长为 0，`cos` 记作 `0`，本库 `score` 固定为 **1.0**。理由：① 不产生 `NaN`（否则排序与阈值比较全部失效）；② 不抛异常，与 Qdrant「不报错」的行为更接近；③ 语义可解释为「正交 / 无相似度」。
  - 该分支是**本地后端的确定性约定**，C15 的黄金数据**刻意排除零向量**。M3 必须用真实 Qdrant 复测零向量，若不一致则在本节与 README「已知差异」中显式声明。
- **对齐要求**：`score` 数值须与上表换算后的 Qdrant 值一致，允许浮点相对误差 `1e-6`。参考值来源见 10 节。

### 9.3 检索流程

`search` 的校验顺序**固定**（用哪种错误见 9.5）：

1. 集合不存在 → `NotFound`；
2. `limit < 1` → `InvalidArgument`；
3. `req.vector.length() != config.size` → `InvalidArgument`；
4. **先过滤再算距离**（filter 存在时）；filter 的路径形式非法 → `Unsupported`；
5. 对候选点算距离，按 `score` 升序排序；**分数相同时按 `PointId` 升序**（本地保证确定性；远端不承诺该次序，故一致性测试不得依赖它）；
6. 截断 `limit`；
7. 应用 `score_threshold`：**保留 `score <= threshold` 的点**（Q7 定稿）；
8. 按 `with_payload` / `with_vector` 填充字段。

字段填充规则（两个后端必须一致）：

- `with_payload = true` → `Some(payload)`；写入时没有 payload 的点返回 **`Some(空 Map)`**（与 Qdrant 的 `{}` 一致），不是 `None`。
- `with_payload = false` → `None`；`with_vector = true` → `Some(vector)`；`false` → `None`。

`scroll`：

- 校验顺序：集合不存在 → `NotFound`；`limit < 1` → `InvalidArgument`；`offset` 有值但**不在集合中** → `InvalidArgument`。
- **按插入序**（Q5 定稿：不承诺全局顺序，只承诺不重不漏）。`offset` 语义是「上一页返回的最后一个 `PointId`」；定位时**只在插入序里找该 ID 的位置**（即使它被 filter 排除也照此定位），再从它的下一个位置开始扫描，保证游标不漂移。
- `next_offset`：若其后仍存在**满足 filter 的点**，返回本页最后一个返回点的 ID；否则返回 `None`。
- 删除点会让其后所有点的下标前移，但**相对次序不变**，故「不重不漏」仍成立。

`retrieve`：按传入 `ids` 顺序返回**能取到**的点（不存在的 ID 静默跳过，与 Qdrant 一致）；集合不存在 → `NotFound`。

### 9.4 并发与线程安全

`MemoryStore` 内含可变状态。**Q10 已定稿（实测，见 13.3）：`@async.Mutex` 与 `@async.Semaphore` 均可用**（8 任务 × 50 次临界区累加为精确 400，无丢更新；Semaphore(2) 下并发峰值 ≤ 2）。M2 又补测了本后端真正依赖的两条语义（`src/local/lock_wbtest.mbt`，三目标通过）：

- **`defer` 在临界区 `raise` 展开时仍会释放锁** —— 这是「写路径统一写 `acquire` + `defer release`」敢于成立的前提。若该前提不成立，一次失败的写操作会永久占住锁，症状是后续操作挂死而非报错（见 13.5）。
- **并发累加无丢更新**：Mutex 在 native / js / wasm 上都真的互斥。

因此决定：

- **内部串行化**：`MemoryStore` 持有 `@async.Mutex`，**11 个方法全部**走 `acquire` + `defer release` 的统一形态（读路径也加锁，省掉「读是否会观察到半更新状态」的推理成本）。这样 `MemoryStore` 可直接用于 `@async.all(..., max_concurrent=n)` 的并发批量写，无需调用方额外处理。
- **临界区内不含 `suspend` 点**：临界区只做同步运算（过滤、距离、排序、map 操作），不调用任何 async 函数，因此在协作式调度下临界区是**原子的**；`acquire` 本身可能挂起，但那只发生在进临界区之前。这条是 review 时的硬要求。
- `VectorStore` 的所有方法本来就是 `async`，因此加锁不会污染同步 API。
- **批量并发上限**由 `@async.all(max_concurrent=n)` 控制，`Semaphore` 仅在需要跨多次调用维持长期配额时使用。
- **README 说明**：内部串行化意味着本地后端的操作是串行的、不提供锁外的并行度保证；这符合「本地后端用于测试与离线」的定位。
- `wasm-gc` 目标下无法验证并发行为（`async test` 不执行），故对 `wasm-gc` 只承诺「可编译」，不承诺并发正确性。

### 9.5 本地后端的错误语义（C14 的依据）

**契约：两个后端都必须能用同一套 `VectorStoreError` 表达失败**（8.4）。本地后端的具体映射：

| 触发条件 | 抛出的错误 | 涉及方法 |
| --- | --- | --- |
| 目标集合不存在 | `NotFound(resource="collection:<name>")` | `delete_collection` / `describe_collection` / `upsert` / `delete_points` / `delete_by_filter` / `retrieve` / `search` / `scroll` / `create_payload_index` |
| 同名集合已存在且配置不同 | `Conflict(message=..)` | `create_collection` |
| `config.size < 1` | `InvalidArgument(message=..)` | `create_collection` |
| 向量维度 ≠ `config.size` | `InvalidArgument(message=..)` | `upsert` / `search` |
| `limit < 1` | `InvalidArgument(message=..)` | `search` / `scroll` |
| `scroll` 的 `offset` 不在集合中 | `InvalidArgument(message=..)` | `scroll` |
| filter 路径形式不被支持 | `Unsupported(feature=..)` | `search` / `scroll` / `delete_by_filter` |
| 同名集合配置一致 | 成功（幂等，Q4 定稿） | `create_collection` |
| 集合不存在时的查询 | `false`，**不抛错** | `collection_exists` |

**明确不抛**的两类：

- 本地后端**永不**抛 `Http` / `Server` / `Decode` / `Auth` / `RateLimited` / `Timeout` / `Transport` —— 这些只在远端出现（8.3）。一致性测试的 C14 只断言双方「共有」的错误种类，不对本地后端的私有分支做断言。
- `upsert` 的 `wait` 参数在本地**被忽略**（无远端刷新语义），恒返回 `UpsertResult::All`；`create_payload_index` 在本地是 **no-op 成功**（暴力检索不需要索引，但集合不存在仍报 `NotFound`）。

### 9.6 过滤求值细则（本地）

`eval_filter(f, payload, point_id)` 的规则。**总原则：取值类条件在 key 缺失时一律不匹配**（7.4），唯一例外是 `is_null(value=true)`。

| 条件 | 本地求值规则 |
| --- | --- |
| `must` / `should` / `must_not` | `must` 全真；`should` 非空时**恒定**要求至少一个为真；`must_not` 全假 |
| `Clause::Cond` / `Clause::Group` | `Cond` 求值单条件；`Group` 递归求值嵌套 Filter（可无限层嵌套） |
| `Match::Value(j)` | 路径取值后：值本身或**数组的任一元素**与 `j` 相等（数字按数值比较，忽略 JSON 字面量写法差异） |
| `Match::Any(js)` / `Match::Except(js)` | 同上，任一元素落在集合内 / **没有任何**元素落在集合内 |
| `Match::Text(t)` | 值的字符串**包含** `t`（不区分大小写）。Qdrant 的 `text` 基于分词全文索引，这里是**近似实现**：一致性测试只使用「分词与子串结果一致」的样本，差异记入 README「已知差异」 |
| `Range` | 值或数组任一元素是数字且满足全部给定边界（`gt` / `gte` / `lt` / `lte`） |
| `GeoBoundingBox` | 值为 `{lat, lon}` 对象，且 `bottom_right.lat ≤ lat ≤ top_left.lat`、`top_left.lon ≤ lon ≤ bottom_right.lon`；数组任一元素满足即可 |
| `GeoRadius` | haversine 距离 ≤ `radius`（**radius 单位为米**，与 Qdrant 一致，见 README）；数组任一元素满足即可 |
| `ValuesCount` | 值必须是数组（取 `length`）或对象（取键数）；标量 → 不匹配；再按边界比较 |
| `IsEmpty(value=true)` | key **存在**且值为空数组或空对象 → 命中；**key 缺失 → 不命中**。`value=false` 时取相反的判定 |
| `IsNull(value=true)` | **key 缺失 或 值为 `null` → 命中**（这是「缺失 key 不匹配」的唯一例外，Qdrant 的 `is_null` 就用于匹配缺字段/空字段） |
| `HasId(ids)` | `point_id ∈ ids`（不看 payload，因此路径语义与它无关） |
| `Nested(key, filter)` | key 的值必须是数组，其**任一对象元素**满足内层 filter（内层 filter 以该元素为 payload 求值） |

路径语义（7.4 已划线，这里是实现口径）：

- 解析支持 `a.b.c` 与 `a.b[].c`；`[]` 的语义是「取该段的值后**展开一层数组**」，供后续段继续下钻。末段的 `[]` 与条件自带的「数组任一元素」语义等价，不冲突。
- 数组展开只展开**一层**；`a[][]` 这类相邻双展开不支持 → `Unsupported`。
- 空段（`a..b`、`.a`、`a.`）、显式下标（`a[0]`）、通配符（`a[*]`）→ `Unsupported(feature=<原始路径>)`。**绝不允许静默返回「不匹配」**。
- 类型不符（如路径中间遇到数字）**不是**错误，只是该分支无候选值 → 条件不成立。

---

## 10. 一致性测试（conformance suite）

这是保证 G7 的唯一手段，也是两个后端不漂移的机制。

```moonbit
// conformance/suite.mbt
pub async fn run_conformance(store : &VectorStore, name_prefix : String) -> Array[String] raise VectorStoreError
```

**v1.4 定稿：返回「失败消息列表」而不是 `Unit`**，理由有三：

1. `@test.fail` 的错误类型是抽象 `Error`，与 `raise VectorStoreError` 不兼容（在 `raise VectorStoreError` 的函数里调它编译不过，M0 已踩过同类坑），因此共享套件**不能依赖测试框架**；
2. 一次跑完所有场景，能一次性看到**全部**失败项，而不是被第一个失败打断；
3. `conformance` 保持为普通库包，remote 与 local 的测试文件都只写三行：跑套件 → 有失败就 `fail` → 断言失败数为 0。

**调用契约**：`name_prefix` 用于隔离集合名（**不同调用必须传不同前缀**，因为 `async test` 并行执行、测试之间不得共享状态，见 12.1 纪律 1）；套件在开始与结束时自行清理自己创建的集合，不依赖外部。

覆盖场景（每个后端都必须跑）：

| # | 场景 | 断言（本地/远端都必须成立） |
| --- | --- | --- |
| C1 | 建集合 → 存在性 → 描述 | `exists == true`；描述的 `size` / `distance` 与创建时一致 |
| C2 | 重复建同名集合（配置一致 / 不一致） | 一致 → 成功（Q4 幂等）；不一致 → `Conflict` |
| C3 | upsert 覆盖同 ID | 只保留最新值；`retrieve` 得到的 payload / vector 是新值；条数不增 |
| C4 | 批量 upsert | 返回 `All`；最终条数 = 写入的去重后条数 |
| C5 | 检索 top-k | 只比较 **score 单调不减** + 命中集合（**不断言并列次序**，见 9.3）；`limit` 精确生效（条数 = min(limit, 命中数)） |
| C6 | `score_threshold` | 结果中每个点都满足 `score <= threshold`；且与不加阈值时的前段一致 |
| C7 | filter：`must` / `should` / `must_not` | 命中 ID 集合与预期完全相等（三种子句各一组用例；`should` 采用 9.6 的「非空即恒定要求 ≥1」语义） |
| C8 | filter：嵌套 Filter（`Clause::Group`） | 同上；另含一层 `must` 内嵌 `must_not` 的组合 |
| C9 | filter：`match` 的 `value` / `any` / `except` / `text` | 同上；样本只用「分词与子串结果一致」的文本，避开 9.6 的近似差异 |
| C10 | filter：`range` 的 `gt` / `gte` / `lt` / `lte` 及组合 | 同上；边界值恰好等于阈值时按 `>=` / `>` 区分 |
| C11 | filter：缺失 key | 取值类条件判「不匹配」；**`is_null(value=true)` 反向命中**（9.6 的唯一例外） |
| C12 | `scroll` 分页游标 | 用小 `limit` 反复翻页直到 `next_offset == None`；合并结果与原集合**相等且无重复**（Q5：不承诺顺序） |
| C13 | `delete_points` / `delete_by_filter` | 删除后 `retrieve` 为空 / 命中的点消失，未命中的点仍在 |
| C14 | 错误种类 | 维度不符 → `InvalidArgument`；集合不存在 → `NotFound`；重复建且配置冲突 → `Conflict`；不支持路径 → `Unsupported`（**仅断言语义级错误种类**，不断言本地私有的 `Http` 等分支） |
| C15 | 距离数值 | 与黄金值在容差内一致（见下） |

**C15 的黄金值来源（v1.4 修正）**：M2 阶段**没有 Docker**（13.2），无法用真实 Qdrant 生成 fixture，因此 M2 使用**解析式手算黄金值**（例如 `a=[1,0]`、`b=[0,1]` 在四种度量下的 score 分别为 `1.0` / `√2` / `0.0` / `2.0`），并**显式声明这不是端到端比对**。M3 必须用真实 Qdrant 对同一批数据重新固化 golden fixture（`tests/integration/` 的 JSON 文件）并替换/补充这组手算值；届时若发现 9.2 的换算表与 Qdrant 实际不符，需回改 9.2 与 README。

---

## 11. 构建、工具链与配置

### 11.1 模块配置

**使用新格式 `moon.mod`**（Q11 已定稿：M1 执行 `moon fmt` 时**已自动完成迁移**，`moon.mod.json` 被删除，见 13.4）。实际生成的内容如下：

```moon
name = "lexchb/moon_vector"

version = "0.1.0"

readme = "README.md"

license = "Apache-2.0"

keywords = [ "vector", "embedding", "qdrant", "rag", "semantic-search" ]

description = "Type-safe vector search client (Qdrant REST) and in-memory backend for MoonBit"

import {
  "moonbitlang/async@0.22.1",
}

options(
  preferred_target: "native",
)
```

> 注意迁移后的格式：依赖写成 `import { "moonbitlang/async@0.22.1" }`，`preferred_target` 被包在 `options(...)` 里（不是顶层赋值）。这些都是 `moon fmt` 自动生成的，不要手改格式。

> **版本必须写死（重要，实测教训）**：`moon add moonbitlang/async` 会解析到**最新版**，而最新版可能晚于本机工具链以致无法构建。因此 `import` 处必须显式写 `@0.22.1`，并且**每次升级都要跑全量测试**。

说明：

- **模块名首段必须是发布者自己的 mooncakes 账号名**（官方文档明确要求 `<你的账号>/<模块名>`）。本机已登录账号为 **`lexchb`**（名下已有 `memcached`、`moonbit-texteditor`），故定为 `lexchb/moon_vector`。Q2 详见 15 节。
- 申报书中的 `moonbit-community/moon_vector` **不可直接发布**：`moonbit-community` 是官方社区组织命名空间（索引中有 106 个包，含 `rabbita`、`elasticsearch` 等），但官方文档未提供自助加入或向他人命名空间发布的方式。**需回写申报书该行**。
- 若将来通过社区流程加入该组织，模块名可迁移为 `moonbit-community/moon_vector`；由于 `moon add` 按模块名寻址，迁移只需同步 README 与本文档，不影响已发布版本。

### 11.2 包配置

**使用新格式 `moon.pkg`**（同样由 `moon fmt` 迁移生成）。`src/core/moon.pkg` 实际内容：

```moon
import {
  "moonbitlang/core/json",
}

import {
  "moonbitlang/async",
} for "test"
```

- `core` 的**生产 API 不依赖 async 运行时**（M1 实测：trait 里声明 `async fn` 并不需要 import async；原 `import` 里的 async 被判为 `unused_package`）。运行时只在测试期需要，故用 `for "test"` 声明 —— 这样 `core` 可以保持零运行时依赖，跨目标更干净。
- `src/local/moon.pkg` 实际内容（M2）：**`async` 是正式依赖**（`MemoryStore` 持有 `@async.Mutex`），`core` 也是正式依赖；`conformance` 只在测试期用得上，故 `for "test"`：

```moon
import {
  "lexchb/moon_vector/src/core",
  "moonbitlang/async",
}

import {
  "lexchb/moon_vector/conformance",
} for "test"
```

- `conformance/moon.pkg` 实际内容（M2）：只依赖 core（**不依赖测试框架**，见 10 节）：

```moon
import {
  "lexchb/moon_vector/src/core",
}
```

- `src/remote/moon.pkg` 将来需要（**注意包名要带 `src/` 前缀**，见元信息勘误）：

```moon
import {
  "lexchb/moon_vector/src/core",
  "moonbitlang/async",
  "moonbitlang/async/http",
  "moonbitlang/core/json",
}

options(
  supported_targets: "native",
)
```

`src/core/` 与 `src/local/` **不设** `supported_targets`（默认全目标）。**M0 实测确认**：`supported_targets = "native"` 会让该包在 `moon check --target js` / `moon test --target js` 中被正确排除，不会因引用 `@http` 而报错。

### 11.3 常用命令（M0 / M1 已逐条实测）

| 命令 | 用途 | 实测状态 |
| --- | --- | --- |
| `moon check` | 类型检查（提交前必跑） | 通过（0 warning） |
| `moon test --target native` | 主测试目标 | 通过（core 24/24） |
| `moon test --target js` | 跨目标验证（core / local） | 通过（core 24/24） |
| `moon test --target wasm` | 跨目标验证（core / local，**async 测试可执行**） | 通过（core 24/24） |
| `moon test --target wasm-gc` | 仅编译校验；**async 测试不执行** | 编译通过，异步测试静默不跑（见 13.3） |
| `moon build --target native` | native 构建（remote） | 未单独验证，随 test 隐式覆盖 |
| `moon fmt` | 格式化（提交前必跑） | **通过，且会自动迁移 mod/pkg 到新格式**（M1） |
| `moon info` | 生成 `pkg.generated.mbti`，用于接口冻结与 diff 评审 | 通过，已生成 `.mbti` |
| `moon coverage analyze` | 覆盖率报告 | 未验证 |

### 11.4 禁止事项

- 禁止在 `core` / `local` 中引用 `@http`。
- 禁止提交未格式化的代码（CI 会跑 `moon fmt --check`）。
- 禁止提交 `.mbti` 变更却不同步本文档。
- **禁止使用 `moon add` 的默认最新版依赖**（见 3 版本约定）。
- **注意 `unused_mut` 在本工具链是 error 而非 warning**（实测：给不必要 `mut` 的数组绑定加 `mut` 会导致 `moon check` 失败）。提交前务必跑 `moon check`。
- 禁止在同时导入 `core/json` 的包中用裸 `inspect` 做 JSON 断言（别名歧义），统一用 `@json.to_json(x).stringify()` 比较字符串。
- **禁止把 `_build/` / `.mooncakes/` 提交入库**（已在 `.gitignore` 中忽略）。
- **新增公共类型或公共 API 时，必须在黑盒测试里至少构造一次**（见 12.1 纪律 4），以保证对外可见性没有被 readonly 默认值挡住。

---

## 12. 测试与 CI 策略

### 12.1 测试分层

| 层 | 位置 | 是否依赖外部服务 | 目标 |
| --- | --- | --- | --- |
| 单元测试（白盒） | `src/*/*_wbtest.mbt`（如 `core/codec_wbtest.mbt`） | 否 | 编解码往返、距离实现、路径解析、排序细节；可访问私有成员，可自带私有断言 helper |
| 单元测试（黑盒） | `src/*/*_test.mbt`（如 `core/store_test.mbt`） | 否 | **公共 API 对外可用性的守门测试**：用 `@core.X` 构造/实现/匹配一遍（见纪律 4） |
| 一致性测试 | `conformance/` + 各后端调用 | local 否 / remote 是 | 两后端行为一致 |
| 集成测试 | `tests/integration/` | 是（Qdrant 或本地桩） | 真实端点、错误映射、重试、超时 |

**M0 / M1 实测的四条测试纪律（务必遵守）**：

1. **`async test` 默认并行执行**。因此每个测试必须**自包含、可重复、无共享可变状态**。M0 中就踩到了这个坑：桩服务用全局计数器模拟「前两次 503」，导致测试第二次运行失败。正确做法是让被测目标自带隔离（如按路径独立计数、或每次请求显式声明重置）。
2. **断言优先比较线上 JSON 字符串**，而非结构体；不要在导入 `core/json` 的包里用裸 `inspect`。白盒测试可自带一个私有 `check(actual, expected)` helper 统一承担这件事。
3. **必须核对 `Total tests` 计数**。`moon test` 在 `wasm-gc` 目标下会**静默跳过 `async test`**（见 13.3），若只看「退出码 0」会得到假绿。CI 中应对预期的测试数做断言（如最低测试数门限），或至少在改动测试后人工核对计数。
4. **每个公共类型都要在黑盒测试里被构造一次（M1 新增，最重要的纪律）**。MoonBit 的默认可见性是 readonly：`pub enum` 的构造器、`pub trait` 的实现、`pub suberror` 的模式匹配，**在同包内（含白盒测试）都正常，只有跨包使用才会暴露问题**。因此必须有 `src/*/*_test.mbt` 黑盒测试刻意用 `@core.X` 限定名去构造/实现/匹配一遍，把它当作「公共 API 是否真的对外可用」的守门测试。M1 就是靠这条才发现 `pub trait`→`pub(open) trait`、`pub enum`→`pub(all) enum` 这两个致命问题（见 13.4）。

### 12.2 CI 作业

```yaml
# .github/workflows/ci.yml（要点摘录）
jobs:
  check:
    steps: [install moon@0.1.20260920, moon fmt --check, moon check, moon info]
  unit:
    steps: [moon test --target native, moon test --target js, moon test --target wasm]
  integration:
    services:
      qdrant: { image: qdrant/qdrant:v1.14.0, ports: ['6333:6333'] }
    steps: [moon test tests/integration --target native]
```

- **集成测试必须能在没有 Docker 的开发机上跳过**：以 `QDRANT_URL` 环境变量是否存在决定是否执行，保证本地开发不被阻塞（本机即无 Docker，见 13.2）。
- **无 Docker 时的替代验证路径**：仓库内提供 `tests/stub/qdrant_stub.py`（本地 HTTP 桩，复刻 Qdrant 的响应形状，含三种 `result` 包裹形状、404 错误体、503 重试、慢响应超时）。M0 已用这一方式完成端到端验证。
- CI 中同时固定 MoonBit 工具链版本 **与** `async` 版本（两者必须成对）。

### 12.3 提交门禁（本地）

提交前必须：`moon fmt` → `moon check` → `moon test` → （涉及 API）`moon info` 检查 diff。

---

## 13. 里程碑与验收（DoD）

| 里程碑 | 范围 | 完成定义（DoD） |
| --- | --- | --- |
| **M0 技术验证** | 工具链能力探明 | ✅ **已完成**（见 13.2）：① trait 中 `async fn` 可行性 → 支持；② `PointId` / `MatchValue` 手写编解码 → 可行；③ native 下 `@http` 端到端 → 可行（用本地桩替代真实 Qdrant）；④ 本文档第 2.3 / 6 / 7 / 8 / 11 / 12 节已按实测回填 |
| **M1 core 抽象层** | 类型、Filter DSL、错误、trait | ✅ **已完成**（见 13.4）：类型全部就位；Filter 编解码往返测试通过；`moon test` 在 native/js/wasm 均 24/24；`.mbti` 已生成；`extend` 声明齐备（0 warning） |
| **M2 local 后端** | 暴力 kNN + 过滤求值 + 分页 + `@async.Mutex` 串行化 | ✅ **已完成**（见 13.5）：C1–C15 全绿（套件对 local 跑通）；距离数值与手算黄金值在容差内一致；native/js/wasm 各 **43/43**；0 warning |
| **M3 remote 后端** | 端点映射、传输层、错误映射 | 对真实 Qdrant 跑通 G2 全流程（无 Docker 环境先用本地桩 + golden fixture 过渡）；重试/超时/状态码映射有针对性测试；一致性测试全绿 |
| **M4 批量与并发** | `@async.all` 有界并发批量写入/检索 | 并发度可配；失败传播/取消行为有测试；`MemoryStore` 的 `@async.Mutex` 串行化有并发正确性测试 |
| **M5 发布** | README、示例、CI、mooncakes | 示例可一键跑通（local 示例不依赖 Docker）；CI 三个作业全绿；发布 v0.1.0；仓库 ≥10 个有效 commit |

### 13.1 最终验收清单（对应申报书「预期验收产物」）

- [ ] `lexchb/moon_vector` 可通过 `moon add` 引入
- [ ] 发布到 mooncakes.io 且版本号为 SemVer
- [ ] README 含：快速开始、API 概览、已知差异、并发说明、最低 Qdrant 版本、API 规范来源声明
- [ ] 至少一个可运行示例（local 后端，无需 Docker）
- [ ] 单元测试 + 一致性测试 + 集成测试（Docker 优先，本地桩兜底）
- [ ] GitHub Actions 覆盖 `moon check` / `moon test` / 集成测试，且工具链与 `async` 版本成对锁定
- [ ] Apache-2.0 `LICENSE` 存在
- [ ] 仓库 ≥10 个有效 commit

### 13.2 M0 验证记录（2026-10-14，已完成）

**环境**：`moon 0.1.20260920 (914d7da)` / `moonc v0.10.14+7d59c7ec9` / `moonbitlang/async 0.22.1` / Python 3.12.6。**本机无 Docker**，故真实 Qdrant 容器验证推迟到 CI（M3）。

**沙盒位置**：`%TEMP%\moonvec-m0`（临时目录，含 `moon.mod.json`、三个探针包 `src/probe_async` / `src/probe_json` / `src/probe_http`、以及 `stub_server.py`）。按仓库约定，探针属于中间产物，不入库；**该沙盒已被清理**，其结论已全部固化到本文档，另见 13.3（Q10 探针 `%TEMP%\moonvec-q10`）。

| 探针 | 验证内容 | 结果 |
| --- | --- | --- |
| ① `probe_async` | trait 中声明并实现 `async fn`；泛型上界 `fn[T : ProbeStore]`；动态派发 `&ProbeStore`；`extend` 使方法语法可用；`@async.all` 有界并发 | **4/4 通过**（native 与 js） |
| ② `probe_json` | `PointId` 裸数字/裸字符串；`MatchValue` 四种内联形状；`Condition` 展平；struct `Option` 字段的 derive 行为 | **11/11 通过**（native / js / wasm-gc） |
| ③ `probe_http` | `@http.Client` 复用、自定义头透传、GET/POST/PUT/DELETE、嵌套 `config` 解析、三种 `result` 包裹形状、404→`status.error`、`with_timeout` 超时、显式循环重试（503 两次后成功） | **9/9 通过**（native） |

**全量回归**：`moon test --target native` = **24/24**（4 + 11 + 9），连续执行两次结果一致；`moon test --target js` = **15/15**（4 + 11，native-only 的 `probe_http` 被正确排除）；`moon check --target js` = 0 error。

**验证过程中发现、并已写入本文档的行为**（按重要性排序）：

| # | 发现 | 落到哪一节 |
| --- | --- | --- |
| 1 | `@async.retry` 会把错误类型擦除为抽象 `Error`，且 `fatal_error` 无法做 suberror 模式匹配 → 重试必须手写循环 | 8.2 |
| 2 | `async` 最新版（0.22.5）晚于本机工具链，`moon.pkg` 含未知键，**无法构建**；必须锁版本 | 2.3 / 3 / 11.1 |
| 3 | struct 的 `T?` 字段由 `derive` **自动省略 None 值**，与 Qdrant 期望一致；仅联合类型需手写 | 2.3 / 7.3 |
| 4 | `Json` 的变体构造器是只读的，必须用 `Json::number/string/object/array` 智能构造器 | 7.3 |
| 5 | `Int64` 默认序列化为**字符串**；整数 ID 需 `Json::number(d, repr=...)` 才能保持数字形状与精度 | 7.3 |
| 6 | 无字段默认值、无部分记录；可选字段类型必须配可选参数构造器 | 2.3 / 6.1 / 7.2 |
| 7 | 枚举/suberror 具名字段必须写 `field~ : T`，构造必须带标签 | 6.1 / 7.2 / 8.4 |
| 8 | 泛型参数写在 `fn` 之后（`fn[T] name`） | 6.4 |
| 9 | trait 方法隐式提升已废弃，需 `extend` 声明（否则用户写不出 `store.search(...)`） | 6.4 |
| 10 | `supported_targets = "native"` 能正确把包排除出 js/wasm 构建 | 11.2 |
| 11 | `async test` 默认并行 → 测试必须自包含；共享状态会导致第二次运行失败 | 12.1 |
| 12 | 同时导入 `core/json` 时裸 `inspect` 有重载歧义，改用字符串比较 | 7.3 / 12.1 |
| 13 | `unused_mut` 在本工具链是 **error** | 11.4 |
| 14 | `moon.mod.json` 已废弃告警，改用 `moon.mod` | 11.1 |

### 13.3 Q2 / Q10 定稿验证（2026-10-14，已完成）

**Q2 —— 模块命名空间（结论：改用 `lexchb/moon_vector`）**

取证方式与结果：

- 本地 registry 索引中 `moonbit-community` **存在且活跃**：其下有 **106 个包**（如 `rabbita`、`elasticsearch`、`graphviz`、`fflate`…），属于官方社区组织命名空间。
- 本机 `~/.moon/credentials.json` 的登录账号为 **`lexchb`**，该账号名下已有 2 个已发布模块（`memcached`、`moonbit-texteditor`）。
- 官方文档对发布路径的表述是：**把模块名改成 `<你的 GitHub 账户名>/<项目名>`，然后 `moon publish`**；模块路径示例也是 `username/myapp`。文档中**没有**向他人/组织命名空间发布或自助加入组织的入口。

结论：`moonbit-community/moon_vector` 不能自助发布 → 主线模块名定为 **`lexchb/moon_vector`**。已同步更新本文档元信息、11.1、11.2、13.1 与包路径注释。

> **需回写申报书**：[PROPOSAL.md](file:///d:/Moonbit/moonbit-Qdrant/PROPOSAL.md) 第 8 行的 GitHub 仓库链接说明与「预期验收产物」中的 `moonbit-community/moon_vector` 应与本文档保持一致。因该文件是提交材料，我未擅自改动，请刘总确认后我来同步。
>
> 后续若通过社区流程加入 `moonbit-community`，模块名再迁移即可（`moon add` 按模块名寻址，迁移只影响 README 与本文档）。

**Q10 —— `@async.Mutex` / `Semaphore` 在非 native 目标下是否可用（结论：可用）**

探针：`%TEMP%\moonvec-q10`（单包，验收 3 项：临界区累加 8 任务 × 50 次 = 精确 400；`try_acquire` 非阻塞语义；`Semaphore(2)` 下并发峰值 ≤ 2），另加 1 个同步 + 1 个异步 sanity 测试用于目标判别。

| 目标 | 同步 test | `async test` | 结果 |
| --- | --- | --- | --- |
| `native` | 执行 | **执行** | **5/5 通过** |
| `js` | 执行 | **执行** | **5/5 通过** |
| `wasm`（Wasm1） | 执行 | **执行** | **5/5 通过** |
| `wasm-gc` | 执行 | **不执行**（静默跳过） | 仅 1/1（同步），异步测试未被运行 |

结论：

1. **`@async.Mutex` / `@async.Semaphore` 在 `native` / `js` / `wasm` 上功能完整**，互斥与并发上限都被实际验证，因此 9.4 的「`MemoryStore` 内部串行化」方案成立，无需降级。
2. **`wasm-gc` 下 `async test` 不会被运行器执行**（包能编译、同步测试能跑、异步测试既无输出也无报错）。这是一个**独立于 Mutex 的工具链/运行器限制**，因此把「可运行验证目标」从 `wasm-gc` 修正为 **`wasm`**（Wasm1）。

   > 待 M1 复核：该现象也可能是 `wasm-gc` 运行器尚未支持 async 事件循环，而非语言或 `async` 库的限制。M1 应在 CI 里对 `wasm-gc` 只做 `moon check`（编译面），把运行验证放在 native/js/wasm 三目标。

**一处方法论教训**：上述「3 个测试全部静默未执行」很容易被误读为「通过」。**`moon test` 的 `Total tests` 计数必须与预期测试数核对**，否则会得到假绿。已把这条写入 12.1。

### 13.4 M1 实测记录（2026-10-14，已完成）

**产出**（全部入库，`_build/` 与 `.mooncakes/` 已加入 `.gitignore`）：

```
moon.mod                       # 新格式（moon fmt 自动迁移，Q11 定稿）
src/core/moon.pkg              # 新格式；json 为正式依赖，async 仅 for "test"
src/core/error.mbt             # VectorStoreError（11 个分支）+ Show 实现
src/core/distance.mbt           # Distance（pub(all)）+ is_similarity
src/core/types.mbt              # Vector/ Payload/ PointId/ VectorConfig/ ScoredPoint/
                                #   StoredPoint/ Point/ UpsertResult/ PayloadSchema/
                                #   SearchRequest/ ScrollRequest/ ScrollPage + 构造器
src/core/filter.mbt             # Filter/ Clause/ Condition/ MatchValue/ RangeSpec/
                                #   GeoPoint/ GeoBox/ GeoRadiusSpec/ ValuesCountSpec
                                #   + 常用条件便捷构造器
src/core/json_codec.mbt         # 6 个手写编解码 + parse_decimal_uint64
src/core/extends.mbt            # 50 条 extend 声明（消除全部 0079 告警）
src/core/store.mbt              # pub(open) trait VectorStore（11 个 async 方法）
src/core/codec_wbtest.mbt       # 21 个编解码/往返测试（白盒）
src/core/store_test.mbt         # 3 个公共 API 守门测试（黑盒，@core. 限定名）
src/core/pkg.generated.mbti     # 接口冻结产物（moon info）
```

**验收结果**：

| 项 | 结果 |
| --- | --- |
| `moon check` | 0 error，**0 warning**（初版 47 个 `implicit_impl_as_method` 告警已由 `extends.mbt` 全部消除） |
| `moon test --target native` | **24/24** |
| `moon test --target js` | **24/24** |
| `moon test --target wasm` | **24/24** |
| `moon fmt` | 通过；**自动迁移** `moon.mod.json` → `moon.mod`、`moon.pkg.json` → `moon.pkg` |
| `moon info` | 通过，生成 `src/core/pkg.generated.mbti` |
| `git status` | 仅 `moon.mod` / `src/` / `DEVELOPMENT.md` / `.gitignore` 待提交（构建产物已忽略） |

**M1 期间发现并已写入本文档的问题（按严重程度）**：

| # | 问题 | 影响 | 落在哪一节 |
| --- | --- | --- | --- |
| 1 | **`pub trait` 是 readonly，外部包无法实现** | 若照初版文档写，local / remote 乃至用户自定义后端全部无法实现 `VectorStore`，抽象层直接失效 | 2.3 约束 5 / 6.4 |
| 2 | **`pub enum` 是 readonly，外部包无法构造变体** | 所有面向用户构造的枚举（`PointId` / `Distance` / `MatchValue` / `Condition` / `Clause` / `PayloadSchema` / `UpsertResult`）对外不可用 | 2.3 约束 5 / 6.1 / 7.2 |
| 3 | **`Clause` 判别逻辑把 `{"has_id":[..]}` 误判为嵌套 Filter** | 含 `has_id` 的过滤条件会有静默语义错误（被解成空 Filter = 匹配全部） | 7.3（由往返测试抓到） |
| 4 | `PointId` 用 `Int64` 无法表达 Qdrant 的 u64 ID | Qdrant 随机 ID 约半数超出 2^63-1，`retrieve`/`search` 会读不回这些点 | 6.1（改为 `UInt64`） |
| 5 | 大整数 JSON 编解码必须走 `repr` + 精确十进制解析 | 否则 > 2^53 的 ID 静默丢精度 | 7.3 |
| 6 | `derive` 会把 `Bool(x)` 解析成本枚举变体（名字遮蔽） | `PayloadSchema::Bool` 会遮蔽内建 `Bool` 的构造器解析，导致 Json 模式匹配静默走错分支 | 6.1（改名 `Boolean`）；Json 布尔必须用 `True` / `False` 模式 |
| 7 | `pub typealias` 语法不存在，应为 `pub type X = Y` | 编译期直接报错 | 16.1 |
| 8 | `@json.JsonPath` 是包私有类型，**外部包无法写出该类型名** | 任何接受/转发 `JsonPath` 的 helper 函数都无法定义（M1 的 `decode_point_ids` 因此内联） | 16.1 |
| 9 | `moon.pkg.json` 的 `test-import` 等价写法是 `import { .. } for "test"` | 迁移后用于把 async 限制在测试期，使 core 生产 API 零运行时依赖 | 11.2 |
| 10 | `extend` 声明确实能消除 0079 告警，且**对内置 trait 与自定义 trait 同样适用** | 47 → 0 告警；否则调用方只能写 `Trait::method(x, ..)` | 6.4 / ADR-10 |
| 11 | `moon fmt` 会**自动迁移** mod/pkg 到新格式 | 手写的 `moon.mod.json` 格式细节不重要，交给 `moon fmt` | 11.1 / 11.2 |

**未在 M1 覆盖、留给后续的风险**：

- `VectorStore` 的 11 个方法中，M1 只验证了**可实现性/可调用性**（测试替身），业务语义要到 M2/M3 才验证。
- `PointId` 的精确解析依赖 `@json.parse` 是否填充 `Number` 的 `repr`。M1 的测试（满量程 u64 往返）**已通过**，说明本工具链确实填充 `repr`；但这是实现细节，M3 对真实 Qdrant 时应再确认一次。
- `UpsertResult::Partial` 目前无实际数据来源（Qdrant 的 upsert 是整批返回），属预留扩展点，README 需说明。

---

### 13.5 M2 实测记录（2026-10-15，已完成）

**产出**（全部入库）：

```
src/local/moon.pkg                # core + async + @math；conformance 仅 for "test"
src/local/path.mbt                # 路径解析与取值（点号 + `[]` 一层展开，其余 Unsupported）
src/local/distance.mbt            # 四度量 + Q6 零向量约定
src/local/filter_eval.mbt         # 逐条件求值（含 haversine 与「缺 key / 空值」分界）
src/local/memory.mbt              # MemoryStore + MemCollection + 11 个方法 + pub extend
src/local/lock_wbtest.mbt         # Mutex：defer-on-raise + 并发累加（2 个测试）
src/local/distance_wbtest.mbt     # 四度量数值（4 个测试）
src/local/filter_eval_wbtest.mbt  # 路径与求值语义（10 个测试）
src/local/memory_test.mbt         # 黑盒守门 + 一致性套件入口（3 个测试）
src/local/pkg.generated.mbti      # 接口冻结：只有 MemoryStore::new + 11 个方法 + impl 声明
conformance/moon.pkg
conformance/suite.mbt             # C1–C15（返回失败列表，不依赖测试框架）
conformance/pkg.generated.mbti    # 只暴露 run_conformance
```

**验收结果**：

| 项 | 结果 |
| --- | --- |
| `moon check` | 0 error，**0 warning** |
| `moon test --target native` | **43/43** |
| `moon test --target js` | **43/43** |
| `moon test --target wasm` | **43/43** |
| 一致性套件 | C1–C15 全绿（对 local 后端跑通；套件把失败收集成列表，一次看全） |
| `moon fmt` | 通过（仅补齐 `moon.mod` / `src/core/moon.pkg` 的文件尾换行） |
| `moon info` | 通过，新增 `src/local` 与 `conformance` 的 `.mbti` |

**测试计数（12.1 纪律 3）**：43 = core 24 + local 19（lock 2 + distance 4 + 路径/求值 10 + 守门 3）。三个目标的计数**完全一致**，说明没有出现「静默跳过」的假绿。

**M2 期间发现并已修正的问题（按严重程度）**：

| # | 问题 | 影响 | 落在哪一节 |
| --- | --- | --- | --- |
| 1 | **跨包使用的 trait impl 必须写 `pub impl`** | 裸 `impl` 只在**声明它的包内**可见：`local` 对 `VectorStore` 的实现对别的包「不存在」，黑盒测试直接报 `does not implement trait ...: no impl is defined`。M1 的测试替身恰好与被测 trait 同包，所以这个坑到 M2 才暴露 | 16.1 |
| 2 | **`impl ... with` 内不能给方法写 `async`** | `impl T for X with async fn m(..)` 直接**解析失败**；异步性完全由 trait 声明决定，实现处写 `fn m(..)` 即可 | 16.1 |
| 3 | **泛型参数必须写在函数名之前** | `fn[X : Eq + Show] T::m(..)` 合法；`fn T::m[X : Eq + Show](..)` 解析失败 | 16.1 |
| 4 | **`Map` 的大括号字面量在实参位置有语法歧义** | `payload={ "k": v }` 里的 `{` 被当作块，报错位置指向后面无关的 `)`，极难定位；统一改用 `Map([...])` | 16.1 |
| 5 | **解析错误会级联出一大批误导性类型错误** | 一个 `async fn` 解析失败，连带报出 `There is no record definition with the fields: points, next_offset`——而那个字面量本身完全正确。教训：**先修解析错误，再看剩余报错** | 16.1 |
| 6 | 测试 helper 里调用 `fail` 需声明错误类型 | 否则报 `Function with error can only be used inside a function with error types in its signature`；helper 写成 `-> Unit raise` 即可 | 16.1 |
| 7 | `@math.pi` / `Map::new()` 已弃用 | `moon check` 会报 deprecated 告警；改用 `@math.PI` 与 `Map([], capacity=..)`（本地用 `Map([])`） | 16.1 |
| 8 | core 的公共类型没有 `Show` | 一致性套件无法直接 `inspect` / 插值结构体（`\{x}` 编译不过），故套件改为**比较渲染后的字符串或布尔表达式**。这是 M1「枚举只 derive `Eq`」带来的实际成本；若后续要提升可读性，可考虑给 `PointId` / `Distance` 等补 `Show`（**当前不做**，避免 M2 越界） | 10 节 / 16.1 |

**M2 新增的、M3 必须复核的三件事**（都写在对应小节，不要漏）：

1. 9.2 的「本库 `score` ↔ Qdrant `score`」换算表（Cosine / Dot 反号）**未经真实 Qdrant 验证**；
2. `should` 的语义（非空即恒定要求 ≥1），C7 已把它钉住，M3 若实测与 Qdrant 不符需回改 9.6 与 C7 期望；
3. `text` 匹配在本地是子串近似（Qdrant 是分词全文）；C9 只用了两者结论一致的样本，README 需声明差异。

---

## 14. 关键设计决策记录（ADR）

| # | 决策 | 理由 | 代价 |
| --- | --- | --- | --- |
| ADR-1 | 走 REST，不做 gRPC / FFI | MoonBit 无 HTTP/2 传输；FFI 引入 C 依赖，破坏跨目标 | 无 gRPC 的性能与流式能力 |
| ADR-2 | core 与 remote 分离双类型体系 | 防止 Qdrant 字段名泄漏进公共 API | 多一层 convert 代码 |
| ADR-3 | 结构体 `derive`，**仅联合类型**手写编解码 | 实测：`derive` 只能生成外部标签（`{"Cond":{...}}`），而 Qdrant 的 `PointId` / `match` 是 untagged；反过来结构体的 `T?` 字段 derive 会正确省略 `None` | 手写代码集中在 `filter_json.mbt` 一处，需往返测试保障 |
| ADR-4 | 只实现 `points/query`，不实现已弃用的 `points/search` | 减少维护面，query 覆盖 search 全部能力 | 与老版本 Qdrant（<1.10）不兼容，需在 README 声明最低版本 |
| ADR-5 | 传输层做薄，不暴露 `@http` 类型 | `@async` 仍 experimental，需隔离第三方 API 漂移 | 灵活性受限 |
| ADR-6 | 本地后端限定过滤路径语义（点号 + `[]`） | 完整复刻 Qdrant 路径语义成本过高且易错 | 有已知差异，需公开声明 |
| ADR-7 | 远端 native-only，**core/local 可跨 native/js/wasm** | 实测只有 IO 类 API 为 native-only；`async` 的非 IO 部分（task group / sleep / all / Mutex / Semaphore）在 js 与 wasm 上可运行 | `wasm-gc` 下异步测试不执行，故该目标只做编译校验（13.3） |
| ADR-8 | **重试手写显式循环，不用 `@async.retry`** | 实测 `retry` 把错误类型擦除为抽象 `Error`，且 `fatal_error` 无法匹配 suberror → 无法实现「4xx 不重试」 | 多约 20 行循环代码，换来精确的错误语义与重试策略 |
| ADR-9 | 工具链与 `async` **成对锁死版本** | 实测最新 `async`（晚于工具链 20 余天）无法构建 | 升级需要成对进行并跑全量测试 |
| ADR-10 | 每个实现包显式写 `extend Type with VectorStore::{..}` | 实测 trait 方法隐式提升已废弃，不写 `extend` 则用户只能用 `VectorStore::search(store, ..)` 形式 | 每个实现都要维护一行方法清单 |
| ADR-11 | `MemoryStore` 内部用 `@async.Mutex` 串行化 | Q10 实测 Mutex 的互斥语义在 native/js/wasm 上均验证通过；`VectorStore` 方法本就是 async，加锁无 API 代价 | 本地后端写操作串行，不提供额外并行度 |
| ADR-12 | 集成测试以本地 HTTP 桩兜底 | 本机无 Docker，无法用真实 Qdrant 起步；桩可精确复刻响应形状 | 桩与真实 Qdrant 可能有细节差异，CI 仍需跑真实容器 |
| ADR-13 | 模块名用 `lexchb/moon_vector`，不用 `moonbit-community/*` | Q2 取证：官方发布路径只支持 `<自己的账号>/<模块名>`，无自助加入组织入口 | 与申报书原文不一致，需回写申报书；将来能否迁入组织不确定 |
| ADR-14 | **`PointId::Num(UInt64)` 而非 `Int64`** | Qdrant 的 ID 是 u64，自动生成的随机 ID 约半数超出 2^63-1；用 Int64 会导致这些已存在的点读不回来（M1 实测修正，见 13.4） | 与本文档 v1.2 不一致；`UInt64` 字面量要写 `UL`，且需自行实现精确十进制解析 |
| ADR-15 | **Cosine 零向量 → `score` 固定 1.0**（`cos` 记 0） | Q6 定稿。`NaN` 会让排序与 `score_threshold` 比较全部失效；抛错又与 Qdrant 行为不符。记 0 的语义可解释为「正交」 | 与 Qdrant 的零向量行为未经实测比对（无 Docker），M3 必须复核；C15 黄金值排除零向量 |
| ADR-16 | **跨包 `import` 用完整包名（含 `src/`）**，如 `lexchb/moon_vector/src/core` | 包名 = 模块名 + 目录路径（由 `pkg.generated.mbti` 第 2 行确证）。v1.3 文档写的 `lexchb/moon_vector/core` 是错的，照抄会让 `local` / `remote` 的 import 全部编译失败 | 文档内所有包路径注释都要跟着改（v1.4 已改） |
| ADR-17 | **conformance 套件不依赖测试框架，返回失败消息列表** | `@test.fail` 的错误类型是抽象 `Error`，与 `raise VectorStoreError` 不能共存；返回列表还能一次跑完全部场景、让 remote/local 的测试文件各自只写三行 | 调用方需要自己 `fail`；失败信息是字符串而非断言栈，定位精度略低 |
| ADR-18 | **`MemoryStore` 的 11 个方法全部加锁，且临界区内不含 `suspend` 点** | 统一形态省掉「读是否会看到半更新状态」的推理；`defer` 在 raise 展开时确实释放锁已由 `lock_wbtest.mbt` 实测（否则失败调用会永久占锁，症状是挂死） | 读操作也被串行化，本地后端并发度受限（符合「测试与离线」定位） |

---

## 15. 开放问题（逐里程碑定稿）

| # | 问题 | 影响 | 状态 | 决断期限 |
| --- | --- | --- | --- | --- |
| Q1 | trait 中是否支持 `async fn`？ | 决定 6.4 是 trait 还是结构化函数记录 | ✅ **已定稿：支持**（实测，6.4） | M0 |
| Q2 | `moonbit-community` 组织名是否可用？否则模块名如何定？ | 决定模块名与发布路径 | ✅ **已定稿：组织存在但不可自助发布 → 用 `lexchb/moon_vector`**（实测，13.3 / ADR-13） | 已定稿 |
| Q3 | Payload 用 `Map[String, Json]` 还是强类型泛型？ | 决定 6.1 / Filter 的易用性 | ✅ **已定稿：用 `Map[String, Json]`（`pub type Payload`）**；原本留给 M2 的强类型包装已在 M2 决议不做（见 Q8），故主线不再变更 | M1 |
| Q4 | 重复 `create_collection` 的语义 | 影响 C2 断言 | ✅ **已定稿：配置一致则幂等成功；配置不一致报 `Conflict`**（远端 Qdrant 在配置一致时返回 `result:false`，不一致返回 400 → 映射 Conflict） | M1 |
| Q5 | `scroll` 的排序依据 | 影响 C12 断言与本地后端实现 | ✅ **已定稿：不承诺全局顺序**——只承诺「分页遍历不重不漏」；本地按插入序实现，远端按 Qdrant 返回序。C12 断言只比对集合相等且无重复 | M1 |
| Q6 | Cosine 遇零向量的约定：报错还是返回固定分？ | 影响 C15 数值对齐 | ✅ **已定稿：任一侧模长为 0 时把 `cos` 记作 0，本库 `score` 固定 1.0**（既不抛错也不产生 `NaN`，见 9.2 / ADR-15）。C15 黄金值排除零向量，M3 用真实 Qdrant 复核 | M2 |
| Q7 | `score_threshold` 的比较方向 | 影响 C6 断言 | ✅ **已定稿（本库内部约定）：统一「越小越近」，保留 `score <= threshold` 的点**。⚠ 注意 Qdrant 的阈值方向随度量类型而变，M3 必须用真实 Qdrant 校准并在 README 声明 | M1 |
| Q8 | 是否提供强类型 payload 映射（如泛型 `PayloadOf[T]`） | 影响 API 复杂度 | ❌ **M2 决议：不做（关闭）**。主线保持 `Map[String, Json]`（Q3）；申报书未承诺该能力，不影响验收。若 M4/M5 出现真实需求，另开新问题而不是回填本条 | M2 |
| Q9 | 远端后端是否支持 serverless/cloud 端点（HTTPS + api-key） | 影响传输层默认配置 | 待定，`TransportOptions.base_url` 已支持 HTTPS | M3 |
| Q10 | `@async.Mutex` 在 `js` / `wasm` 下是否可用（决定 9.4 的最终形态） | 影响本地后端并发承诺 | ✅ **已定稿：可用**，native/js/wasm 均验证通过（13.3） | 已定稿 |
| Q11 | `moon.mod`（新格式）与 `moon.mod.json`（旧格式）最终取舍 | 影响 11.1 | ✅ **已定稿：用新格式 `moon.mod` / `moon.pkg`**——`moon fmt` 会自动完成迁移（M1 实测，见 13.4） | 已定稿 |
| Q12 | 是否需要「响应体大小上限」配置项，默认值取多少 | 影响 8.2 | 待定，暂定 32MB 硬编码 | M3 |
| Q13 | 申报书的模块名与仓库链接需回写（`moonbit-community` → `lexchb`） | 影响发布路径一致性 | 待刘总确认后同步 PROPOSAL.md | M1 前 |

> 每条定稿后，把结论并入正文并在「变更记录」留痕；`|` 不允许长期悬挂超过一个里程碑。

---

## 16. 编码与协作规范

- 命名：类型用大驼峰，函数/字段用小写下划线，与 MoonBit 标准库风格一致。
- 每个公共 API 需有 `///|` 文档注释，说明**语义**（尤其边界条件），而非重复签名。
- 不做无谓抽象：只有出现第二个实现时（local / remote）才抽 trait；不预留未被章节描述的扩展点。
- 注释只写「为什么」，不写「做了什么」。
- commit message 采用 `type(scope): subject` 形式（`feat` / `fix` / `docs` / `test` / `refactor` / `chore`），一个 commit 一件事，保证「有效 commit」计数真实反映开发量。
- 所有对外承诺（一致的目标支持范围、已知差异、并发限制）必须同时出现在本文档与 README，不得只在代码注释里写。

### 16.1 MoonBit 语法与惯用法清单（M0 实测，必须遵守）

以下每一条都是实测得出的硬性约束，写代码前先对照本文档：

| 主题 | 正确写法 | 错误写法 / 陷阱 |
| --- | --- | --- |
| 泛型参数位置 | `pub fn[T : Trait] name(..)` | `pub fn name[T](..)` → 解析错误 |
| 枚举 / suberror 具名字段 | `Variant(a~ : Int, b~ : String)`，构造时 `Variant(a=1, b="x")` | `Variant(a : Int)` 解析错误；不带标签构造报「labels are required」 |
| 结构体字面量 | 必须写全所有字段 | 不允许部分记录；无字段默认值 |
| 可省略字段 | 提供可选参数构造器 `T::new(a? : Int, b? : Int)` | 不要暴露裸结构体字面量给调用方 |
| 可选参数 | `fn f(a? : Int, b? : Bool = false)` | — |
| trait 方法调用 | 写 `pub extend Type with Trait::{m1, m2}` 才能用 `x.m1()` | 不写 `extend` 会告警，且只能 `Trait::m1(x)` |
| `Json` 构造 | `Json::number(d, repr?=s)` / `Json::string(s)` / `Json::object(m)` / `Json::array(a)` / `Json::null()` | 变体构造 `Number(..)` / `Object(..)` → 「read-only type」错误 |
| `Json` 模式匹配 | `if json is Object(m) { .. }` | 无限制，正常可用 |
| Int64 → JSON 数字 | `Json::number(n.to_double(), repr=n.to_string())` | `Int64` 默认 `ToJson` 输出**字符串** |
| from_json 抛错 | `raise @json.JsonDecodeError((path, "msg"))`，path 可用 `path.add_key("k")` | `@json.decode_error` 是私有函数，不可调用 |
| 数组绑定 | `let xs : Array[Int] = []` | 加不必要的 `mut` → `unused_mut` error |
| 空 Map | `Map([])` | 裸 `{}` → `ambiguous_braces` 告警 |
| 错误插值 | 需要 `impl Show for MyError` | suberror 不会自动获得 `Show`，`\{e}` 会编译失败 |
| 保留字 | 避免用 `method` 作参数名 | `method` 是保留字（告警） |
| 三方错误插值 | `catch { e => "\{e}" }`（具体类型可插值） | 对**抽象 `Error`** 无法做构造器模式匹配 |
| 可见性：可实现的 trait | `pub(open) trait T` | 裸 `pub trait` 是 readonly 的，外部包报 `Cannot implement trait ... because it is readonly` |
| 可见性：可构造的枚举 | `pub(all) enum E`；suberror 同理 `pub(all) suberror E` | 裸 `pub enum` 外部包报 `Cannot create values of the read-only type: X`；这类错误**只在跨包使用时才暴露** |
| 类型别名 | `pub type Vector = Array[Double]` | `pub typealias` 不存在，会被解析成 `type` 后跟小写标识符 → 解析错误 |
| `JsonPath` | 只能在 `impl FromJson` 内部作为推断出的 `path` 使用，并用 `path.add_key(..)` / `add_index(..)` | 该类型是包私有的，**无法写出类型名**，因此不能定义接受它的 helper 函数（需要时把逻辑内联） |
| 测试专用依赖 | `moon.pkg` 里 `import { "pkg" } for "test"`（旧格式 `test-import`） | 放进 `import` 会触发 `unused_package` 告警，也让生产 API 白依赖运行时 |
| 可选参数转发 | `f(gt?, gte?)`（在参数同名的函数里转发） | 直接传 `gt~` 会报类型不匹配（`Double?` vs `Double`） |
| 枚举变体名遮蔽 | `PayloadSchema::Boolean`（避免与内建 `Bool` 撞名） | 变体名为 `Bool` 时，本包内 `Bool(x)` 会被解析成该变体，Json 布尔匹配静默走错分支；Json 布尔应匹配 `True` / `False` |
| 黑盒测试命名 | `@core.VectorConfig::new(..)` | 在 `_test.mbt` 里用裸名会告警 `test_unqualified_package` |
| 迁移 mod/pkg | 交给 `moon fmt` 自动迁移 | 手工维护 JSON 格式细节没有收益 |
| **trait impl 的跨包可见性** | `pub impl Trait for Type with fn m(..)` | 裸 `impl` 只在**声明它的包内**可见，别的包报 `does not implement trait ...: no impl is defined`（M2 实测，同包测试永远发现不了） |
| impl 块内的方法声明 | `pub impl Tr for T with fn m(self, ..)` | **不能写 `async`**：`with async fn m(..)` → 解析错误；异步性由 trait 声明决定 |
| 泛型方法（含 trait 方法实现） | `fn[X : Eq + Show] Type::m(..)` | `fn Type::m[X : Eq + Show](..)` → 解析失败（泛型参数必须在名字**之前**） |
| `Map` 字面量 | `Map([(k, v), ..])`；空表 `Map([])` | `{ "k": v }` 在**实参位置**会被当成块 → 报错位置指向无关的 `)`；`Map::new()` 已弃用 |
| 常量 | `@math.PI` | `@math.pi` 已弃用（deprecated 告警） |
| 测试 helper 调 `fail` | `fn helper(..) -> Unit raise { .. }` | helper 未声明错误类型 → `Function with error can only be used inside a function with error types in its signature` |
| 结构体字面量的可见性 | 跨包读字段可以（`config.size`），**字面量构造**在 M2 实测可用（`ScrollPage`/`ScoredPoint` 在别的包构造成功） | 但只在「字段未被标 `priv`」时成立；`MemoryStore` 的字段刻意标了 `priv`，外部只能走 `new()` |
| 公共类型缺 `Show` | 断言比较渲染后的字符串/布尔表达式 | core 的类型只 derive 了 `Eq`；`"\{x}"` 插值需要 `Show`，用它做断言会编译失败 |

> **一条方法论**：MoonBit 的**解析错误会级联**成一大批看似无关的类型错误（M2 实例：`impl ... with async fn` 解析失败后，编译器在另一处报 `There is no record definition with the fields: points, next_offset`，而那个字面量完全正确）。遇到「类型错误难以理解」时，**先确认前面没有解析错误**，否则会照着错误信息往完全错误的方向改。

---

## 17. 风险与缓解

| 风险 | 影响 | 缓解 | 状态 |
| --- | --- | --- | --- |
| `@async` API 不稳定，且版本与工具链强耦合 | 传输层反复返工、甚至无法构建 | 传输层隔离；工具链与 `async` 成对锁死；升级单独 PR 并跑全量测试 | 已缓解（ADR-9） |
| trait 不支持 async → 抽象层重构 | M1 返工 | M0 已验证支持，风险消除 | 已消除 |
| `@async.retry` 擦除错误类型 | 无法实现精确重试策略 | 改为显式重试循环 | 已缓解（ADR-8） |
| Qdrant JSON 联合形状与 derive 不符 | 编解码错误、静默丢条件 | 手写编解码 + 双向往返测试 + 一致性测试 C7–C10 | 已缓解（ADR-3） |
| 本地后端距离语义与 Qdrant 不一致 | 一致性测试 C15 失败、用户信任受损 | Q6 已定稿（ADR-15）；M2 已固化黄金值并做容差比对（10 节） | 部分缓解（M2 为**解析式手算**黄金值，M3 必须用真实 Qdrant 复核） |
| **本库 `score` 与 Qdrant `score` 的换算未实测（M2 新增）** | Cosine / Dot 两个「相似度型」度量与 Qdrant 反号（9.2），若 M3 实测不符，C6/C15 与 README 全部要改 | 9.2 已把换算关系写成表格并在 README 预告；M3 用真实 Qdrant 对同批数据做数值比对 | 待处理（M3 必须闭环，不可拖过 M3） |
| 过滤路径语义差异引发误用 | 用户排查困难 | 不支持形式显式报 `Unsupported`（**M2 已实现**）；9.6 已把逐个条件语义划线；README「已知差异」待 M5 落地 | 已缓解（M2） |
| `text` 匹配在本地是子串近似，Qdrant 是分词全文 | 同一 filter 在两后端命中集合可能不同 | C9 只用「分词与子串结论一致」的样本；差异写入 README「已知差异」（M5） | 已缓解（M2，采样本规避） |
| Docker 集成测试在 CI 上不稳定 / 本机无 Docker | 阻塞合并、M3 无法起步 | 集成作业与单元作业分离、可跳过；本地用 HTTP 桩（已实测可行） | 已缓解（ADR-12） |
| 测试依赖共享状态导致不可重复 | 假性失败、CI 抖动 | 测试必须自包含；`async test` 并行执行这一事实写入 12.1 | 已缓解 |
| 响应体过大 | 内存打爆 | 读入后校验长度上限（32MB），超限报 `Decode` | 待处理（Q12） |
| **readonly 默认可见性挡住公共 API（M1 新增）** | 抽象层与所有枚举对外不可用，且只在跨包使用时才暴露 | 每个公共类型/API 都必须在黑盒测试里被构造一次（12.1 纪律 4）；已在 M1 抓到 2 个致命问题 | 已缓解（约束 5 / 13.4） |
| Qdrant 大整数 ID 丢精度 | 读不回已有点、静默错值 | `PointId` 用 `UInt64` + `repr` 精确十进制解析；M1 已用满量程 u64 往返测试覆盖 | 已缓解（ADR-14 / 7.3） |

---

## 18. 附录

### 18.1 参考规范

- Qdrant REST API / OpenAPI（v1.14 系列），Apache-2.0：<https://github.com/qdrant/qdrant>
- Query points 端点：<https://api.qdrant.tech/v-1-14-x/api-reference/search/query-points>
- 过滤与 `must` / `should` / `must_not` 语义：<https://qdrant.tech/documentation/search/filtering/>
- MoonBit async（experimental）与目标支持：<https://docs.moonbitlang.com/en/latest/language/async-experimental.html>
- MoonBit 模块/包配置：<https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html> 、<https://docs.moonbitlang.com/en/latest/toolchain/moon/package.html>

> 本项目为原创实现，不复制 Qdrant 源码；仅在 README 中注明 API 规范来源。

### 18.2 术语对照（Qdrant 字段 ↔ 本库语义）

| Qdrant | 本库 |
| --- | --- |
| `vectors.size` | `VectorConfig.size` |
| `vectors.distance` | `VectorConfig.distance` |
| `with_payload` | `SearchRequest.with_payload` |
| `score_threshold` | `SearchRequest.score_threshold` |
| `next_page_offset` | `ScrollPage.next_offset` |
| `status.error` | `VectorStoreError::Http.message` |
