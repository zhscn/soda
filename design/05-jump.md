# 跳转图与位置列表

## 导航的两个层次

导航同时维护语义图和每个 Window 的线性 walk：

```text
JumpNode {
  id,
  resource,
  document_id?,
  anchor?,
  line_column_fallback,
  excerpt,
  last_visit
}

JumpEdge { from, to, kind, timestamp }
JumpGraph { nodes, edges }              // per Workbench
Walk { entries, cursor }                // per Window
```

图记录 definition、reference、search、location-list、manual 等具有意图的边；
walk 记录用户实际经过的顺序，也可包含不值得建图节点的普通位置。`jump-back` 和
`jump-forward` 只沿 walk 移动，分支查询则读取 graph。

## 节点与写入

节点用 `(resource, 量化位置)` 合并。活 buffer 使用 `DocumentAnchor` 抵抗编辑漂移；
关闭 buffer 后保留 line/column fallback 与 excerpt。重新打开时先尝试 fallback，
再用 excerpt 校验或在邻域内重锚定。

自动语义边只在 [04-workbench.md](04-workbench.md) 的 display 入口写入。request
中的 origin 形成 from，落点形成 to，intent 映射为 edge kind。回放 jump history
时抑制再次写入。

Window 离开当前 buffer 时把当前位置结算进 walk。split 创建独立 walk，但两个
Window 共享 Workbench 的 graph，因此分叉阅读既有各自 back/forward，也能查询
另一分支。

在历史中间发起新跳转时，walk 追加一次 visit，不截断旧条目。graph 节点有软上限；
淘汰策略优先移除久未访问且不含 manual edge 的节点。

## LocationList

所有位置 producer 使用同一个惰性值：

```text
LocationItem {
  resource,
  range,
  coordinate_encoding: byte | utf16,
  excerpt,
  metadata,
  resolved: (BufferId, AnchorRange, stale)?
}

LocationList {
  id,
  source,
  items,
  version
}
```

grep、references、implementations、diagnostics、build errors 和外部语义索引只是
不同 producer。创建列表不打开文件；坐标保持 producer 的原始编码，直到资源被
解析到具体 snapshot 后再换算。

Scheme definition 与 references 由
[11-scheme-semantics.md](11-scheme-semantics.md) 的 DefinitionId 和 workspace
倒排索引产生。provider 返回 LocationList，不直接打开 Buffer 或选择 Window。

excerpt 同时用于显示和内容校验。item 在首次跳转或对应 buffer 打开时提升为
AnchorRange。未提升 item 的落点顺序为：

1. range 处内容与 excerpt 一致；
2. 在 range 邻域搜索唯一 excerpt；
3. 在整个 buffer 搜索唯一 excerpt；
4. 使用 fallback range 并标记 stale。

一个 Workbench 持有 location-list stack 与 current list。发布新结果只更新明确的
current 引用，不注册全局 next-error callback。列表可由 picker 消费，也可物化为
只读工具 buffer；两种形式共享 item identity 与当前索引。

## Excerpt 组合视图

组合视图把多个底层 buffer 的 anchor range 投影为一个连续 view：

```text
Excerpt {
  buffer,
  context: AnchorRange,
  primary: AnchorRange
}

ComposedView {
  excerpts,
  projection_segments,
  selection,
  viewport
}
```

相邻或重叠 excerpt 可以合并。snapshot 生成投影文本与“投影区间到源 buffer
区间”的映射；编辑必须完全落在可编辑 segment 内，再映射为底层 transaction。
普通 location list 只在用户进入可编辑组合视图时加载相关 buffer。

## 跨 Buffer 事务

workspace edit 是一组带源 revision 的 per-buffer edit：

1. 解析 resource 并验证每个 revision、range 与写权限；
2. 每个 buffer 建立 pending transaction；
3. 全部成员准备成功后提交；
4. 记录每个 undo-tree 边为一个 transaction group。

group undo 不改变各 Document 的 undo 数据结构，只协调它们跳到成组边的另一端。
某成员已在分支上继续编辑时，policy 可以跳过并报告冲突，或显式选择跨分支跳转。
LSP rename、code action 和可编辑组合视图使用同一机制。

## 设计依据

线性 jump list 对逐键 back/forward 最自然，图则能保留“从同一点进入多个分支”的
语义；两者不应互相替代。LocationList 把 producer 与呈现解耦，并以 resource、
原生坐标和 excerpt 延迟加载。组合视图与跨 buffer 事务是在同一数据模型上增加
编辑能力，不要求 grep、diagnostic 或 LSP 各自发明结果 buffer。
