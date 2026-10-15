///| 四种距离度量的实现。本库统一约定「分数越小越近」，换算关系见 DEVELOPMENT.md 9.2。

///|
/// 内积。四个度量里三个都要用，故单列。
fn dot_product(a : Array[Double], b : Array[Double]) -> Double {
  let mut acc = 0.0
  for i = 0; i < a.length(); i = i + 1 {
    acc = acc + a[i] * b[i]
  }
  acc
}

///|
/// L2 范数（向量模长）。
fn l2_norm(a : Array[Double]) -> Double {
  dot_product(a, a).sqrt()
}

///|
/// 计算一个「查询向量 × 已存点向量」的分数。
///
/// 调用方须保证两个向量等长：维度校验属于集合元数据，在 store 层完成（9.3），
/// 放在这里会变成「每个点都校验一次」的无谓开销。
fn distance_score(
  metric : @core.Distance,
  query : Array[Double],
  stored : Array[Double],
) -> Double {
  match metric {
    @core.Cosine => {
      let query_norm = l2_norm(query)
      let stored_norm = l2_norm(stored)
      // Q6 定稿（ADR-15）：任一侧为零向量时把 cos 记作 0 ⇒ score 恒为 1.0。
      // 不做这个分支就会得到 NaN，而 NaN 会让排序与 score_threshold 比较**全部失效**
      // （且失效是静默的：结果看起来只是「顺序乱了」）。
      if query_norm == 0.0 || stored_norm == 0.0 {
        1.0
      } else {
        1.0 - dot_product(query, stored) / (query_norm * stored_norm)
      }
    }
    @core.Euclid => {
      let mut acc = 0.0
      for i = 0; i < query.length(); i = i + 1 {
        let diff = query[i] - stored[i]
        acc = acc + diff * diff
      }
      acc.sqrt()
    }
    // 相似度型度量必须取反，才能与「越小越近」的内部约定一致（9.2）
    @core.Dot => -dot_product(query, stored)
    @core.Manhattan => {
      let mut acc = 0.0
      for i = 0; i < query.length(); i = i + 1 {
        acc = acc + (query[i] - stored[i]).abs()
      }
      acc
    }
  }
}
