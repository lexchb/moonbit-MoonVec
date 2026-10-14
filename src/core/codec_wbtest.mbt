///|
/// M1 编解码测试（白盒）。
///
/// 断言方式：直接比较**线上 JSON 字符串**。这既能钉死 wire format，也规避了
/// 同时导入 core/json 时 `inspect` 的重载歧义（DEVELOPMENT.md 12.1）。
fn check(actual : String, expected : String) -> Unit raise {
  if actual != expected {
    fail("expected \{expected}\n     got \{actual}")
  }
}

///|
fn decode_filter(text : String) -> Filter raise {
  @json.from_json(@json.parse(text))
}

///|
fn decode_condition(text : String) -> Condition raise {
  @json.from_json(@json.parse(text))
}

///|
fn decode_point_id(text : String) -> PointId raise {
  @json.from_json(@json.parse(text))
}

///|
/// ---- Distance / PayloadSchema：裸字符串，手写编解码 ----
test "Distance 编解码" {
  check(@json.to_json(Distance::Cosine).stringify(), "\"Cosine\"")
  check(@json.to_json(Distance::Dot).stringify(), "\"Dot\"")
  check(@json.to_json(Distance::Manhattan).stringify(), "\"Manhattan\"")
  let d : Distance = @json.from_json(@json.parse("\"Euclid\""))
  check(@json.to_json(d).stringify(), "\"Euclid\"")
  let bad = try {
    let _ : Distance = @json.from_json(@json.parse("\"Hamming\""))
    "no error"
  } catch {
    _ => "error"
  }
  check(bad, "error")
}

///|
test "PayloadSchema 编解码（Boolean 的线上名是 bool）" {
  check(@json.to_json(PayloadSchema::Boolean).stringify(), "\"bool\"")
  check(@json.to_json(PayloadSchema::Keyword).stringify(), "\"keyword\"")
  let s : PayloadSchema = @json.from_json(@json.parse("\"geo\""))
  check(@json.to_json(s).stringify(), "\"geo\"")
}

///|
/// ---- PointId：裸数字 / 裸字符串，且大整数不能丢精度 ----
test "PointId 小整数序列化为裸数字" {
  check(@json.to_json(PointId::of_int(42UL)).stringify(), "42")
}

///|
test "PointId 大于 2^53 的整数不丢精度" {
  // 2^53 + 1 无法用 Double 精确表示，必须依赖 Json 的 repr 字段
  check(
    @json.to_json(PointId::of_int(9007199254740993UL)).stringify(),
    "9007199254740993",
  )
}

///|
test "PointId 支持 u64 满量程（Qdrant 的随机 ID 会超出 i64 上限）" {
  check(
    @json.to_json(PointId::of_int(18446744073709551615UL)).stringify(),
    "18446744073709551615",
  )
}

///|
test "PointId 解析满量程 u64 不丢精度" {
  let id = decode_point_id("18446744073709551615")
  check(@json.to_json(id).stringify(), "18446744073709551615")
}

///|
test "PointId UUID 形状与往返" {
  check(@json.to_json(PointId::of_uuid("550e8400")).stringify(), "\"550e8400\"")
  let id = decode_point_id("\"550e8400\"")
  check(@json.to_json(id).stringify(), "\"550e8400\"")
}

///|
test "PointId 拒绝负数" {
  let got = try {
    let _ = decode_point_id("-1")
    "no error"
  } catch {
    _ => "error"
  }
  check(got, "error")
}

///|
/// ---- MatchValue：四种内联形状 ----
test "MatchValue 四种形状" {
  check(
    @json.to_json(MatchValue::Value(Json::string("acme"))).stringify(),
    "{\"value\":\"acme\"}",
  )
  check(
    @json.to_json(MatchValue::Any([Json::string("a"), Json::string("b")])).stringify(),
    "{\"any\":[\"a\",\"b\"]}",
  )
  check(
    @json.to_json(MatchValue::Except([Json::string("x")])).stringify(),
    "{\"except\":[\"x\"]}",
  )
  check(
    @json.to_json(MatchValue::Text("hello")).stringify(),
    "{\"text\":\"hello\"}",
  )
}

///|
/// ---- RangeSpec：derive 省略 None 字段 ----
test "RangeSpec 省略值为 None 的边界" {
  check(
    @json.to_json(RangeSpec::new(gte=0.5, lt=0.9)).stringify(),
    "{\"gte\":0.5,\"lt\":0.9}",
  )
  check(@json.to_json(RangeSpec::new()).stringify(), "{}")
}

///|
test "RangeSpec 往返" {
  let src = RangeSpec::new(gte=0.5, lte=0.9)
  let back : RangeSpec = @json.from_json(@json.to_json(src))
  if back != src {
    fail("RangeSpec 往返不等")
  }
}

///|
/// ---- Condition：key 与子对象展平 ----
test "Condition.match 展平为 key + match" {
  check(
    @json.to_json(Condition::match_str("tenant_id", "acme")).stringify(),
    "{\"key\":\"tenant_id\",\"match\":{\"value\":\"acme\"}}",
  )
  check(
    @json.to_json(Condition::match_any("doc_type", ["draft", "trash"])).stringify(),
    "{\"key\":\"doc_type\",\"match\":{\"any\":[\"draft\",\"trash\"]}}",
  )
  check(
    @json.to_json(Condition::match_text("body", "rust")).stringify(),
    "{\"key\":\"body\",\"match\":{\"text\":\"rust\"}}",
  )
}

///|
test "Condition.range 展平为 key + range" {
  check(
    @json.to_json(Condition::range("score", gte=0.5, lt=0.9)).stringify(),
    "{\"key\":\"score\",\"range\":{\"gte\":0.5,\"lt\":0.9}}",
  )
}

///|
test "Condition 其余形状" {
  check(
    @json.to_json(
      Condition::GeoBoundingBox(
        key="loc",
        box=GeoBox::new(
          top_left=GeoPoint::new(lat=1.0, lon=2.0),
          bottom_right=GeoPoint::new(lat=3.0, lon=4.0),
        ),
      ),
    ).stringify(),
    "{\"key\":\"loc\",\"geo_bounding_box\":{\"top_left\":{\"lat\":1,\"lon\":2},\"bottom_right\":{\"lat\":3,\"lon\":4}}}",
  )
  check(
    @json.to_json(Condition::is_empty("tags", true)).stringify(),
    "{\"key\":\"tags\",\"is_empty\":true}",
  )
  check(
    @json.to_json(Condition::is_null("nick", false)).stringify(),
    "{\"key\":\"nick\",\"is_null\":false}",
  )
  check(
    @json.to_json(Condition::values_count("tags", gte=2)).stringify(),
    "{\"key\":\"tags\",\"values_count\":{\"gte\":2}}",
  )
}

///|
test "Condition.has_id 没有顶层 key" {
  check(
    @json.to_json(
      Condition::has_id([PointId::of_int(1UL), PointId::of_int(2UL)]),
    ).stringify(),
    "{\"has_id\":[1,2]}",
  )
}

///|
test "Condition.nested 的 key 在 nested 对象内部" {
  let inner = Filter::new(must=[
    Clause::from_condition(Condition::match_str("brand", "acme")),
  ])
  check(
    @json.to_json(Condition::nested("diet", inner)).stringify(),
    "{\"nested\":{\"key\":\"diet\",\"filter\":{\"must\":[{\"key\":\"brand\",\"match\":{\"value\":\"acme\"}}]}}}",
  )
}

///|
test "Condition 逐项往返（含特殊形状）" {
  let cases : Array[Condition] = [
    Condition::match_str("k", "v"),
    Condition::range("k", gt=1.0, lte=9.0),
    Condition::is_empty("k", true),
    Condition::has_id([PointId::of_int(7UL)]),
    Condition::nested("d", Filter::empty()),
    Condition::values_count("k", gt=1, lt=5),
  ]
  for c in cases {
    let back = decode_condition(@json.to_json(c).stringify())
    if back != c {
      fail("Condition 往返不等: \{@json.to_json(c).stringify()}")
    }
  }
}

///|
/// ---- Filter：三个子句、嵌套 Clause::Group、缺失键 ----
test "Filter 空对象" {
  check(@json.to_json(Filter::empty()).stringify(), "{}")
}

///|
test "Filter 三子句与嵌套 Group" {
  let f = Filter::new(
    must=[
      Clause::from_condition(Condition::match_str("tenant_id", "acme")),
      Clause::from_filter(
        Filter::new(must=[
          Clause::from_condition(Condition::range("score", gte=0.5)),
        ]),
      ),
    ],
    must_not=[
      Clause::from_condition(
        Condition::match_any("doc_type", ["draft", "trash"]),
      ),
    ],
  )
  check(
    @json.to_json(f).stringify(),
    "{\"must\":[{\"key\":\"tenant_id\",\"match\":{\"value\":\"acme\"}},{\"must\":[{\"key\":\"score\",\"range\":{\"gte\":0.5}}]}],\"must_not\":[{\"key\":\"doc_type\",\"match\":{\"any\":[\"draft\",\"trash\"]}}]}",
  )
}

///|
test "Filter 解码时缺失的子句应为 None（而非报错）" {
  let f = decode_filter("{\"must\":[{\"key\":\"k\",\"match\":{\"value\":1}}]}")
  if f.must is None || f.should is Some(_) || f.must_not is Some(_) {
    fail("缺失子句未按 None 处理")
  }
  check(
    @json.to_json(f).stringify(),
    "{\"must\":[{\"key\":\"k\",\"match\":{\"value\":1}}]}",
  )
}

///|
test "Filter 复杂往返（与字段顺序无关的比较）" {
  let src = Filter::new(
    must=[
      Clause::from_condition(Condition::match_str("tenant_id", "acme")),
      Clause::from_filter(
        Filter::new(should=[
          Clause::from_condition(Condition::range("score", gte=0.5, lt=0.9)),
          Clause::from_condition(Condition::is_null("deleted_at", false)),
        ]),
      ),
    ],
    should=[Clause::from_condition(Condition::has_id([PointId::of_int(1UL)]))],
    must_not=[
      Clause::from_condition(Condition::nested("diet", Filter::empty())),
    ],
  )
  let wire = @json.to_json(src).stringify()
  let back = decode_filter(wire)
  if back != src {
    fail(
      "Filter 往返不等\n  wire: \{wire}\n  back: \{@json.to_json(back).stringify()}",
    )
  }
}
