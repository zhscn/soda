# 跳转图与位置列表

## 实现状态

| 能力 | 状态 |
|---|---|
| `EditorLocation`、per-View back/forward walk | 已实现 |
| source/target `LocationItem` jump history entry | 已实现 |
| anchor-backed bookmark 与列表 Buffer | 已实现 |
| 文件 Buffer 的 save-place 恢复与持久化 | 已实现 |
| `LocationItem`、`LocationList` 与 next/previous navigation | 已实现 |
| Scheme definition/reference/diagnostic producer | 已实现 |
| navigation origin 与 LanguageAttachment provenance | 已实现 |
| Workbench 级语义 `JumpGraph` | 未实现 |
| 可编辑 excerpt 组合视图 | 未实现 |
| 通用跨 Buffer 原子事务与 group undo | 未实现 |

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

command loop 的线性导航使用 `EditorLocation` 作为 live location。该值保存
buffer/resource、创建时 revision、DocumentAnchor 和 byte offset fallback。
`editor-jump-to-location!` 接管 target 的生命周期；每个 View 持有有界 walk，
View 关闭时释放 walk 内的 anchor。Buffer 从 Editor 移除前，所有 walk 先把对应
location detach 为 fallback，随后才关闭 Document。

walk 的相邻 live location 同时形成 `JumpHistoryEntry`。entry 保存 jump kind 以及
source/target `LocationItem`，用于保留发起时的 resource、revision、range 和 metadata；
live `EditorLocation` 继续负责编辑后的 anchor 跟踪。definition、xref、diagnostic、
search、goto-line 和显式 API jump 都写入该入口。back/forward 激活位置前先验证目标
Buffer 和 anchor；已移除 Buffer 的 detached entry 会被跳过。

bookmark catalog 由 Editor 持有。每个 bookmark 保存名称、resource、source revision、
活 Buffer anchor、行列 fallback 和可选 annotation。覆盖、重命名和删除会结算旧 anchor；
Buffer 移除时 bookmark 保留 resource 与 fallback，重新打开资源后按夹取后的行列恢复。
bookmark jump 写入普通 jump history，bookmark list 则物化为只读工具 Buffer。

save-place catalog 同样由 Editor 持有，以规范文件路径为 key，保存 point、逻辑
viewport、visual-row/column viewport 偏移和可选 mark。View 离开文件 Buffer 时更新
entry，重新显示该文件时恢复；超过当前文档范围的 point、mark 和首行会夹取到有效
边界。显式文件跳转提供的 source position 在恢复后应用，因此仍拥有最终落点控制权。

TUI 从 `$SODA_SAVE_PLACE_FILE`，或 `$XDG_STATE_HOME/soda/places.ss`，或
`$HOME/.local/state/soda/places.ss` 读取 catalog。文件是带 schema 名称和版本号的
Scheme datum，只包含可序列化的位置字段；损坏或不支持的文件按空 catalog 处理。
退出时先生成不可变 bytevector，再通过 runtime 的临时文件、fsync 和 rename 工作流
原子替换状态文件。空的 `SODA_SAVE_PLACE_FILE` 关闭磁盘持久化。

显式 jump 在 walk 尾部追加 target。用户从历史中间发起新 jump 时，walk 先追加
当前位置的 revisit，再追加新 target，因此 back 能回到分叉点，继续 back 仍可
经过原来的访问序列。back/forward 在离开当前 entry 前用实时 caret 替换它。

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
  language_context?,
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

Editor 保存一个 current LocationList 及其当前 index。provider 发布列表后可以跳到
首项；`xref.next-location` 和 `xref.previous-location` 按 prefix count 在列表内
双向回绕，并通过普通 navigation jump 写入当前 View 的 walk。已解析 LocationItem
带 Buffer identity、resource、source revision、byte range、excerpt 和 provider
metadata；实际跳转前必须再次验证 Buffer revision。尚未打开的 LocationItem 使用
resource、revision 与 byte range，跳转时发出异步文件读取请求。Buffer 移除时，
引用该 Buffer 的 current list 一并失效，纯 resource item 保持有效。provider
通过 editor 公共 API 发布列表；列表游标也是公共操作，因此 grep、diagnostics 和
build provider 可以复用同一导航命令。

grep、references、implementations、diagnostics、build errors 和外部语义索引只是
不同 producer。创建列表不打开文件；坐标保持 producer 的原始编码，直到资源被
解析到具体 snapshot 后再换算。

依赖语言上下文的 producer 把发起 View 的 LanguageAttachment identity 写入 item 的
`language_context`。异步打开目标资源时，该值随 request 冻结；display 完成后由目标
View 继承对应 attachment。落点路径不重新决定 Project 或 LanguageSession。同一
resource 从不同 session 得到的 item 因而可以打开同一 Buffer，并在不同 View 中保留
各自的 completion、hover、diagnostic 和后续 xref 上下文。具体 attachment 生命周期
由 [09-language-modes.md](09-language-modes.md) 定义。

Scheme definition 与 references 由
[11-scheme-semantics.md](11-scheme-semantics.md) 的 DefinitionId 和 environment
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
