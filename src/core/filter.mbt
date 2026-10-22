///| 过滤条件 DSL。设计目标：把 Qdrant 最复杂、最易出错的部分（must / should /
/// must_not 嵌套）变成类型安全的构造器，而不是让用户手写 JSON（DEVELOPMENT.md 7.1）。

///|
/// 过滤条件。三个子句数组，元素既可以是单条件，也可以是嵌套的 Filter。
///
/// 结构体 + derive 即可：`Array[Clause]?` 字段为 None 时会被自动省略，
/// 与 Qdrant 期望的形状一致（DEVELOPMENT.md 7.3）。
pub(all) struct Filter {
  must : Array[Clause]?
  should : Array[Clause]?
  must_not : Array[Clause]?
} derive(Eq, ToJson, @json.FromJson)

///|
pub fn Filter::new(
  must? : Array[Clause],
  should? : Array[Clause],
  must_not? : Array[Clause],
) -> Filter {
  { must, should, must_not, }
}

///|
/// 空过滤器：三个子句全为 None。
pub fn Filter::empty() -> Filter {
  Filter::new()
}

///|
/// 子句：单条件，或嵌套的 Filter（Qdrant 允许 must 里直接放一个 filter 对象）。
/// 必须是 `pub(all)`，否则外部包无法构造（裸 `pub enum` 是 readonly 的）。
pub(all) enum Clause {
  Cond(condition~ : Condition)
  Group(filter~ : Filter)
} derive(Eq)

///|
pub fn Clause::from_condition(c : Condition) -> Clause {
  Cond(condition=c)
}

///|
pub fn Clause::from_filter(f : Filter) -> Clause {
  Group(filter=f)
}

///|
/// 单个过滤条件。
///
/// 注意两处与其余条件不同的形状（DEVELOPMENT.md 7.2）：
/// - `HasId` 没有 key，形如 `{"has_id": [...]}`；
/// - `Nested` 的 key 在 nested 对象内部，形如 `{"nested": {"key": .., "filter": ..}}`。
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

///|
/// match 的四种互斥形状，线上是内联对象（非外部标签），故编解码手写。
pub(all) enum MatchValue {
  Value(Json)
  Any(Array[Json])
  Except(Array[Json])
  Text(String)
} derive(Eq)

///|
/// range 的四条边界。derive 即可：None 字段会被自动省略。
pub(all) struct RangeSpec {
  gt : Double?
  gte : Double?
  lt : Double?
  lte : Double?
} derive(Eq, ToJson, @json.FromJson)

///|
pub fn RangeSpec::new(
  gt? : Double,
  gte? : Double,
  lt? : Double,
  lte? : Double,
) -> RangeSpec {
  { gt, gte, lt, lte, }
}

///|
/// 地理坐标点。
pub(all) struct GeoPoint {
  lat : Double
  lon : Double
} derive(Eq, ToJson, @json.FromJson)

///|
pub fn GeoPoint::new(lat~ : Double, lon~ : Double) -> GeoPoint {
  { lat, lon, }
}

///|
/// 地理矩形范围。
pub(all) struct GeoBox {
  top_left : GeoPoint
  bottom_right : GeoPoint
} derive(Eq, ToJson, @json.FromJson)

///|
pub fn GeoBox::new(top_left~ : GeoPoint, bottom_right~ : GeoPoint) -> GeoBox {
  { top_left, bottom_right, }
}

///|
/// 地理半径范围。
pub(all) struct GeoRadiusSpec {
  center : GeoPoint
  radius : Double
} derive(Eq, ToJson, @json.FromJson)

///|
pub fn GeoRadiusSpec::new(
  center~ : GeoPoint,
  radius~ : Double,
) -> GeoRadiusSpec {
  { center, radius, }
}

///|
/// 数组元素个数范围。四条边界同为 None 时会被省略。
pub(all) struct ValuesCountSpec {
  gt : Int32?
  gte : Int32?
  lt : Int32?
  lte : Int32?
} derive(Eq, ToJson, @json.FromJson)

///|
pub fn ValuesCountSpec::new(
  gt? : Int32,
  gte? : Int32,
  lt? : Int32,
  lte? : Int32,
) -> ValuesCountSpec {
  { gt, gte, lt, lte, }
}

///|
/// 常用条件的便捷构造器：让调用方不必写冗长的标签形式。
pub fn Condition::match_value(key : String, value : Json) -> Condition {
  Match(key~, value=MatchValue::Value(value))
}

///|
pub fn Condition::match_str(key : String, value : String) -> Condition {
  Match(key~, value=MatchValue::Value(Json::string(value)))
}

///|
pub fn Condition::match_int(key : String, value : Int32) -> Condition {
  Match(key~, value=MatchValue::Value(Json::number(value.to_double())))
}

///|
pub fn Condition::match_bool(key : String, value : Bool) -> Condition {
  Match(key~, value=MatchValue::Value(Json::boolean(value)))
}

///|
pub fn Condition::match_any(key : String, values : Array[String]) -> Condition {
  Match(key~, value=MatchValue::Any(values.map(v => Json::string(v))))
}

///|
pub fn Condition::match_except(
  key : String,
  values : Array[String],
) -> Condition {
  Match(key~, value=MatchValue::Except(values.map(v => Json::string(v))))
}

///|
pub fn Condition::match_text(key : String, text : String) -> Condition {
  Match(key~, value=MatchValue::Text(text))
}

///|
pub fn Condition::range(
  key : String,
  gt? : Double,
  gte? : Double,
  lt? : Double,
  lte? : Double,
) -> Condition {
  Range(key~, spec=RangeSpec::new(gt?, gte?, lt?, lte?))
}

///|
pub fn Condition::has_id(ids : Array[PointId]) -> Condition {
  HasId(ids~)
}

///|
pub fn Condition::nested(key : String, filter : Filter) -> Condition {
  Nested(key~, filter~)
}

///|
pub fn Condition::is_empty(key : String, value : Bool) -> Condition {
  IsEmpty(key~, value~)
}

///|
pub fn Condition::is_null(key : String, value : Bool) -> Condition {
  IsNull(key~, value~)
}

///|
pub fn Condition::values_count(
  key : String,
  gt? : Int32,
  gte? : Int32,
  lt? : Int32,
  lte? : Int32,
) -> Condition {
  ValuesCount(key~, spec=ValuesCountSpec::new(gt?, gte?, lt?, lte?))
}
