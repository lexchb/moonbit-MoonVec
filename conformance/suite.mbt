///| 一致性测试套件（DEVELOPMENT.md 10）。
///
/// 两个后端（local / remote）都必须跑通同一套断言，这是 G7「两个后端行为一致」的
/// 唯一保证机制，也是两端不漂移的抓手。
///
/// 设计要点（ADR-17）：套件**不依赖测试框架**，失败以字符串列表返回，由调用方的测试
/// 文件决定怎么报。原因是 `@test.fail` 的错误类型是抽象 `Error`，与套件的
/// `raise VectorStoreError` 不兼容；顺带还换来「一次跑完全部场景」的好处。
///
/// 调用契约：`name_prefix` 每次调用必须不同（`async test` 并行执行，集合名不得撞车），
/// 套件创建的集合全部带该前缀且会在结束时自行删除。
///
/// 断言风格说明：core 的公共类型只 derive 了 `Eq`（M1 决议），没有 `Show`。因此除
/// `Int` / `Bool` / `String` 外，本套件不直接比较结构体，而是**比较渲染后的字符串**或
/// 布尔表达式，并把可读的实际值写进失败信息里。

///|
/// 套件运行期状态。`failures` 是 Array（引用语义），因此按值传递 `Suite` 也能把
/// 失败信息带回调用方。
priv struct Suite {
  prefix : String
  failures : Array[String]
}

///|
fn Suite::new(prefix : String) -> Suite {
  { prefix, failures: [], }
}

///|
/// 集合名 = 前缀 + 后缀，保证不同调用之间不冲突。
fn Suite::name(self : Suite, suffix : String) -> String {
  "\{self.prefix}_\{suffix}"
}

///|
/// 记录一条失败，**不抛错**：套件要跑完全部场景，一次看全（10 节）。
fn Suite::report(self : Suite, scenario : String, message : String) -> Unit {
  self.failures.push("\{scenario}：\{message}")
}

///|
fn[X : Eq + Show] Suite::expect_eq(
  self : Suite,
  scenario : String,
  what : String,
  actual : X,
  expected : X,
) -> Unit {
  if actual != expected {
    self.report(scenario, "\{what} 期望 \{expected}，实际 \{actual}")
  }
}

///|
fn Suite::expect_true(
  self : Suite,
  scenario : String,
  what : String,
  actual : Bool,
) -> Unit {
  if actual == false {
    self.report(scenario, "\{what}")
  }
}

///|
/// payload 构造：`payload_of([("tenant", Json::string("acme")), ..])`。
///
/// 不用 `{ "k": v }` 字面量，是因为在**实参位置**大括号会被优先解析成块而非 Map，
/// 语法歧义会让错误信息指向莫名其妙的位置（M2 踩坑）。
fn payload_of(entries : Array[(String, Json)]) -> @core.Payload {
  Map(entries)
}

///|
/// 浮点比较：以 `max(1, |expected|)` 为标尺的**相对**误差，避免大数上的绝对误差失真。
fn close_enough(actual : Double, expected : Double) -> Bool {
  let scale = if expected.abs() > 1.0 { expected.abs() } else { 1.0 }
  (actual - expected).abs() / scale <= 1.0e-6
}

///|
/// ID 的稳定字符串表示。`PointId` 没有 `Show`，故手写；同时用于失败信息的可读性。
fn id_key(id : @core.PointId) -> String {
  match id {
    @core.Num(number) => "n:\{number}"
    @core.Uuid(text) => "u:\{text}"
  }
}

///|
/// 把 ID 列表变成**排序后**的字符串列表：与预期集合比较时不依赖返回顺序
/// （Q5 不承诺全局顺序，见 9.3），只比较集合本身。
fn id_set(ids : Array[@core.PointId]) -> Array[String] {
  let out : Array[String] = []
  for id in ids {
    out.push(id_key(id))
  }
  out.sort()
  out
}

///|
/// 把渲染好的 ID 列表拼成一行，供失败信息使用。
fn join_keys(keys : Array[String]) -> String {
  let mut out = ""
  for i = 0; i < keys.length(); i = i + 1 {
    if i > 0 {
      out = out + ","
    }
    out = out + keys[i]
  }
  out
}

///|
fn ids_of_numbers(numbers : Array[Int32]) -> Array[@core.PointId] {
  let out : Array[@core.PointId] = []
  for number in numbers {
    out.push(@core.PointId::of_int(number.to_uint64()))
  }
  out
}

///|
/// 断言「ID 集合相等」，失败信息渲染成 `[n:1,n:2]` 形态。
fn Suite::expect_ids(
  self : Suite,
  scenario : String,
  what : String,
  actual : Array[@core.PointId],
  expected : Array[Int32],
) -> Unit {
  let actual_keys = join_keys(id_set(actual))
  let expected_keys = join_keys(id_set(ids_of_numbers(expected)))
  if actual_keys != expected_keys {
    self.report(
      scenario,
      "\{what} 命中集合期望 [\{expected_keys}]，实际 [\{actual_keys}]",
    )
  }
}

///|
/// 断言「实际 ID 等于期望 ID」。
fn Suite::expect_id(
  self : Suite,
  scenario : String,
  what : String,
  actual : @core.PointId,
  expected : @core.PointId,
) -> Unit {
  if actual != expected {
    self.report(
      scenario,
      "\{what} 期望 \{id_key(expected)}，实际 \{id_key(actual)}",
    )
  }
}

///|
/// 断言「条数正确且无重复」。
fn Suite::expect_unique_count(
  self : Suite,
  scenario : String,
  what : String,
  ids : Array[@core.PointId],
  expected : Int32,
) -> Unit {
  let keys = id_set(ids)
  if keys.length() != expected {
    self.report(
      scenario,
      "\{what} 期望 \{expected} 条，实际 \{keys.length()} 条（[\{join_keys(keys)}]）",
    )
    return
  }
  let mut unique = true
  for i = 1; i < keys.length(); i = i + 1 {
    if keys[i - 1] == keys[i] {
      unique = false
    }
  }
  if unique == false {
    self.report(scenario, "\{what} 出现重复：[\{join_keys(keys)}]")
  }
}

///|
/// 翻完全部页，返回所有点 ID。既用于条数断言，也是 C12「不重不漏」的载体。
async fn scroll_all(
  store : &@core.VectorStore,
  name : String,
  page_size : Int32,
) -> Array[@core.PointId] raise @core.VectorStoreError {
  let out : Array[@core.PointId] = []
  let mut offset : @core.PointId? = None
  let mut rounds = 0
  // 上限只是防御性护栏：正常的游标一定会收敛到 None
  while rounds < 1000 {
    rounds = rounds + 1
    let request = match offset {
      Some(id) => @core.ScrollRequest::new(limit=page_size, offset=id)
      None => @core.ScrollRequest::new(limit=page_size)
    }
    let page = store.scroll(name, request)
    if page.points.length() == 0 {
      break
    }
    for point in page.points {
      out.push(point.id)
    }
    match page.next_offset {
      Some(id) => offset = Some(id)
      None => break
    }
  }
  out
}

///|
/// 搜索并返回结果 ID 集合（比较用）。
async fn search_ids(
  store : &@core.VectorStore,
  name : String,
  filter : @core.Filter,
) -> Array[@core.PointId] raise @core.VectorStoreError {
  let hits = store.search(
    name,
    @core.SearchRequest::new(
      vector=[1.0, 0.0, 0.0, 0.0],
      limit=100,
      filter~,
      with_payload=false,
    ),
  )
  let out : Array[@core.PointId] = []
  for hit in hits {
    out.push(hit.id)
  }
  out
}

///|
/// 断言「过滤器命中的 ID 集合与预期一致」。
async fn Suite::expect_filter(
  self : Suite,
  scenario : String,
  what : String,
  store : &@core.VectorStore,
  name : String,
  filter : @core.Filter,
  expected : Array[Int32],
) -> Unit raise @core.VectorStoreError {
  let actual = search_ids(store, name, filter)
  self.expect_ids(scenario, what, actual, expected)
}

///|
/// 从结果里挑出指定 ID 的分数（C15 用：limit 放到全量，按 ID 定位自己的分数）。
fn score_of(hits : Array[@core.ScoredPoint], id : @core.PointId) -> Double? {
  for hit in hits {
    if hit.id == id {
      return Some(hit.score)
    }
  }
  None
}

///|
/// C5–C12 共用的只读数据集（Euclid，维度 4）。
/// 分数刻意设计成「有唯一最近点 / 有明显的并列 / 有边界命中」三种情形。
fn main_points() -> Array[@core.Point] {
  [
    @core.Point::new(
      id=@core.PointId::of_int(1UL),
      vector=[1.0, 0.0, 0.0, 0.0],
      payload=payload_of([
        ("tenant", Json::string("acme")),
        ("score", Json::number(0.5)),
        ("doc_type", Json::string("guide")),
        ("tags", Json::array([Json::string("a"), Json::string("b")])),
        ("title", Json::string("Quick brown fox")),
        (
          "nested",
          Json::array([
            Json::object(
              payload_of([
                ("kind", Json::string("x")),
                ("weight", Json::number(1.0)),
              ]),
            ),
          ]),
        ),
        (
          "geo",
          Json::object(
            payload_of([("lat", Json::number(1.0)), ("lon", Json::number(1.0))]),
          ),
        ),
        ("empty_list", Json::array([])),
      ]),
    ),
    @core.Point::new(
      id=@core.PointId::of_int(2UL),
      vector=[0.0, 1.0, 0.0, 0.0],
      payload=payload_of([
        ("tenant", Json::string("acme")),
        ("score", Json::number(0.9)),
        ("doc_type", Json::string("draft")),
        ("tags", Json::array([Json::string("b"), Json::string("c")])),
        ("title", Json::string("Lazy dog")),
        (
          "nested",
          Json::array([
            Json::object(
              payload_of([
                ("kind", Json::string("y")),
                ("weight", Json::number(2.0)),
              ]),
            ),
          ]),
        ),
        (
          "geo",
          Json::object(
            payload_of([
              ("lat", Json::number(10.0)),
              ("lon", Json::number(10.0)),
            ]),
          ),
        ),
        ("count", Json::number(3.0)),
      ]),
    ),
    @core.Point::new(
      id=@core.PointId::of_int(3UL),
      vector=[0.0, 0.0, 1.0, 0.0],
      payload=payload_of([
        ("tenant", Json::string("globex")),
        ("score", Json::number(0.7)),
        ("doc_type", Json::string("guide")),
        ("tags", Json::array([Json::string("c")])),
        ("title", Json::string("Quick brown bear")),
        (
          "nested",
          Json::array([
            Json::object(
              payload_of([
                ("kind", Json::string("x")),
                ("weight", Json::number(3.0)),
              ]),
            ),
          ]),
        ),
        ("count", Json::number(1.0)),
      ]),
    ),
    // 这个点刻意**不带** score / title / nested / geo / count：C11 的「缺 key」用例全靠它
    @core.Point::new(
      id=@core.PointId::of_int(4UL),
      vector=[0.0, 0.0, 0.0, 1.0],
      payload=payload_of([
        ("tenant", Json::string("globex")),
        ("doc_type", Json::string("trash")),
        ("tags", Json::array([Json::string("d")])),
      ]),
    ),
    // 与查询 [1,0,0,0] 的距离恰好为 1.0：C6 的「阈值取等号」用例靠它
    @core.Point::new(
      id=@core.PointId::of_int(5UL),
      vector=[1.0, 1.0, 0.0, 0.0],
      payload=payload_of([
        ("tenant", Json::string("acme")),
        ("score", Json::number(0.5)),
        ("doc_type", Json::string("guide")),
        ("tags", Json::array([Json::string("a")])),
        ("title", Json::string("Quick brown cat")),
        (
          "nested",
          Json::array([
            Json::object(
              payload_of([
                ("kind", Json::string("x")),
                ("weight", Json::number(0.5)),
              ]),
            ),
          ]),
        ),
        ("count", Json::number(2.0)),
      ]),
    ),
  ]
}

///|
/// 写入路径专用数据集（C3 / C4 / C13 依次作用在同一个集合上，故顺序敏感）。
fn write_points() -> Array[@core.Point] {
  [
    @core.Point::new(
      id=@core.PointId::of_int(1UL),
      vector=[1.0, 0.0, 0.0, 0.0],
      payload=payload_of([
        ("tenant", Json::string("acme")),
        ("score", Json::number(0.4)),
      ]),
    ),
    @core.Point::new(
      id=@core.PointId::of_int(2UL),
      vector=[0.0, 1.0, 0.0, 0.0],
      payload=payload_of([
        ("tenant", Json::string("acme")),
        ("score", Json::number(0.8)),
      ]),
    ),
    @core.Point::new(
      id=@core.PointId::of_int(3UL),
      vector=[0.0, 0.0, 1.0, 0.0],
      payload=payload_of([
        ("tenant", Json::string("globex")),
        ("score", Json::number(0.6)),
      ]),
    ),
    @core.Point::new(
      id=@core.PointId::of_int(4UL),
      vector=[0.0, 0.0, 0.0, 1.0],
      payload=payload_of([("tenant", Json::string("globex"))]),
    ),
  ]
}

///|
/// C1：建集合 → 存在性 → 描述。
async fn check_c1(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  let config = @core.VectorConfig::new(size=4, distance=@core.Euclid)
  store.create_collection(name, config)
  suite.expect_true(
    "C1",
    "新建集合后 collection_exists 应为 true",
    store.collection_exists(name),
  )
  let described = store.describe_collection(name)
  suite.expect_eq("C1", "描述出的 size", described.size, 4)
  suite.expect_true(
    "C1",
    "描述出的 distance 应为创建时的 Euclid",
    described.distance == @core.Euclid,
  )
}

///|
/// C2：重复建同名集合（Q4 定稿：配置一致幂等，不一致 Conflict）。
async fn check_c2(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  store.create_collection(
    name,
    @core.VectorConfig::new(size=4, distance=@core.Euclid),
  )
  let conflict = try {
    store.create_collection(
      name,
      @core.VectorConfig::new(size=8, distance=@core.Euclid),
    )
    false
  } catch {
    @core.VectorStoreError::Conflict(_) => true
    _ => false
  }
  suite.expect_true(
    "C2", "同名集合配置不一致应报 Conflict", conflict,
  )
  suite.expect_eq(
    "C2",
    "冲突后集合仍存在",
    store.collection_exists(name),
    true,
  )
}

///|
/// C4：批量 upsert（先跑，因为 C3 会覆盖其中一条）。
async fn check_c4(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  store.create_collection(
    name,
    @core.VectorConfig::new(size=4, distance=@core.Euclid),
  )
  let result = store.upsert(name, write_points(), true)
  suite.expect_true("C4", "批量 upsert 应返回 All", result == @core.All)
  let ids = scroll_all(store, name, 2)
  suite.expect_unique_count("C4", "批量写入后的条数", ids, 4)
}

///|
/// C3：upsert 覆盖同 ID（只保留最新值，条数不增）。
async fn check_c3(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  let overwritten = @core.Point::new(
    id=@core.PointId::of_int(2UL),
    vector=[1.0, 1.0, 1.0, 1.0],
    payload=payload_of([
      ("tenant", Json::string("globex")),
      ("score", Json::number(0.1)),
    ]),
  )
  ignore(store.upsert(name, [overwritten], true))
  let fetched = store.retrieve(name, [@core.PointId::of_int(2UL)], true, true)
  suite.expect_eq(
    "C3",
    "覆盖后 retrieve 的命中条数",
    fetched.length(),
    1,
  )
  if fetched.length() == 1 {
    suite.expect_true(
      "C3",
      "覆盖后的向量应为 [1,1,1,1]",
      fetched[0].vector == Some([1.0, 1.0, 1.0, 1.0]),
    )
    let tenant = match fetched[0].payload {
      Some(map) => map.get("tenant")
      None => None
    }
    suite.expect_true(
      "C3",
      "覆盖后的 payload.tenant 应为 globex",
      tenant == Some(Json::string("globex")),
    )
  }
  let ids = scroll_all(store, name, 2)
  suite.expect_unique_count("C3", "覆盖写后的条数", ids, 4)
}

///|
/// C13：delete_points / delete_by_filter。
async fn check_c13(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  store.delete_points(name, [@core.PointId::of_int(4UL)])
  let gone = store.retrieve(name, [@core.PointId::of_int(4UL)], true, false)
  suite.expect_eq(
    "C13",
    "delete_points 后 retrieve 的条数",
    gone.length(),
    0,
  )
  let after_points = scroll_all(store, name, 2)
  suite.expect_unique_count(
    "C13", "delete_points 后的条数", after_points, 3,
  )

  // 此时 id=2 的 tenant 已被 C3 改成 globex，故只应删掉 id=1
  store.delete_by_filter(
    name,
    @core.Filter::new(must=[
      @core.Clause::from_condition(@core.Condition::match_str("tenant", "acme")),
    ]),
  )
  let after_filter = scroll_all(store, name, 2)
  suite.expect_unique_count(
    "C13", "delete_by_filter 后的条数", after_filter, 2,
  )
  let removed = store.retrieve(name, [@core.PointId::of_int(1UL)], true, false)
  suite.expect_eq(
    "C13",
    "被 filter 删掉的点 retrieve 条数",
    removed.length(),
    0,
  )
}

///|
/// C5：检索 top-k。只断言「单调不减 + 唯一的最近点 + limit 生效」，
/// **不断言并列次序**（远端不承诺，见 9.3）。
async fn check_c5(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  let hits = store.search(
    name,
    @core.SearchRequest::new(
      vector=[1.0, 0.0, 0.0, 0.0],
      limit=3,
      with_payload=false,
    ),
  )
  suite.expect_eq("C5", "limit=3 的返回条数", hits.length(), 3)
  if hits.length() == 3 {
    suite.expect_id(
      "C5",
      "最近点（距离 0）",
      hits[0].id,
      @core.PointId::of_int(1UL),
    )
    suite.expect_id(
      "C5",
      "次近点（距离 1.0）",
      hits[1].id,
      @core.PointId::of_int(5UL),
    )
    suite.expect_true(
      "C5",
      "第三名分数应为 √2（并列组），实际 \{hits[2].score}",
      close_enough(hits[2].score, 2.0.sqrt()),
    )
  }
  let mut monotone = true
  for i = 1; i < hits.length(); i = i + 1 {
    if hits[i - 1].score > hits[i].score {
      monotone = false
    }
  }
  suite.expect_true("C5", "分数应单调不减", monotone)

  let all = store.search(
    name,
    @core.SearchRequest::new(
      vector=[1.0, 0.0, 0.0, 0.0],
      limit=100,
      with_payload=false,
    ),
  )
  suite.expect_eq("C5", "limit 超过总数时返回全部", all.length(), 5)
}

///|
/// C6：score_threshold（与 Qdrant 对齐：仅保留 `score < threshold` 的点，2026-10-22 实测）。
async fn check_c6(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  let hits = store.search(
    name,
    @core.SearchRequest::new(
      vector=[1.0, 0.0, 0.0, 0.0],
      limit=100,
      score_threshold=1.0,
      with_payload=false,
    ),
  )
  let ids : Array[@core.PointId] = []
  for hit in hits {
    ids.push(hit.id)
  }
  suite.expect_ids(
    "C6",
    "阈值 1.0 仅保留距离 < 1.0 的点（与 Qdrant 对齐，等号排除）",
    ids,
    [1],
  )
}

///|
/// C7：must / should / must_not。
async fn check_c7(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  let must_filter = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::match_str("tenant", "acme")),
  ])
  suite.expect_filter("C7", "must: tenant=acme", store, name, must_filter, [
    1, 2, 5,
  ])

  let should_filter = @core.Filter::new(should=[
    @core.Clause::from_condition(@core.Condition::match_str("tenant", "globex")),
    @core.Clause::from_condition(@core.Condition::range("score", gte=0.9)),
  ])
  suite.expect_filter(
    "C7",
    "should: tenant=globex 或 score>=0.9",
    store,
    name,
    should_filter,
    [2, 3, 4],
  )

  let must_not_filter = @core.Filter::new(must_not=[
    @core.Clause::from_condition(
      @core.Condition::match_any("doc_type", ["draft", "trash"]),
    ),
  ])
  suite.expect_filter(
    "C7",
    "must_not: doc_type 在 (draft,trash) 的取反",
    store,
    name,
    must_not_filter,
    [1, 3, 5],
  )

  // 9.6 定稿的 should 语义：**非空即恒定要求至少一个为真**，不因 must 非空而放宽。
  // 这是与 Qdrant 之间最需要 M3 校准的一条（10 节），故单独列用例把它钉住。
  let combined = @core.Filter::new(
    must=[
      @core.Clause::from_condition(@core.Condition::match_str("tenant", "acme")),
    ],
    should=[
      @core.Clause::from_condition(
        @core.Condition::match_str("doc_type", "guide"),
      ),
    ],
  )
  suite.expect_filter(
    "C7",
    "must + should: acme 且 doc_type=guide",
    store,
    name,
    combined,
    [1, 5],
  )
}

///|
/// C8：嵌套 Filter（`Clause::Group`）。
async fn check_c8(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  let inner = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::range("score", gte=0.9)),
  ])
  let grouped = @core.Filter::new(must=[@core.Clause::from_filter(inner)])
  suite.expect_filter(
    "C8",
    "must 内嵌 filter: score>=0.9",
    store,
    name,
    grouped,
    [2],
  )

  let mixed = @core.Filter::new(
    must=[
      @core.Clause::from_condition(@core.Condition::match_str("tenant", "acme")),
    ],
    must_not=[@core.Clause::from_filter(inner)],
  )
  suite.expect_filter(
    "C8",
    "must + must_not 内嵌: acme 且 score<0.9",
    store,
    name,
    mixed,
    [1, 5],
  )
}

///|
/// C9：match 的 value / any / except / text（含数组元素的隐式匹配）。
async fn check_c9(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  let value_filter = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::match_str("tenant", "acme")),
  ])
  suite.expect_filter("C9", "match.value", store, name, value_filter, [1, 2, 5])

  let any_filter = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::match_any("doc_type", ["draft", "trash"]),
    ),
  ])
  suite.expect_filter("C9", "match.any", store, name, any_filter, [2, 4])

  let except_filter = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::match_except("doc_type", ["draft", "trash"]),
    ),
  ])
  suite.expect_filter("C9", "match.except", store, name, except_filter, [
    1, 3, 5,
  ])

  // 文本样本与 Qdrant 的分词结果一致（"brown" 是独立词），避开 9.6 的近似差异
  let text_filter = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::match_text("title", "brown")),
  ])
  suite.expect_filter(
    "C9",
    "match.text（分词一致的样本）",
    store,
    name,
    text_filter,
    [1, 3, 5],
  )

  // 数组型 payload 的隐式「任一元素」语义
  let array_filter = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::match_str("tags", "b")),
  ])
  suite.expect_filter(
    "C9",
    "数组元素匹配: tags 含 b",
    store,
    name,
    array_filter,
    [1, 2],
  )
}

///|
/// C10：range 的四种边界与组合。
async fn check_c10(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  // gte 含等号（id=1、id=5 都恰好是 0.5，必须命中）、lt 不含等号（id=2 恰好是 0.9，必须排除）
  let score_filter = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::range("score", gte=0.5, lt=0.9),
    ),
  ])
  suite.expect_filter(
    "C10",
    "range score in [0.5, 0.9)",
    store,
    name,
    score_filter,
    [1, 3, 5],
  )

  // gt 不含等号（1 不命中）、lte 含等号（3 命中）
  let count_filter = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::range("count", gt=1.0, lte=3.0),
    ),
  ])
  suite.expect_filter(
    "C10",
    "range count in (1, 3]",
    store,
    name,
    count_filter,
    [2, 5],
  )
}

///|
/// C11：缺失 key。取值类条件一律不匹配；is_null / is_empty 对缺字段的行为与 Qdrant
/// 对齐（2026-10-22 实测）：is_null(true) 不命中缺字段、is_null(false) 命中。
async fn check_c11(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  let missing_match = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::match_str("nonexistent_field", "x"),
    ),
  ])
  suite.expect_filter(
    "C11",
    "缺失 key 的 match 不匹配",
    store,
    name,
    missing_match,
    [],
  )

  let missing_range = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::range("score", gt=0.0)),
  ])
  suite.expect_filter(
    "C11",
    "缺失 key 的 range 不匹配（只有 id=4 缺 score）",
    store,
    name,
    missing_range,
    [1, 2, 3, 5],
  )

  // Qdrant 的 is_null 只匹配显式 null；套件数据无 null 值 → true 分支空
  let is_null_true = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::is_null("title", true)),
  ])
  suite.expect_filter(
    "C11",
    "is_null(title,true) 只匹配显式 null（缺字段不命中）",
    store,
    name,
    is_null_true,
    [],
  )

  // is_null(false) 匹配非 null；缺字段视为非 null（与 Qdrant 一致）
  let is_null_false = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::is_null("title", false)),
  ])
  suite.expect_filter(
    "C11",
    "is_null(title,false) 匹配非 null（含缺字段）",
    store,
    name,
    is_null_false,
    [1, 2, 3, 4, 5],
  )
}

///|
/// C16：`values_count` / `is_empty` / `geo`（加入共享套件，B8 解决）。
/// 断言只依赖 main_points 里**确定存在**的字段：id=1 有 geo(1,1) 与 empty_list;
/// tags 分布为 id1/2 长2、id3/4/5 长1。
async fn check_c16(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  // values_count：数组长度计数（9.6：数组取 length）
  let vc_filter = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::values_count("tags", gte=2)),
  ])
  suite.expect_filter(
    "C16",
    "values_count: tags 长度≥2（九.6 数组计数）",
    store,
    name,
    vc_filter,
    [1, 2],
  )

  // is_empty：与 Qdrant 对齐——缺字段也算「空」，故除 id=1（空数组）外全部命中
  let ie_filter = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::is_empty("empty_list", true)),
  ])
  suite.expect_filter(
    "C16",
    "is_empty(empty_list,true) 命中空数组与缺字段（与 Qdrant 对齐）",
    store,
    name,
    ie_filter,
    [1, 2, 3, 4, 5],
  )

  // geo_bounding_box：矩形 [lat 0..2, lon 0..2] 只含 id=1(1,1)
  let geo_box = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::GeoBoundingBox(
        key="geo",
        box=@core.GeoBox::new(
          top_left=@core.GeoPoint::new(lat=2.0, lon=0.0),
          bottom_right=@core.GeoPoint::new(lat=0.0, lon=2.0),
        ),
      ),
    ),
  ])
  suite.expect_filter(
    "C16",
    "geo_bounding_box 只含 id=1",
    store,
    name,
    geo_box,
    [1],
  )

  // geo_radius：中心(1,1)半径 50m 只含 id=1（其余无 geo 或距离远）
  let geo_radius = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::GeoRadius(
        key="geo",
        spec=@core.GeoRadiusSpec::new(
          center=@core.GeoPoint::new(lat=1.0, lon=1.0),
          radius=50.0,
        ),
      ),
    ),
  ])
  suite.expect_filter(
    "C16",
    "geo_radius 中心(1,1)只含 id=1",
    store,
    name,
    geo_radius,
    [1],
  )
}

///|
/// C12：scroll 分页游标（Q5：只承诺不重不漏）。
async fn check_c12(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  let ids = scroll_all(store, name, 2)
  suite.expect_unique_count(
    "C12", "分页遍历全量（页大小 2）", ids, 5,
  )
  // 换成页大小 1 再翻一遍：游标语义必须在不同页大小下都成立
  let one_by_one = scroll_all(store, name, 1)
  suite.expect_unique_count(
    "C12", "分页遍历全量（页大小 1）", one_by_one, 5,
  )
}

///|
/// C14：错误种类（只断言语义级种类，不碰本地私有的 Http/Decode 等分支，见 9.5）。
async fn check_c14(
  store : &@core.VectorStore,
  suite : Suite,
  name : String,
) -> Unit raise @core.VectorStoreError {
  let missing = "\{name}_missing"
  let described = try {
    ignore(store.describe_collection(missing))
    "no-error"
  } catch {
    @core.VectorStoreError::NotFound(_) => "NotFound"
    // 细分错误种类，便于在真实 Qdrant 上定位映射偏差
    @core.VectorStoreError::Http(status~, ..) => "Http(\{status})"
    @core.VectorStoreError::InvalidArgument(_) => "InvalidArgument"
    @core.VectorStoreError::Decode(_) => "Decode"
    @core.VectorStoreError::Server(status~, ..) => "Server(\{status})"
    @core.VectorStoreError::Conflict(_) => "Conflict"
    @core.VectorStoreError::Auth(_) => "Auth"
    @core.VectorStoreError::RateLimited(_) => "RateLimited"
    @core.VectorStoreError::Transport(message~) => "Transport:\{message}"
    @core.VectorStoreError::Timeout(_) => "Timeout"
    _ => "other"
  }
  suite.expect_eq(
    "C14", "不存在的集合 describe 的错误种类", described, "NotFound",
  )

  let searched = try {
    ignore(
      store.search(
        missing,
        @core.SearchRequest::new(vector=[1.0, 0.0, 0.0, 0.0], limit=1),
      ),
    )
    "no-error"
  } catch {
    @core.VectorStoreError::NotFound(_) => "NotFound"
    @core.VectorStoreError::Http(status~, ..) => "Http(\{status})"
    @core.VectorStoreError::InvalidArgument(_) => "InvalidArgument"
    @core.VectorStoreError::Decode(_) => "Decode"
    @core.VectorStoreError::Server(status~, ..) => "Server(\{status})"
    @core.VectorStoreError::Conflict(_) => "Conflict"
    @core.VectorStoreError::Auth(_) => "Auth"
    @core.VectorStoreError::RateLimited(_) => "RateLimited"
    @core.VectorStoreError::Transport(message~) => "Transport:\{message}"
    @core.VectorStoreError::Timeout(_) => "Timeout"
    _ => "other"
  }
  suite.expect_eq(
    "C14", "不存在的集合 search 的错误种类", searched, "NotFound",
  )

  let bad_dim = try {
    ignore(
      store.upsert(
        name,
        [@core.Point::new(id=@core.PointId::of_int(9UL), vector=[1.0, 2.0])],
        true,
      ),
    )
    "no-error"
  } catch {
    @core.VectorStoreError::InvalidArgument(_) => "InvalidArgument"
    _ => "other"
  }
  suite.expect_eq(
    "C14", "维度不符的错误种类", bad_dim, "InvalidArgument",
  )

  let bad_limit = try {
    ignore(
      store.search(
        name,
        @core.SearchRequest::new(vector=[1.0, 0.0, 0.0, 0.0], limit=0),
      ),
    )
    "no-error"
  } catch {
    @core.VectorStoreError::InvalidArgument(_) => "InvalidArgument"
    _ => "other"
  }
  suite.expect_eq(
    "C14", "limit<1 的错误种类", bad_limit, "InvalidArgument",
  )

  // 说明：C14 不再断言「不支持路径 → Unsupported」。该语义是 local 私有的
  // （Qdrant 本身支持 `a[0]` 数组下标，见 9.6 路径语义划线）；远端若真遇到
  // 不支持的路径会由 Qdrant 返回 4xx。local 侧的 Unsupported 由
  // `src/local/filter_eval_wbtest.mbt` 白盒覆盖，两后端此行为本就不该一致。

  // 维度不符的写入不能留下副作用
  let still_five = scroll_all(store, name, 2)
  suite.expect_unique_count(
    "C14", "失败的 upsert 不留副作用", still_five, 5,
  )
}

///|
/// C15 的一条黄金用例：查询向量、入库点、期望分数。
priv struct GoldenCase {
  query : Array[Double]
  point : Array[Double]
  expected : Double
}

///|
/// C15：距离数值。M2 用**解析式手算**黄金值（10 节声明这不是端到端比对）；
/// M3 必须用真实 Qdrant 复核同一批数据。
async fn check_c15(
  store : &@core.VectorStore,
  suite : Suite,
  label : String,
  name : String,
  metric : @core.Distance,
  cases : Array[GoldenCase],
) -> Unit raise @core.VectorStoreError {
  store.create_collection(
    name,
    @core.VectorConfig::new(size=2, distance=metric),
  )
  let points : Array[@core.Point] = []
  for i = 0; i < cases.length(); i = i + 1 {
    points.push(
      @core.Point::new(
        id=@core.PointId::of_int((i + 1).to_uint64()),
        vector=cases[i].point,
      ),
    )
  }
  ignore(store.upsert(name, points, true))
  for i = 0; i < cases.length(); i = i + 1 {
    let hits = store.search(
      name,
      @core.SearchRequest::new(
        vector=cases[i].query,
        limit=cases.length(),
        with_payload=false,
      ),
    )
    let id = @core.PointId::of_int((i + 1).to_uint64())
    match score_of(hits, id) {
      Some(score) =>
        if close_enough(score, cases[i].expected) == false {
          suite.report(
            "C15",
            "用例 #\{i}（\{label}）分数期望 \{cases[i].expected}，实际 \{score}",
          )
        }
      None =>
        suite.report(
          "C15",
          "用例 #\{i}（\{label}）在结果里找不到自己的点",
        )
    }
  }
}

///|
/// 跑完整套 C1–C16。返回失败消息列表（空列表 = 全绿）。
pub async fn run_conformance(
  store : &@core.VectorStore,
  name_prefix : String,
) -> Array[String] raise @core.VectorStoreError {
  let suite = Suite::new(name_prefix)
  let main = suite.name("main")
  let write = suite.name("write")
  let created : Array[String] = [main, write]

  check_c1(store, suite, main)
  check_c2(store, suite, main)
  // 先灌只读数据集，再跑所有只读断言（顺序敏感：C14 之后 main 不应再被改动）
  ignore(store.upsert(main, main_points(), true))
  check_c5(store, suite, main)
  check_c6(store, suite, main)
  check_c7(store, suite, main)
  check_c8(store, suite, main)
  check_c9(store, suite, main)
  check_c10(store, suite, main)
  check_c11(store, suite, main)
  check_c16(store, suite, main)
  check_c12(store, suite, main)
  check_c14(store, suite, main)

  // 写路径依次作用于同一个集合：C4 灌数据 → C3 覆盖 → C13 删除
  check_c4(store, suite, write)
  check_c3(store, suite, write)
  check_c13(store, suite, write)

  // C15：四种度量各一个集合。黄金值全部来自解析式手算，零向量用例体现 Q6 的约定。
  let cosine_cases : Array[GoldenCase] = [
    { query: [1.0, 0.0], point: [1.0, 0.0], expected: 0.0, },
    { query: [1.0, 0.0], point: [0.0, 1.0], expected: 1.0, },
    // 零向量约定（Q6 / ADR-15）：cos 记 0 ⇒ 分数恒为 1.0
    { query: [0.0, 0.0], point: [1.0, 0.0], expected: 1.0, },
    { query: [1.0, 0.0], point: [0.0, 0.0], expected: 1.0, },
    // cos = 3/5 ⇒ 分数 1 - 0.6 = 0.4
    { query: [1.0, 0.0], point: [3.0, 4.0], expected: 0.4, },
  ]
  let euclid_cases : Array[GoldenCase] = [
    { query: [1.0, 0.0], point: [0.0, 1.0], expected: 2.0.sqrt(), },
    { query: [0.0, 0.0], point: [3.0, 4.0], expected: 5.0, },
    { query: [1.0, 0.0], point: [1.0, 0.0], expected: 0.0, },
    { query: [2.0, 2.0], point: [5.0, 6.0], expected: 5.0, },
  ]
  let dot_cases : Array[GoldenCase] = [
    { query: [1.0, 0.0], point: [0.0, 1.0], expected: 0.0, },
    { query: [1.0, 2.0], point: [3.0, 4.0], expected: -11.0, },
    { query: [0.0, 0.0], point: [3.0, 4.0], expected: 0.0, },
  ]
  let manhattan_cases : Array[GoldenCase] = [
    { query: [1.0, 0.0], point: [0.0, 1.0], expected: 2.0, },
    { query: [0.0, 0.0], point: [3.0, 4.0], expected: 7.0, },
    { query: [2.0, 2.0], point: [5.0, 6.0], expected: 7.0, },
  ]
  let cosine_name = suite.name("cosine")
  created.push(cosine_name)
  check_c15(store, suite, "Cosine", cosine_name, @core.Cosine, cosine_cases)
  let euclid_name = suite.name("euclid")
  created.push(euclid_name)
  check_c15(store, suite, "Euclid", euclid_name, @core.Euclid, euclid_cases)
  let dot_name = suite.name("dot")
  created.push(dot_name)
  check_c15(store, suite, "Dot", dot_name, @core.Dot, dot_cases)
  let manhattan_name = suite.name("manhattan")
  created.push(manhattan_name)
  check_c15(
    store,
    suite,
    "Manhattan",
    manhattan_name,
    @core.Manhattan,
    manhattan_cases,
  )

  // 自清理：套件只删自己创建的集合，不碰其他数据
  for name in created {
    store.delete_collection(name) catch {
      _ => ()
    }
  }
  suite.failures
}
