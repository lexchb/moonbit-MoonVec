///|
/// 距离度量。与 Qdrant 的 distance 字段一一对应。
///
/// 必须是 `pub(all)`：裸的 `pub enum` 是 readonly 的，外部包无法构造它的变体。
/// 本库所有面向用户的枚举（Distance / PointId / MatchValue / Condition / Clause /
/// PayloadSchema / UpsertResult）都遵循这条规则。
///
/// Qdrant 的线上表示是裸字符串（"Cosine" / "Euclid" / "Dot" / "Manhattan"），
/// 因此本类型的 JSON 编解码手写（见 json_codec.mbt）。
pub(all) enum Distance {
  Cosine
  Euclid
  Dot
  Manhattan
} derive(Eq)

///|
/// 本库内部约定：所有度量统一为「分数越小越近」。
/// Dot 在实现侧需要取负，详见 DEVELOPMENT.md 9.2。
pub fn Distance::is_similarity(self : Distance) -> Bool {
  match self {
    Cosine | Dot => true
    Euclid | Manhattan => false
  }
}
