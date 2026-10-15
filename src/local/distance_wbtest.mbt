///| 四度量距离的数值与零向量约定（DEVELOPMENT.md 9.2 / Q6 / ADR-15）。
///
/// 一致性套件的 C15 已经比对过一组黄金值（10 节），这里是**白盒补充**：能直接调私有
/// 函数，因此可以覆盖套件不便构造的分支（负分量、零向量、相似度型度量的方向性）。

///|
/// 相对误差断言。容差与 C15 一致（1e-6），避免两处标准不同步。
fn check_near(actual : Double, expected : Double, what : String) -> Unit raise {
  let scale = if expected.abs() > 1.0 { expected.abs() } else { 1.0 }
  if (actual - expected).abs() / scale > 1.0e-6 {
    fail("\{what}：期望 \{expected}，实际 \{actual}")
  }
}

///|
test "Cosine：零向量任一侧时分数恒为 1.0（不产生 NaN）" {
  let zero : Array[Double] = [0.0, 0.0]
  let unit : Array[Double] = [1.0, 0.0]
  check_near(
    distance_score(@core.Cosine, zero, unit),
    1.0,
    "查询为零向量",
  )
  check_near(
    distance_score(@core.Cosine, unit, zero),
    1.0,
    "入库点为零向量",
  )
  check_near(
    distance_score(@core.Cosine, zero, zero),
    1.0,
    "两侧都是零向量",
  )
}

///|
test "Cosine：一般情形的 1 - cos 换算" {
  check_near(
    distance_score(@core.Cosine, [1.0, 0.0], [1.0, 0.0]),
    0.0,
    "同向",
  )
  check_near(
    distance_score(@core.Cosine, [1.0, 0.0], [0.0, 1.0]),
    1.0,
    "正交",
  )
  check_near(
    distance_score(@core.Cosine, [1.0, 0.0], [3.0, 4.0]),
    0.4,
    "cos=3/5",
  )
}

///|
test "Euclid 与 Manhattan：本身就是距离，不做变换" {
  check_near(
    distance_score(@core.Euclid, [1.0, 0.0], [0.0, 1.0]),
    2.0.sqrt(),
    "Euclid √2",
  )
  check_near(
    distance_score(@core.Euclid, [0.0, 0.0], [3.0, 4.0]),
    5.0,
    "Euclid 3-4-5",
  )
  check_near(
    distance_score(@core.Manhattan, [0.0, 0.0], [3.0, 4.0]),
    7.0,
    "Manhattan L1",
  )
}

///|
test "Dot：取负后仍满足「越小越近」" {
  // 与自身的内积为 2 ⇒ 分数 -2（最近）；与反向向量的内积为 -2 ⇒ 分数 +2（更远）
  check_near(distance_score(@core.Dot, [1.0, 1.0], [1.0, 1.0]), -2.0, "同向")
  check_near(distance_score(@core.Dot, [1.0, 1.0], [-1.0, -1.0]), 2.0, "反向")
  check_near(distance_score(@core.Dot, [1.0, 2.0], [3.0, 4.0]), -11.0, "3+8")
}
