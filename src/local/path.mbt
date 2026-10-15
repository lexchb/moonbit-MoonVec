///| payload 路径解析与取值。
///
/// 语义边界在 DEVELOPMENT.md 9.6 定稿：只支持点号嵌套（`a.b.c`）与 `[]` 一层展开
/// （`a.b[].c`）；空段、显式下标、通配符一律抛 `Unsupported`。
///
/// **绝不静默判「不匹配」**：静默的语义错误会让用户拿到一个看似正常、实则少了一半
/// 结果集的东西，比直接报错难查得多（ADR-6）。

///|
/// 路径中的一段：字段名 + 「取到值后是否展开一层数组」。
/// 仅供本包使用，故不写 `pub`。
priv struct PathSeg {
  name : String
  expand : Bool
}

///|
fn unsupported_path(path : String) -> @core.VectorStoreError {
  @core.VectorStoreError::Unsupported(
    feature="payload path `\{path}`：仅支持点号嵌套与 `[]` 展开",
  )
}

///|
/// 把路径字符串解析为段列表；遇到不支持的形式抛 `Unsupported`。
fn parse_path(path : String) -> Array[PathSeg] raise @core.VectorStoreError {
  let segs : Array[PathSeg] = []
  for raw in path.split(".") {
    let name = match raw.strip_suffix("[]") {
      Some(base) => base.to_owned()
      None => raw.to_owned()
    }
    // 空段（`a..b`、前后点号）与「段内仍有 `[`」（`a[0]` / `a[*]` / `a[][]`）都不支持
    if name.length() == 0 {
      raise unsupported_path(path)
    }
    if name.find("[") is Some(_) {
      raise unsupported_path(path)
    }
    segs.push(PathSeg::{ name, expand: raw.has_suffix("[]"), })
  }
  segs
}

///|
/// 按路径从 payload 取出「候选值」。
///
/// 缺失 key 或类型不符**不是错误**：只是该分支无候选值，条件自然不成立（9.6）。
/// 只有不支持的路径形式才抛错，且那一层已在 `parse_path` 拦掉了。
fn resolve_path(payload : @core.Payload, segs : Array[PathSeg]) -> Array[Json] {
  let mut current : Array[Json] = [Json::object(payload)]
  for seg in segs {
    let mut next : Array[Json] = []
    for value in current {
      if value is Object(fields) {
        if fields.get(seg.name) is Some(child) {
          next.push(child)
        }
      }
    }
    if seg.expand {
      let expanded : Array[Json] = []
      for value in next {
        if value is Array(items) {
          for item in items {
            expanded.push(item)
          }
        }
      }
      next = expanded
    }
    current = next
  }
  current
}

///|
/// 条件求值用的「标量候选」：数组展开一层的元素，标量取自身。
///
/// 这一层隐式展开是**刻意**的：Qdrant 的 `match` / `range` / geo 等条件对数组型
/// payload 自动按「任一元素满足」判定，与调用方是否写 `[]` 无关（9.6）。
fn scalar_values(value : Json) -> Array[Json] {
  if value is Array(items) {
    items
  } else {
    [value]
  }
}

///|
/// 把多组候选值各自展开一层后合并，供「任一候选满足」类条件使用。
fn flat_scalars(candidates : Array[Json]) -> Array[Json] {
  let out : Array[Json] = []
  for candidate in candidates {
    for scalar in scalar_values(candidate) {
      out.push(scalar)
    }
  }
  out
}

///|
/// 解析 `{lat, lon}` 形式的 payload 地理点。
fn geo_point_of(value : Json) -> (Double, Double)? {
  if value is Object(fields) {
    match (fields.get("lat"), fields.get("lon")) {
      (Some(Number(lat, ..)), Some(Number(lon, ..))) => Some((lat, lon))
      _ => None
    }
  } else {
    None
  }
}
