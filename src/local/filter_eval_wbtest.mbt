///| 路径语义与过滤求值的白盒测试（DEVELOPMENT.md 7.4 / 9.6）。
///
/// 这里刻意测三类东西：
/// 1. **不支持的形式必须报错**（静默判「不匹配」是最危险的失败模式）；
/// 2. **缺 key 与空值的区别**（`except`、`is_null`、`is_empty` 的分界全靠它）；
/// 3. 每个 Condition 的正反两面。

///|
fn expect(case : String, actual : Bool) -> Unit raise {
  if actual == false {
    fail(case)
  }
}

///|
/// 断言某个表达式的求值会抛 `Unsupported`（且确实**没有**抛别的错误）。
fn expect_unsupported(path : String) -> Unit raise {
  let kind = try {
    ignore(parse_path(path))
    "no-error"
  } catch {
    @core.VectorStoreError::Unsupported(_) => "Unsupported"
    _ => "other"
  }
  if kind != "Unsupported" {
    fail("路径 `\{path}` 期望 Unsupported，实际 \{kind}")
  }
}

///|
/// 便捷构造 payload。
fn payload(entries : Array[(String, Json)]) -> @core.Payload {
  Map(entries)
}

///|
test "parse_path：支持的形式" {
  expect("a.b.c 应解析成功", parse_path("a.b.c").length() == 3)
  let segs = parse_path("a.b[].c")
  expect("a.b[].c 应解析为 3 段", segs.length() == 3)
  expect("第二段应标记展开", segs[1].expand)
  expect("第一段不应展开", segs[0].expand == false)
  expect("末段不应展开", segs[2].expand == false)
}

///|
test "parse_path：不支持的形式一律抛 Unsupported（不静默）" {
  expect_unsupported("")
  expect_unsupported("a..b")
  expect_unsupported(".a")
  expect_unsupported("a.")
  expect_unsupported("a[0]")
  expect_unsupported("a[*]")
  expect_unsupported("a[][]")
}

///|
test "resolve_path：点号嵌套与 `[]` 展开" {
  let data = payload([
    (
      "a",
      Json::object(
        payload([("b", Json::object(payload([("c", Json::number(7.0))])))]),
      ),
    ),
    (
      "list",
      Json::array([
        Json::object(payload([("k", Json::number(1.0))])),
        Json::object(payload([("k", Json::number(2.0))])),
      ]),
    ),
  ])
  let nested = resolve_path(data, parse_path("a.b.c"))
  expect("a.b.c 应取到一个候选", nested.length() == 1)
  expect("a.b.c 的值应为 7", nested[0] == Json::number(7.0))

  let expanded = resolve_path(data, parse_path("list[].k"))
  expect("list[].k 应展开出 2 个候选", expanded.length() == 2)

  // 没有 `[]` 时数组不会自动下钻（`[]` 的语义就是「显式展开」）
  let not_expanded = resolve_path(data, parse_path("list.k"))
  expect("list.k 不应取到候选", not_expanded.length() == 0)

  let missing = resolve_path(data, parse_path("nope.x"))
  expect("缺失路径应无候选", missing.length() == 0)
}

///|
test "缺 key 与空值的分界：except / is_null / is_empty" {
  let data = payload([
    ("tenant", Json::string("acme")),
    ("empty_list", Json::array([])),
    ("tags", Json::array([Json::string("a")])),
  ])
  let id = @core.PointId::of_int(1UL)

  // 缺 key 的取值类条件一律不匹配 —— 包括语义上「反面」的 except
  let except_missing = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::match_except("nope", ["x"])),
  ])
  expect(
    "缺 key 的 except 应不匹配",
    eval_filter(except_missing, data, id) == false,
  )

  // 但「取到空数组」与「缺 key」不同：except 在空集合上恒真（9.6 口径）
  let except_empty = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::match_except("empty_list", ["x"]),
    ),
  ])
  expect(
    "对空数组的 except 应匹配",
    eval_filter(except_empty, data, id),
  )

  // is_null 与 Qdrant 对齐：只匹配显式 null；缺字段 is_null(true) 不命中、false 命中
  let null_missing = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::is_null("nope", true)),
  ])
  expect(
    "is_null(true) 对缺字段应不命中（与 Qdrant 对齐）",
    eval_filter(null_missing, data, id) == false,
  )

  let null_false = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::is_null("nope", false)),
  ])
  expect(
    "is_null(false) 对缺字段应命中（与 Qdrant 对齐）",
    eval_filter(null_false, data, id),
  )

  // is_empty 与 Qdrant 对齐：空数组命中，缺字段也算「空」
  let empty_true = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::is_empty("empty_list", true)),
  ])
  expect("is_empty(true) 应命中空数组", eval_filter(empty_true, data, id))

  let empty_on_missing = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::is_empty("nope", true)),
  ])
  expect(
    "is_empty(true) 对缺 key 应命中（与 Qdrant 对齐）",
    eval_filter(empty_on_missing, data, id),
  )

  let empty_false = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::is_empty("tags", false)),
  ])
  expect(
    "is_empty(false) 应命中非空数组",
    eval_filter(empty_false, data, id),
  )
}

///|
test "数组型 payload：match / range 按任一元素判定" {
  let data = payload([
    ("tags", Json::array([Json::string("a"), Json::string("b")])),
    ("nums", Json::array([Json::number(1.0), Json::number(5.0)])),
  ])
  let id = @core.PointId::of_int(1UL)

  let hit = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::match_str("tags", "b")),
  ])
  expect("tags 含 b 应命中", eval_filter(hit, data, id))

  let miss = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::match_str("tags", "z")),
  ])
  expect("tags 不含 z 应不命中", eval_filter(miss, data, id) == false)

  let ranged = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::range("nums", gte=4.0)),
  ])
  expect("nums 任一元素 ≥ 4 应命中", eval_filter(ranged, data, id))
}

///|
test "values_count：数组取长度、对象取键数、标量不匹配" {
  let data = payload([
    ("arr2", Json::array([Json::number(1.0), Json::number(2.0)])),
    (
      "obj",
      Json::object(
        payload([("a", Json::number(1.0)), ("b", Json::number(2.0))]),
      ),
    ),
    ("scalar", Json::number(1.0)),
  ])
  let id = @core.PointId::of_int(1UL)

  let arr_ok = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::values_count("arr2", gte=2, lte=2),
    ),
  ])
  expect("长度 2 的数组应命中", eval_filter(arr_ok, data, id))

  let obj_ok = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::values_count("obj", gte=2)),
  ])
  expect("2 键的对象应命中", eval_filter(obj_ok, data, id))

  let scalar_no = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::values_count("scalar", gte=1)),
  ])
  expect(
    "标量不应命中 values_count",
    eval_filter(scalar_no, data, id) == false,
  )
}

///|
test "nested：数组内的对象元素任一满足" {
  let data = payload([
    (
      "nested",
      Json::array([
        Json::object(payload([("kind", Json::string("x"))])),
        Json::object(payload([("kind", Json::string("y"))])),
      ]),
    ),
  ])
  let id = @core.PointId::of_int(1UL)
  let inner = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::match_str("kind", "y")),
  ])
  let hit = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::nested("nested", inner)),
  ])
  expect("任一元素满足即命中", eval_filter(hit, data, id))

  let inner_miss = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::match_str("kind", "z")),
  ])
  let miss = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::nested("nested", inner_miss)),
  ])
  expect("没有元素满足则不命中", eval_filter(miss, data, id) == false)

  // 值不是数组时 nested 不命中（而不是报错）
  let not_array = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::nested("nope", inner)),
  ])
  expect(
    "缺 key 的 nested 不命中",
    eval_filter(not_array, data, id) == false,
  )
}

///|
test "geo：矩形范围与半径（米）" {
  let data = payload([
    (
      "geo",
      Json::object(
        payload([("lat", Json::number(0.0)), ("lon", Json::number(0.0))]),
      ),
    ),
  ])
  let id = @core.PointId::of_int(1UL)

  let inside = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::GeoBoundingBox(
        key="geo",
        box=@core.GeoBox::new(
          top_left=@core.GeoPoint::new(lat=1.0, lon=-1.0),
          bottom_right=@core.GeoPoint::new(lat=-1.0, lon=1.0),
        ),
      ),
    ),
  ])
  expect("(0,0) 应落在矩形内", eval_filter(inside, data, id))

  let outside = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::GeoBoundingBox(
        key="geo",
        box=@core.GeoBox::new(
          top_left=@core.GeoPoint::new(lat=10.0, lon=10.0),
          bottom_right=@core.GeoPoint::new(lat=9.0, lon=11.0),
        ),
      ),
    ),
  ])
  expect(
    "(0,0) 不应落在远处矩形内",
    eval_filter(outside, data, id) == false,
  )

  // 1 度纬度 ≈ 111km：半径 200km 命中，100km 不命中
  let near = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::GeoRadius(
        key="geo",
        spec=@core.GeoRadiusSpec::new(
          center=@core.GeoPoint::new(lat=1.0, lon=0.0),
          radius=200000.0,
        ),
      ),
    ),
  ])
  expect("1 度 ≈ 111km 应落在 200km 内", eval_filter(near, data, id))

  let far = @core.Filter::new(must=[
    @core.Clause::from_condition(
      @core.Condition::GeoRadius(
        key="geo",
        spec=@core.GeoRadiusSpec::new(
          center=@core.GeoPoint::new(lat=1.0, lon=0.0),
          radius=100000.0,
        ),
      ),
    ),
  ])
  expect("111km 应落在 100km 外", eval_filter(far, data, id) == false)
}

///|
test "组合语义：should 非空即恒定要求至少一个为真" {
  let data = payload([("tenant", Json::string("acme"))])
  let id = @core.PointId::of_int(1UL)
  // must 命中，但 should 全部不命中 ⇒ 整体不匹配（9.6 定稿的语义）
  let combined = @core.Filter::new(
    must=[
      @core.Clause::from_condition(@core.Condition::match_str("tenant", "acme")),
    ],
    should=[
      @core.Clause::from_condition(@core.Condition::match_str("nope", "x")),
    ],
  )
  expect(
    "must 命中但 should 全不命中 ⇒ 不匹配",
    eval_filter(combined, data, id) == false,
  )

  // must_not 命中即否决
  let vetoed = @core.Filter::new(must_not=[
    @core.Clause::from_condition(@core.Condition::match_str("tenant", "acme")),
  ])
  expect(
    "must_not 命中 ⇒ 不匹配",
    eval_filter(vetoed, data, id) == false,
  )
}

///|
test "不支持的路径形式在求值阶段也抛 Unsupported" {
  let data = payload([("a", Json::number(1.0))])
  let id = @core.PointId::of_int(1UL)
  let bad = @core.Filter::new(must=[
    @core.Clause::from_condition(@core.Condition::match_str("a[0]", "x")),
  ])
  let kind = try {
    ignore(eval_filter(bad, data, id))
    "no-error"
  } catch {
    @core.VectorStoreError::Unsupported(_) => "Unsupported"
    _ => "other"
  }
  expect("a[0] 应抛 Unsupported，实际 \{kind}", kind == "Unsupported")
}
