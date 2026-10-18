///| REST 路径构造（DEVELOPMENT.md 8.1 端点映射表）。

///|
/// 集合资源路径：`/collections/{c}`。
fn collection_path(name : String) -> String {
  "/collections/\{name}"
}

///|
/// payload 索引路径：`/collections/{c}/index`。
fn payload_index_path(collection : String) -> String {
  "/collections/\{collection}/index"
}

///|
/// 点操作路径：`/collections/{c}/points`。
fn points_path(collection : String) -> String {
  "/collections/\{collection}/points"
}

///|
/// 删除路径：`/collections/{c}/points/delete?wait=..`。
fn delete_points_path(collection : String, wait : Bool) -> String {
  "/collections/\{collection}/points/delete?wait=\{wait}"
}

///|
/// 检索路径：`/collections/{c}/points/query`。
fn query_path(collection : String) -> String {
  "/collections/\{collection}/points/query"
}

///|
/// 分页路径：`/collections/{c}/points/scroll`。
fn scroll_path(collection : String) -> String {
  "/collections/\{collection}/points/scroll"
}
