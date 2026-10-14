///| 手写 JSON 编解码集中在此文件（DEVELOPMENT.md 7.3 的约束）。
///
/// 为什么必须手写：Qdrant 多处使用「非外部标签」的联合类型 —— PointId 是裸数字或
/// 裸字符串，match 是内联的 value/any/except/text，Condition 把 key 与子对象展平在
/// 同一层。`derive` 只能生成外部标签（形如 `{"Cond": ...}`），与该形状不兼容。
///
/// 结构体则相反：`derive` 会自动省略值为 None 的可选字段，正是 Qdrant 期望的形状，
/// 所以 RangeSpec / GeoBox / ValuesCountSpec / Filter 都用 derive，见 filter.mbt。

///|
/// 从十进制字面量精确解析 UInt64。
///
/// 用途：JSON 数字在 MoonBit 中落到 Double，超过 2^53 会丢精度。Qdrant 的随机 ID 是
/// 满量程 u64，因此必须优先使用词法器保留的原始字面量（Json 的 repr 字段）。
fn parse_decimal_uint64(text : String) -> UInt64? {
  if text.length() == 0 {
    return None
  }
  let mut acc : UInt64 = 0UL
  let mut seen = false
  for code in text.code_units() {
    let digit : UInt64 = match code {
      '0' => 0UL
      '1' => 1UL
      '2' => 2UL
      '3' => 3UL
      '4' => 4UL
      '5' => 5UL
      '6' => 6UL
      '7' => 7UL
      '8' => 8UL
      '9' => 9UL
      _ => return None
    }
    let next = acc * 10UL + digit
    // 回除校验，捕获溢出（比逐位比较最大值更简单且精确）
    if next / 10UL != acc {
      return None
    }
    acc = next
    seen = true
  }
  if seen {
    Some(acc)
  } else {
    None
  }
}

///|
/// PointId：线上是裸数字或裸字符串。
pub impl ToJson for PointId with fn to_json(self) {
  match self {
    Num(n) => Json::number(n.to_double(), repr=n.to_string())
    Uuid(s) => Json::string(s)
  }
}

///|
pub impl @json.FromJson for PointId with fn from_json(json, path) {
  match json {
    Number(n, repr~) => {
      let exact = match repr {
        Some(r) => parse_decimal_uint64(r)
        None => None
      }
      match exact {
        Some(v) => Num(v)
        None =>
          if n < 0.0 {
            raise @json.JsonDecodeError((path, "PointId: negative numeric id"))
          } else {
            // 只能退化到 Double 转换；此时 > 2^53 的值可能已不精确
            Num(n.to_uint64())
          }
      }
    }
    String(s) => Uuid(s)
    _ =>
      raise @json.JsonDecodeError((path, "PointId: expected number or string"))
  }
}

///|
/// Distance：线上是裸字符串。
pub impl ToJson for Distance with fn to_json(self) {
  match self {
    Cosine => Json::string("Cosine")
    Euclid => Json::string("Euclid")
    Dot => Json::string("Dot")
    Manhattan => Json::string("Manhattan")
  }
}

///|
pub impl @json.FromJson for Distance with fn from_json(json, path) {
  guard json is String(s) else {
    raise @json.JsonDecodeError((path, "Distance: expected string"))
  }
  match s {
    "Cosine" => Cosine
    "Euclid" => Euclid
    "Dot" => Dot
    "Manhattan" => Manhattan
    _ => raise @json.JsonDecodeError((path, "Distance: unknown metric \{s}"))
  }
}

///|
/// PayloadSchema：线上是 Qdrant 的小写 schema 名。
pub impl ToJson for PayloadSchema with fn to_json(self) {
  match self {
    Keyword => Json::string("keyword")
    Integer => Json::string("integer")
    Float => Json::string("float")
    Boolean => Json::string("bool")
    Geo => Json::string("geo")
    Text => Json::string("text")
  }
}

///|
pub impl @json.FromJson for PayloadSchema with fn from_json(json, path) {
  guard json is String(s) else {
    raise @json.JsonDecodeError((path, "PayloadSchema: expected string"))
  }
  match s {
    "keyword" => Keyword
    "integer" => Integer
    "float" => Float
    "bool" => Boolean
    "geo" => Geo
    "text" => Text
    _ =>
      raise @json.JsonDecodeError((path, "PayloadSchema: unknown schema \{s}"))
  }
}

///|
/// MatchValue：四个互斥的内联形状。
pub impl ToJson for MatchValue with fn to_json(self) {
  match self {
    Value(j) => Json::object({ "value": j })
    Any(a) => Json::object({ "any": Json::array(a) })
    Except(a) => Json::object({ "except": Json::array(a) })
    Text(s) => Json::object({ "text": Json::string(s) })
  }
}

///|
pub impl @json.FromJson for MatchValue with fn from_json(json, path) {
  guard json is Object(m) else {
    raise @json.JsonDecodeError((path, "MatchValue: expected object"))
  }
  if m.get("value") is Some(v) {
    return Value(v)
  }
  if m.get("any") is Some(v) {
    guard v is Array(a) else {
      raise @json.JsonDecodeError((path, "MatchValue.any: expected array"))
    }
    return Any(a)
  }
  if m.get("except") is Some(v) {
    guard v is Array(a) else {
      raise @json.JsonDecodeError((path, "MatchValue.except: expected array"))
    }
    return Except(a)
  }
  if m.get("text") is Some(v) {
    guard v is String(s) else {
      raise @json.JsonDecodeError((path, "MatchValue.text: expected string"))
    }
    return Text(s)
  }
  raise @json.JsonDecodeError((path, "MatchValue: no recognized key"))
}

///|
/// Condition：key 与子对象展平在同一层；HasId 与 Nested 形状特殊。
pub impl ToJson for Condition with fn to_json(self) {
  match self {
    Match(key~, value~) =>
      Json::object({ "key": Json::string(key), "match": @json.to_json(value) })
    Range(key~, spec~) =>
      Json::object({ "key": Json::string(key), "range": @json.to_json(spec) })
    GeoBoundingBox(key~, box~) =>
      Json::object({
        "key": Json::string(key),
        "geo_bounding_box": @json.to_json(box),
      })
    GeoRadius(key~, spec~) =>
      Json::object({
        "key": Json::string(key),
        "geo_radius": @json.to_json(spec),
      })
    ValuesCount(key~, spec~) =>
      Json::object({
        "key": Json::string(key),
        "values_count": @json.to_json(spec),
      })
    IsEmpty(key~, value~) =>
      Json::object({
        "key": Json::string(key),
        "is_empty": Json::boolean(value),
      })
    IsNull(key~, value~) =>
      Json::object({ "key": Json::string(key), "is_null": Json::boolean(value) })
    HasId(ids~) =>
      Json::object({ "has_id": Json::array(ids.map(id => @json.to_json(id))) })
    Nested(key~, filter~) =>
      Json::object({
        "nested": Json::object({
          "key": Json::string(key),
          "filter": @json.to_json(filter),
        }),
      })
  }
}

///|
pub impl @json.FromJson for Condition with fn from_json(json, path) {
  guard json is Object(m) else {
    raise @json.JsonDecodeError((path, "Condition: expected object"))
  }
  // HasId 没有 key
  if m.get("has_id") is Some(v) {
    guard v is Array(a) else {
      raise @json.JsonDecodeError((path, "Condition.has_id: expected array"))
    }
    let ids : Array[PointId] = []
    for i = 0; i < a.length(); i = i + 1 {
      ids.push(@json.from_json(a[i], path=path.add_key("has_id").add_index(i)))
    }
    return HasId(ids~)
  }
  // Nested 的 key 在 nested 对象内部
  if m.get("nested") is Some(v) {
    guard v is Object(nm) else {
      raise @json.JsonDecodeError((path, "Condition.nested: expected object"))
    }
    guard nm.get("key") is Some(String(inner_key)) else {
      raise @json.JsonDecodeError((path, "Condition.nested: missing key"))
    }
    guard nm.get("filter") is Some(f) else {
      raise @json.JsonDecodeError((path, "Condition.nested: missing filter"))
    }
    let filter : Filter = @json.from_json(
      f,
      path=path.add_key("nested").add_key("filter"),
    )
    return Nested(key=inner_key, filter~)
  }
  // 其余条件都有顶层 key
  guard m.get("key") is Some(String(key)) else {
    raise @json.JsonDecodeError((path, "Condition: missing key"))
  }
  if m.get("match") is Some(sub) {
    let v : MatchValue = @json.from_json(sub, path=path.add_key("match"))
    return Match(key~, value=v)
  }
  if m.get("range") is Some(sub) {
    let v : RangeSpec = @json.from_json(sub, path=path.add_key("range"))
    return Range(key~, spec=v)
  }
  if m.get("geo_bounding_box") is Some(sub) {
    let v : GeoBox = @json.from_json(sub, path=path.add_key("geo_bounding_box"))
    return GeoBoundingBox(key~, box=v)
  }
  if m.get("geo_radius") is Some(sub) {
    let v : GeoRadiusSpec = @json.from_json(
      sub,
      path=path.add_key("geo_radius"),
    )
    return GeoRadius(key~, spec=v)
  }
  if m.get("values_count") is Some(sub) {
    let v : ValuesCountSpec = @json.from_json(
      sub,
      path=path.add_key("values_count"),
    )
    return ValuesCount(key~, spec=v)
  }
  if m.get("is_empty") is Some(v) {
    match v {
      True => return IsEmpty(key~, value=true)
      False => return IsEmpty(key~, value=false)
      _ =>
        raise @json.JsonDecodeError((path, "Condition.is_empty: expected bool"))
    }
  }
  if m.get("is_null") is Some(v) {
    match v {
      True => return IsNull(key~, value=true)
      False => return IsNull(key~, value=false)
      _ =>
        raise @json.JsonDecodeError((path, "Condition.is_null: expected bool"))
    }
  }
  raise @json.JsonDecodeError((path, "Condition: no recognized clause"))
}

///|
/// Clause：Cond 内联 Condition；Group 内联嵌套 Filter。
pub impl ToJson for Clause with fn to_json(self) {
  match self {
    Cond(condition~) => @json.to_json(condition)
    Group(filter~) => @json.to_json(filter)
  }
}

///|
pub impl @json.FromJson for Clause with fn from_json(json, path) {
  guard json is Object(m) else {
    raise @json.JsonDecodeError((path, "Clause: expected object"))
  }
  // 判别规则：Condition 一定带 key / nested / has_id 这三个标记键之一
  // （注意 has_id 没有顶层 key，若只用 key 判别会把它误判成嵌套 Filter）。
  // 其余情形（含空对象）按嵌套 Filter 处理，空 Filter 语义为「匹配全部」。
  if m.get("key") is Some(_) ||
    m.get("nested") is Some(_) ||
    m.get("has_id") is Some(_) {
    let c : Condition = @json.from_json(json, path~)
    Cond(condition=c)
  } else {
    let f : Filter = @json.from_json(json, path~)
    Group(filter=f)
  }
}
