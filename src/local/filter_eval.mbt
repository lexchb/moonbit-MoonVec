///| Filter 求值：把 core 的过滤 DSL 应用到内存 payload 上。
///
/// 逐个条件的语义在 DEVELOPMENT.md 9.6 已定稿，本文件只负责实现，**不引入新语义**。
/// 总原则：取值类条件在路径取不到值时一律不匹配，唯一例外是 `is_null(value=true)`。

///|
/// 求值入口。`point_id` 只被 `has_id` 与嵌套 filter 透传使用。
fn eval_filter(
  filter : @core.Filter,
  payload : @core.Payload,
  point_id : @core.PointId,
) -> Bool raise @core.VectorStoreError {
  if filter.must is Some(clauses) {
    for clause in clauses {
      guard eval_clause(clause, payload, point_id) else { return false }
    }
  }
  if filter.should is Some(clauses) {
    // 9.6 定稿：只要 should 非空就**恒定**要求至少一个为真，不因 must 非空而放宽
    if clauses.length() > 0 {
      let mut matched = false
      for clause in clauses {
        if eval_clause(clause, payload, point_id) {
          matched = true
        }
      }
      guard matched else { return false }
    }
  }
  if filter.must_not is Some(clauses) {
    for clause in clauses {
      if eval_clause(clause, payload, point_id) {
        return false
      }
    }
  }
  true
}

///|
/// 子句：单条件，或嵌套的 Filter（递归，层数不设上限）。
fn eval_clause(
  clause : @core.Clause,
  payload : @core.Payload,
  point_id : @core.PointId,
) -> Bool raise @core.VectorStoreError {
  match clause {
    @core.Cond(condition~) => eval_condition(condition, payload, point_id)
    @core.Group(filter~) => eval_filter(filter, payload, point_id)
  }
}

///|
fn eval_condition(
  condition : @core.Condition,
  payload : @core.Payload,
  point_id : @core.PointId,
) -> Bool raise @core.VectorStoreError {
  match condition {
    // has_id 不看 payload，因此与路径语义无关
    @core.HasId(ids~) => ids.contains(point_id)
    @core.Match(key~, value~) => eval_match(key, value, payload)
    @core.Range(key~, spec~) => eval_range(key, spec, payload)
    @core.GeoBoundingBox(key~, box~) => eval_geo_box(key, box, payload)
    @core.GeoRadius(key~, spec~) => eval_geo_radius(key, spec, payload)
    @core.ValuesCount(key~, spec~) => eval_values_count(key, spec, payload)
    @core.IsEmpty(key~, value~) => eval_is_empty(key, value, payload)
    @core.IsNull(key~, value~) => eval_is_null(key, value, payload)
    @core.Nested(key~, filter~) => eval_nested(key, filter, payload, point_id)
  }
}

///|
/// 路径取值。抛 `Unsupported` 的那一层在 `parse_path` 内（9.6）。
fn values_at(
  key : String,
  payload : @core.Payload,
) -> Array[Json] raise @core.VectorStoreError {
  resolve_path(payload, parse_path(key))
}

///|
/// 「任一候选与期望值相等」。用内建的 `Json` 相等（`==`）：它对数字只比数值、
/// 忽略字面量写法差异（`1` 与 `1.0` 相等），其余类型递归比较。
fn any_equals(candidates : Array[Json], expected : Json) -> Bool {
  for candidate in candidates {
    if candidate == expected {
      return true
    }
  }
  false
}

///|
fn eval_match(
  key : String,
  value : @core.MatchValue,
  payload : @core.Payload,
) -> Bool raise @core.VectorStoreError {
  // 判据是「路径取到值」而不是「展开后的标量非空」：否则 `except` 在
  // 「空数组」与「缺 key」两种情形上会混为一谈（9.6 总原则）
  let raw = values_at(key, payload)
  if raw.length() == 0 {
    return false
  }
  let candidates = flat_scalars(raw)
  match value {
    @core.Value(expected) => any_equals(candidates, expected)
    @core.Any(expected) => {
      for one in expected {
        if any_equals(candidates, one) {
          return true
        }
      }
      false
    }
    @core.Except(excluded) => {
      for one in excluded {
        if any_equals(candidates, one) {
          return false
        }
      }
      true
    }
    @core.Text(text) => {
      let needle = text.to_lower()
      for candidate in candidates {
        if text_hit(candidate, needle) {
          return true
        }
      }
      false
    }
  }
}

///|
/// `text` 的本地近似实现：子串包含（不区分大小写）。Qdrant 走的是分词全文索引，
/// 差异记入 README「已知差异」；一致性测试只采样两者结论一致的文本（9.6）。
fn text_hit(value : Json, needle : String) -> Bool {
  if value is String(text) {
    text.to_lower().find(needle) is Some(_)
  } else {
    false
  }
}

///|
/// 四条边界共用：`None` 表示该侧不限；用 `Double` 以便 `range` 与 `values_count` 复用。
fn within_bounds(
  value : Double,
  gt : Double?,
  gte : Double?,
  lt : Double?,
  lte : Double?,
) -> Bool {
  let mut ok = true
  if gt is Some(bound) {
    if value <= bound {
      ok = false
    }
  }
  if gte is Some(bound) {
    if value < bound {
      ok = false
    }
  }
  if lt is Some(bound) {
    if value >= bound {
      ok = false
    }
  }
  if lte is Some(bound) {
    if value > bound {
      ok = false
    }
  }
  ok
}

///|
fn eval_range(
  key : String,
  spec : @core.RangeSpec,
  payload : @core.Payload,
) -> Bool raise @core.VectorStoreError {
  let raw = values_at(key, payload)
  if raw.length() == 0 {
    return false
  }
  for candidate in flat_scalars(raw) {
    if candidate is Number(number, ..) {
      if within_bounds(number, spec.gt, spec.gte, spec.lt, spec.lte) {
        return true
      }
    }
  }
  false
}

///|
fn eval_geo_box(
  key : String,
  box : @core.GeoBox,
  payload : @core.Payload,
) -> Bool raise @core.VectorStoreError {
  let raw = values_at(key, payload)
  if raw.length() == 0 {
    return false
  }
  for candidate in flat_scalars(raw) {
    if geo_point_of(candidate) is Some((lat, lon)) {
      if lat <= box.top_left.lat &&
        lat >= box.bottom_right.lat &&
        lon >= box.top_left.lon &&
        lon <= box.bottom_right.lon {
        return true
      }
    }
  }
  false
}

///|
fn eval_geo_radius(
  key : String,
  spec : @core.GeoRadiusSpec,
  payload : @core.Payload,
) -> Bool raise @core.VectorStoreError {
  let raw = values_at(key, payload)
  if raw.length() == 0 {
    return false
  }
  for candidate in flat_scalars(raw) {
    if geo_point_of(candidate) is Some((lat, lon)) {
      if haversine_meters(spec.center.lat, spec.center.lon, lat, lon) <=
        spec.radius {
        return true
      }
    }
  }
  false
}

///|
/// haversine 距离（米）。地球半径取 6371000 m，与 Qdrant 的 `radius` 量纲一致（9.6）。
fn haversine_meters(
  lat1 : Double,
  lon1 : Double,
  lat2 : Double,
  lon2 : Double,
) -> Double {
  let to_rad = @math.PI / 180.0
  let half_dlat = (lat2 - lat1) * to_rad / 2.0
  let half_dlon = (lon2 - lon1) * to_rad / 2.0
  let a = @math.sin(half_dlat) * @math.sin(half_dlat) +
    @math.cos(lat1 * to_rad) *
    @math.cos(lat2 * to_rad) *
    @math.sin(half_dlon) *
    @math.sin(half_dlon)
  // 数值误差可能让 a 略大于 1，直接 sqrt 会得到 NaN
  let clamped = if a > 1.0 { 1.0 } else { a }
  2.0 * 6371000.0 * @math.atan2(clamped.sqrt(), (1.0 - clamped).sqrt())
}

///|
fn eval_values_count(
  key : String,
  spec : @core.ValuesCountSpec,
  payload : @core.Payload,
) -> Bool raise @core.VectorStoreError {
  let raw = values_at(key, payload)
  if raw.length() == 0 {
    return false
  }
  for candidate in raw {
    let count = match candidate {
      Array(items) => Some(items.length())
      Object(fields) => Some(fields.length())
      _ => None
    }
    if count is Some(number) {
      if within_bounds(
          number.to_double(),
          spec.gt.map(bound => bound.to_double()),
          spec.gte.map(bound => bound.to_double()),
          spec.lt.map(bound => bound.to_double()),
          spec.lte.map(bound => bound.to_double()),
        ) {
        return true
      }
    }
  }
  false
}

///|
/// `is_empty`：只看**值本身**是否为空数组/空对象。key 缺失时判不匹配（9.6）。
fn eval_is_empty(
  key : String,
  expect_empty : Bool,
  payload : @core.Payload,
) -> Bool raise @core.VectorStoreError {
  let candidates = values_at(key, payload)
  if candidates.length() == 0 {
    return false
  }
  let mut seen_empty = false
  for candidate in candidates {
    match candidate {
      Array(items) => if items.length() == 0 { seen_empty = true }
      Object(fields) => if fields.length() == 0 { seen_empty = true }
      _ => ()
    }
  }
  seen_empty == expect_empty
}

///|
/// `is_null`：**key 缺失也算命中 `true`** —— 这是「缺失 key 一律不匹配」的唯一例外，
/// 因为 Qdrant 的 `is_null` 本来就是为了匹配「缺字段 / 空字段」而存在的（9.6）。
fn eval_is_null(
  key : String,
  expect_null : Bool,
  payload : @core.Payload,
) -> Bool raise @core.VectorStoreError {
  let candidates = values_at(key, payload)
  let mut nullish = candidates.length() == 0
  for candidate in candidates {
    if candidate is Null {
      nullish = true
    }
  }
  nullish == expect_null
}

///|
/// `nested`：key 的值必须是数组，其**任一对象元素**满足内层 filter。
/// 内层 filter 以该元素自身为 payload 求值（9.6）。
fn eval_nested(
  key : String,
  inner : @core.Filter,
  payload : @core.Payload,
  point_id : @core.PointId,
) -> Bool raise @core.VectorStoreError {
  for candidate in values_at(key, payload) {
    if candidate is Array(items) {
      for item in items {
        if item is Object(fields) {
          if eval_filter(inner, fields, point_id) {
            return true
          }
        }
      }
    }
  }
  false
}
