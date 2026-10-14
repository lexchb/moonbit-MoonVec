///| 显式声明「哪些 trait 方法可以按方法语法调用」。
///
/// 背景：本工具链已弃用「trait 实现的方法被隐式提升为普通方法」（告警 0079）。
/// 不写这些声明，调用方只能写 `Trait::method(x, ..)` 而不能写 `x.method(..)`，
/// 因此它们是**公共 API 易用性的一部分**，需要随 `.mbti` 一起评审
/// （DEVELOPMENT.md 6.4 / ADR-10）。
///
/// 每个「类型 + trait」组合写一行；用 `..` 表示该 trait 的全部方法。

///|
/// 内建 Eq
pub extend Distance with Eq::{not_equal, equal}

///|
pub extend VectorConfig with Eq::{not_equal, equal}

///|
pub extend PayloadSchema with Eq::{not_equal, equal}

///|
pub extend PointId with Eq::{not_equal, equal}

///|
pub extend ScoredPoint with Eq::{not_equal, equal}

///|
pub extend StoredPoint with Eq::{not_equal, equal}

///|
pub extend Point with Eq::{not_equal, equal}

///|
pub extend UpsertResult with Eq::{not_equal, equal}

///|
pub extend SearchRequest with Eq::{not_equal, equal}

///|
pub extend ScrollRequest with Eq::{not_equal, equal}

///|
pub extend ScrollPage with Eq::{not_equal, equal}

///|
pub extend Filter with Eq::{not_equal, equal}

///|
pub extend Clause with Eq::{not_equal, equal}

///|
pub extend Condition with Eq::{not_equal, equal}

///|
pub extend MatchValue with Eq::{not_equal, equal}

///|
pub extend RangeSpec with Eq::{not_equal, equal}

///|
pub extend GeoPoint with Eq::{not_equal, equal}

///|
pub extend GeoBox with Eq::{not_equal, equal}

///|
pub extend GeoRadiusSpec with Eq::{not_equal, equal}

///|
pub extend ValuesCountSpec with Eq::{not_equal, equal}

///|
/// 内建 Hash
pub extend PointId with Hash::{hash, hash_combine}

///|
/// 内建 Show
pub extend VectorStoreError with Show::{to_string, output}

///|
/// 内建 ToJson
pub extend PointId with ToJson::{to_json}

///|
pub extend Distance with ToJson::{to_json}

///|
pub extend PayloadSchema with ToJson::{to_json}

///|
pub extend MatchValue with ToJson::{to_json}

///|
pub extend Condition with ToJson::{to_json}

///|
pub extend Clause with ToJson::{to_json}

///|
pub extend Filter with ToJson::{to_json}

///|
pub extend RangeSpec with ToJson::{to_json}

///|
pub extend GeoPoint with ToJson::{to_json}

///|
pub extend GeoBox with ToJson::{to_json}

///|
pub extend GeoRadiusSpec with ToJson::{to_json}

///|
pub extend ValuesCountSpec with ToJson::{to_json}

///|
/// moonbitlang/core/json 的 FromJson
pub extend PointId with @json.FromJson::{from_json}

///|
pub extend Distance with @json.FromJson::{from_json}

///|
pub extend PayloadSchema with @json.FromJson::{from_json}

///|
pub extend MatchValue with @json.FromJson::{from_json}

///|
pub extend Condition with @json.FromJson::{from_json}

///|
pub extend Clause with @json.FromJson::{from_json}

///|
pub extend Filter with @json.FromJson::{from_json}

///|
pub extend RangeSpec with @json.FromJson::{from_json}

///|
pub extend GeoPoint with @json.FromJson::{from_json}

///|
pub extend GeoBox with @json.FromJson::{from_json}

///|
pub extend GeoRadiusSpec with @json.FromJson::{from_json}

///|
pub extend ValuesCountSpec with @json.FromJson::{from_json}
