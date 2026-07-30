# Minibuffer 与读取协议

## 定位

minibuffer 是 command loop 管理的临时输入会话。它复用 Buffer、View、keymap 和
TUI component，但不进入 WindowLayout、workbench MRU 或持久化状态。普通文本读取
与候选补全使用同一会话生命周期；completion provider 和候选展示保持独立。

```text
PromptRequest
      │
      ▼
PromptSession ──────── transient Buffer / View
      │
      ├── plain read
      └── CompletionSession ── provider / matcher / presenter
      │
      ▼
prompt.reply effect
      │
      ▼
internal command message
      │
      └── command.invoke effect ──> interactive command message
```

minibuffer 不启动递归 command loop。发起命令创建 session 后立即返回；输入、
渲染和异步事件继续由主循环推进。接受或取消产生 reply effect，effect handler 将
结果转换成后续 internal command message。continuation 需要执行用户选择的命令时，
产生 `command.invoke` effect；对应 handler 把它转换成 interactive command
message，使键绑定、直接 command message 与 `M-x` 共享错误处理和 command class
语义。

## 请求、会话与结果

`PromptRequest` 声明一次读取：

```text
PromptRequest {
  prompt,
  initial,
  history-id?,
  default?,
  accept-policy,
  validator?,
  completion-source?,
  accept-command,
  abort-command?,
  data?,
  change-command?
}
```

- `prompt` 是 chrome，由 TUI component 渲染，不属于输入 Document。
- `initial` 是输入 Buffer 的初始正文。
- `default` 只在接受空输入时成为结果，不预先插入 Document。
- `history-id` 选择 Editor 持有的 history collection。
- `accept-policy` 为 `free` 或 `must-match`；`must-match` 使用 validator 检查最终值。
- `completion-source` 为读取附加结构化 choice completion。
- `data` 是 responder 的不透明 continuation data，在接受和取消时原样进入结果。
- `change-command` 在 transient input Buffer revision 改变后产生
  `command.invoke` effect；payload 是 prompt session id。同一个 revision 内的
  caret motion、completion selection 和 responder command 不触发 change。
- responder 使用 command symbol，不保存调用栈或暂停中的递归编辑。

`PromptSession` 保存 session id、request、transient buffer/view id、origin view id、
状态和 history 游标。session id 单调递增，供后续 completion generation 和异步
结果校验使用。

`PromptResult` 包含 session id、`accepted` 或 `aborted` 状态、最终值、选中的
completion candidate、origin view id 和 request data。接受结果先关闭 session
并恢复 origin view，再投递给 responder。取消值和 candidate 为 `#f`；没有 abort
responder 时只完成清理。

## Buffer、View 与焦点

每个 session 创建一个 `track-modified? = #f` 的 transient Buffer 和对应 View。
View 使用 `minibuffer` InputState，文本输入和移动、删除命令继续走普通 keymap 与
Document transaction。session 关闭时 View、anchor、Buffer 和 Document 一起释放。

活动 prompt View 独占输入焦点。正文区域使用最外层 session 的 origin view 渲染；
只有栈顶 session 接收输入。嵌套读取通过 session stack 表示：

- 新 session 的 origin 是当前 prompt View；
- 接受或取消栈顶 session 后恢复该 origin；
- 最外层 session 的 origin 始终是正文显示 View；
- 嵌套不会创建第二个事件循环。

TUI root 在 session 活动时按正文、modeline、minibuffer 和可选 completion list
布局。候选列表从 minibuffer 的下一行向下展开；两者占用底部保留行并参与 reflow。
prompt 与 transient input 分别使用 `minibuffer-prompt` 和 `minibuffer-input`
face。输入 cell 保留 transient Document position 和 component source，因此光标与
`describe-char` 仍使用统一的 frame 数据。带 completion 的 prompt 为位置指示器保留
固定列宽；初次打开和 terminal resize 使用同一个 input viewport 计算契约。

## Keymap 与 history

`prompt.input` transient keymap 定义：

- `RET`、`C-j`：接受显式选中的候选；没有选择时接受原始输入；
- `M-RET`、`M-j`：忽略候选并接受原始输入；
- `ESC`、`C-g`：取消；
- `Up`、`C-p`：选择上一个候选；
- `Down`、`C-n`：选择下一个候选；
- `M-p`、`M-Up`：上一条 history；
- `M-n`、`M-Down`：下一条 history；
- `TAB`：插入候选并保持 minibuffer 活动；
- `S-TAB`：选择上一个候选。

history 由 Editor 按 symbol 标识并保存，条目以最新值优先。首次向后浏览前保存当前
draft；向前越过最新条目时恢复 draft。只有通过验证的非空接受值进入 history，
连续重复值只保留一份。default、initial 和 history 是彼此独立的输入来源。

## Completion 接口

带补全的读取在 `PromptSession` 上附加 `CompletionSession`，不改变 prompt 的接受、
取消和 reply 契约。completion 管线使用两类目标：

```text
CompletionTarget =
    DocumentTarget(document-id, revision, range)
  | PromptTarget(prompt-session-id, field-start, point, replacement-end)

PromptCompletionContext {
  input,
  point,
  source-metadata
}
```

两类目标共享 `CompletionItem`、generation、候选身份、过滤排序、选择状态和 TUI
presenter。language provider 继续产生 revision-aware edit；命令、Buffer、路径和
Scheme binding 等离散集合通过 choice source 归一化成相同的候选条目。

异步 prompt provider 从类型化的 `PromptCompletionContext` 读取完整 input、字符
位置和 source metadata。context 使用结构相等性参与 generation identity；query
和 context 都未改变时，重复 refresh 不会取消或重启 provider。

choice source 显式提供 metadata、boundaries、candidates、validate 和 cancel 操作。
候选分别保存 insert text、label、annotation、group、source 和 payload，显示文本
不承担返回值或对象身份。

`boundaries(input, point)` 使用字符索引返回当前 field 的 `[start, end)`。completion
query 是 `[start, point)`；应用候选时原子替换 `[start, end)`，因此光标位于 field
中间时不会留下旧后缀。路径、复合命令和其他分段 reader 可以在插入候选后返回一个
新的空 field，例如 `root/usr/|`。`RET` 遇到这种边界会提交当前 field 并继续读取，
直到候选没有引入后续 field 才结束 prompt。`TAB` 始终只提交当前 field。

Prompt completion 使用完整 input 和 point 作为 source context identity。query
不变但 field 外文本发生变化时仍会推进 generation 并重新产生候选。例如从路径
末尾删除一个目录分量后，新目录的空 query 不会复用旧目录的空 query 结果。

choice source metadata 为匹配和选择声明策略：

```text
category:    command | file | buffer | ...
styles:      (prefix substring flex fzf)
ignore-case: boolean
preselect:   boolean
```

styles 按顺序尝试，每个匹配结果包含 score、匹配区间和 exact 标记。presenter 使用
匹配区间高亮 label，并对可见候选统一对齐 annotation。默认不预选 candidate；键入
会清除 candidate selection，避免 `RET` 意外接受列表首项。需要传统首项选择行为的
source 可以设置 `preselect`。文件 reader 采用首项预选，因此目录结果出现时显示
`1/n`；从第一项向前移动会选择原始文件名输入并显示 `*/n`，允许提交任意路径。

`CompletionSession` 持有显式的选择策略：

```text
SelectionPolicy {
  domain:  candidates | input-and-candidates,
  initial: none | input | first,
  cycle?: boolean
}
```

`free` reader 使用 `input-and-candidates`，其中空的 selected index 表示 input；
`must-match` reader 使用 `candidates`，空 index 表示尚未选择。minibuffer 默认不
循环：从 input 向后进入第一项，从第一项向前返回 input，最后一项向后保持不动。
只包含 candidates 的 reader 在第一项向前时保持第一项。Document completion 使用
可循环的 candidates 域，并默认选择第一项。

minibuffer 左侧使用 `position/total` 指示当前域位置。candidate 使用从 1 开始的
位置，`*` 表示可接受的原始 input，`!` 表示尚未选择 candidate 且原始 input 不是
导航项。input 成为当前项时叠加 `completion-selected` face；候选成为当前项时只
高亮对应候选行。`RET` 接受当前项，`M-RET` 始终接受 input。`TAB` 将当前候选写入
input 并刷新 field，刷新后的选择由新 field 的 reader 策略决定。

completion list 在终端空间允许时保留 `completion-window-max-rows` 行，不随当前
匹配数量改变布局高度；候选不足的行使用 completion background 填充。session 保存
候选 viewport 的起始位置。选择向下越过底边时 viewport 向下滚动，随后向上移动先在
当前 viewport 内移动高亮行，只有越过顶边时才向上滚动。

minibuffer 的命令、Buffer、主题和文件 source 使用 `fzf` 风格。matcher 按字符边界、
路径分隔符、camelCase 转换和连续匹配加权，并对间隔匹配扣分；同分候选依次按匹配
跨度、起点和候选长度排序。匹配保留原字符串中的字符位置，使大小写不敏感的搜索也
能准确生成非连续高亮区间。Document completion 的 source 独立声明匹配 styles，
语言 provider 可以继续使用 prefix 等面向标识符的策略。

completion component 始终显式表示 pending、无匹配、候选数量和当前选择位置。选择
按 `(provider, item-id)` 保持身份；refilter 或异步结果到达后，只要候选仍然存在，
选择不会因排序位置变化而漂移。

`M-x` 使用 command registry choice source 和 `extended-command` history 读取
command symbol。它使用大小写不敏感的 `fzf` 匹配，并保持无预选状态。发起
`M-x` 的 prefix argument 作为 request data 跨 prompt
生命周期保存，`prompt.execute-command` 把它放入 interactive command message，
因此最终命令收到与直接按键调用相同的 `CommandContext`。
