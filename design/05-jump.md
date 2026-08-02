# 跳转图与位置列表

## 实现状态

| 能力 | 状态 |
|---|---|
| `EditorLocation`、per-View back/forward walk | 已实现 |
| source/target `LocationItem` jump history entry | 已实现 |
| anchor-backed bookmark 与列表 Buffer | 已实现 |
| 文件 Buffer 的 save-place 恢复与持久化 | 已实现 |
| `LocationItem`、`LocationList` producer model | 已实现 |
| 基于文本属性的 Result Buffer 与 next/previous/group navigation | 已实现 |
| 隐藏 Result Buffer 的 Buffer-local navigation point | 已实现 |
| Result Buffer 的可发现 item action | 已实现 |
| Result Buffer 的 producer refresh callback | 已实现 |
| Scheme definition/reference/diagnostic producer | 已实现 |
| navigation origin 与 LanguageAttachment provenance | 已实现 |
| Workbench 级语义 `JumpGraph` 与持久化 | 已实现 |
| WorkspaceEdit 可编辑投影视图 | 已实现 |
| 任意 Result Buffer 的可编辑 projection capability | 已实现 |
| Project search 的 wgrep 式匹配编辑 | 已实现 |
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
  presentation?,
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

LocationList 是 producer 与 presentation 之间的惰性数据模型。Workbench 可以保存
current LocationList 供 session 恢复和语义查询使用；交互选择和全局位置导航由物化后的
Result Buffer 持有。已解析 LocationItem
带 Buffer identity、resource、source revision、byte range、source excerpt、可选
presentation 和 provider metadata；实际跳转前必须再次验证 Buffer revision。尚未打开的 LocationItem 使用
resource、revision 与 byte range，跳转时发出异步文件读取请求。Buffer 移除时，
引用该 Buffer 的 current list 一并失效，纯 resource item 保持有效。provider
通过 editor 公共 API 发布列表。

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

excerpt 只保存源 range 的原始文本，用于内容校验和重锚定。presentation 是 Result
Buffer 可选的领域显示文本，例如诊断消息；缺省时结果行显示当前源文本。两者分离后，
诊断、符号和搜索 producer 可以改变列表的信息密度，而不会破坏 stale location
恢复。item 在首次跳转或对应 buffer 打开时提升为 AnchorRange。未提升 item 的落点顺序为：

1. range 处内容与 excerpt 一致；
2. 在 range 邻域搜索唯一 excerpt；
3. 在整个 buffer 搜索唯一 excerpt；
4. 使用 fallback range 并标记 stale。

## Result Buffer

xref、project search、diagnostics、compilation 和 Git 等 producer 把结果物化为普通
文本 Buffer。公共属性构成 presentation 协议：

```text
result-item   领域 payload
result-index  Buffer 内稳定的导航次序
result-group  文件、诊断来源或其他逻辑分组
result-target 结果行中对应源 range 的精确区间
face          普通文本装饰
```

`result-list-mode` 提供只读策略和基础 keymap。领域 mode 继承该 mode，并通过
`result-buffer-interface` 提供 item activation 和 quit 行为。`n`/`p` 移动 Result
Buffer 的真实 point，再激活 point 下的 item；`N`/`P` 按 `result-group` 移动到相邻组
的首项。RET 选择源位置，TAB 选择并关闭结果窗口，`C-o` 只预览。`m` 切换条目标记，
`u` 取消当前标记，`U` 清除全部标记；支持批处理的领域 action 消费已标记条目。

`xref-results-mode` 继承 location result 行为，并保存产生列表的 source View 与
refresh callback。`g` 从该 View 的语言上下文重新执行查询。preview 更新专用 source
View，但保持 Result Buffer 的 Window 为 active；该规则同样适用于需要异步打开文件的
LocationItem。select 才携带 display intent 并把焦点交给 source View。

领域 mode 可以向 Buffer 注册命名 `result-action`。action 包含显示名称、针对 point
下 `result-item` 的适用性判断和执行过程。键位仍由 mode keymap 决定；which-key、菜单
或其他 TUI 组件可以枚举 point 下的可用 action，而无需识别领域 payload。Git status
的 stage、unstage 和 diff 使用该协议。action applicability 消费 porcelain XY 状态：
worktree change 提供 stage，index change 提供 unstage，tracked change 提供 diff；producer
运行期间领域 action 暂停，只保留面板级取消/关闭能力。

可重新生成内容的 Result Buffer 注册 buffer-local refresh callback。`g` 调用当前
Buffer 的 producer，而不判断它来自搜索、版本控制或语义服务。producer 负责替换
session、取消仍在运行的旧任务并重新建立属性；Project search 和 Git status 使用该
协议。带 cancellation command 的运行中 producer 还提供面板级 `stop` action；它停止
任务但保留已经生成的文本和 LocationItem。`close` 仍可取消并关闭面板，已经显式停止
的任务在关闭时不会重复提交 cancellation。`C-c C-k` 是所有 Result Buffer 的停止入口。
refresh action 根据 producer state 显示为 Refresh、Restart、Retry 或 Run again；命令
身份保持为 `buffer-item.refresh`，领域 mode 不需要复制状态分支。每次进入 `running`
状态建立新的 producer generation，并重置该 Buffer 的停止握手，使停止后的重试仍可
再次取消。
LSP xref producer 按 source View 跟踪 pending request。刷新先发送
`$/cancelRequest` 终止同一来源的旧请求，再建立新 generation；迟到响应不改变当前
Result Buffer。停止命令只结束当前请求，保留已经呈现的 reference 条目。

Result Buffer 在不可见时仍保存当前 item。全局 next/previous locus 使用当前 Workbench
中最近实际导航的 Result Buffer，并跳过已经关闭的 Buffer；它不依赖 Result Buffer
当前是否显示在某个 Window。多个结果 Buffer 按最近使用次序参与选择。源位置访问由公共
location visitor 完成，统一处理 live Buffer revision、异步文件打开、UTF-16 fallback
和 LanguageAttachment 传播。

Result Buffer 的会话身份由基础 resource 名称和 source View 所属 Workbench 共同确定。
同一 Workbench 内重新执行 producer 会刷新原有 Buffer；不同 Workbench 可以同时保留
各自的 xref、搜索、诊断、编译和 Git 结果。Buffer registry 需要唯一名称时为后续实例
分配 `<N>` 后缀，领域 producer 仍使用不带后缀的基础 resource 识别自己的会话。异步
producer 的 active session 也按 Workbench 隔离，因此一个 Workbench 中的刷新只取消
该 Workbench 的旧任务。

LocationList 的 index 与 Result Buffer 当前 item 同步，用于语义 API 和 session 数据。
从任意 Result Buffer 激活或预览位置时，该列表同时成为所在 Workbench 的 current
LocationList；在多个 xref、搜索或诊断面板之间往返不会留下另一个 producer 的列表。
LocationList 不承担 point、Window 或 preview 生命周期。

Editable projection 使用 DocumentAnchor 标记 Result Buffer 中允许修改的区间，并把每个
区间关联到领域 source。编辑 guard 只允许修改完整落在 projection 内的文本。接受操作
读取 projection 的当前内容，由领域 mode 生成原子 workspace edits；放弃操作恢复或重新
生成 producer 结果。编辑 session 同时把 projection anchors 发布为 Buffer 的
`search-ranges` capability，因此普通 query replace 可在所有 projected targets 间导航和
替换，而不会匹配标题、路径、上下文 excerpt 或跨越两个 target。Project search 把
`rg --json` 的绝对 range 和行内 match range
呈现为 `result-target`，进入编辑模式前异步打开全部目标文件，并校验该属性覆盖的文本仍
与源 Buffer 一致。接受后源 Buffer 保持 modified 状态，结果 Buffer 关闭以避免继续使用
旧位置。领域编辑逻辑只消费标准 target property，不依赖结果行的前缀或布局。

Workspace edit preview 将每项协议 edit 映射为一个可编辑 projection，并默认标记
全部条目。用户可以在预览中取消任意条目；Apply 和 Edit 只消费仍被标记的 projection，
因此 rename、code action 等 producer 无需各自实现变更筛选。清空全部标记时应用与
编辑动作不可用，重新标记条目即可恢复。

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
