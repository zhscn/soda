# Minibuffer 与读取协议

## 能力边界

- request/session/continuation 协议在主 command loop 中非递归地运行。
- 每个 prompt 使用独立的 transient Buffer/View，并通过 identity 完成接受、
  取消与资源回收。
- completion controller 管理 candidate、selection、preview、restore 和 accept 事务。
- minibuffer adapter 使用普通 transient Buffer/View 显示固定高度的候选列表，
  并使用 interaction companion placement 跟随 prompt 布局。
- history collection、async completion source 和其他候选 presenter 通过 request、snapshot
  与 controller 边界扩展。

## 定位

minibuffer 是 command loop 管理的临时输入会话。它复用 Buffer、View、keymap 和
Surface interaction placement，但不进入 root WindowLayout、workbench MRU 或持久化状态。普通文本读取
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
  history-key?,
  default?,
  accept-policy,
  validator?,
  completion-source?,
  keymap?,
  accept-command,
  abort-command?,
  data?,
  change-command?
}
```

- `prompt` 是 chrome，由 TUI component 渲染，不属于输入 Document。
- `initial` 是输入 Buffer 的初始正文。prompt View 在首次 placement 前将 point 放在其
  末尾，使初始内容可以直接继续输入；空正文的 point 为 0。
- `default` 只在接受空输入时成为结果，不预先插入 Document。
- `history-key` 按输入用途选择 MinibufferService 持有的 history collection。共享键的
  request 共享已接受值；文件名和扩展命令等不同用途保持隔离。
- `accept-policy` 为 `free` 或 `must-match`；`must-match` 使用 validator 检查最终值。
- `completion-source` 为读取附加结构化 choice completion。
- `keymap` 为离散回答提供位于普通 prompt 编辑 keymap 之前的临时键绑定。绑定仍以
  command disposition 进入 command loop，由通用接受命令把当前按键转换为 responder 值。
- `data` 是 responder 的不透明 continuation data，在接受和取消时原样进入结果。
- `change-command` 在 transient input Buffer revision 改变后产生
  `command.invoke` effect；payload 是 prompt session id。同一个 revision 内的
  caret motion、completion selection 和 responder command 不触发 change。
- responder 使用 command symbol，不保存调用栈或暂停中的递归编辑。

`PromptSession` 保存 session id、request、transient buffer/view id、origin view id、
状态和 history 游标。session id 单调递增，供后续 completion generation 和异步
结果校验使用。

session 状态沿 `open → submitting → accepted` 或
`open → cancelling → cancelled` 单向迁移。命令错误也将尚未终止的 session 转换为
`cancelled`。批量取消按 session 栈从内向外执行，使每个内层 prompt 在其 origin View
仍有效时完成关闭和焦点恢复。

`minibuffer.accept` 与 `minibuffer.cancel` 是普通 command。minibuffer keymap 只绑定
这两个命令，frontend 按所有其他 command 相同的队列路径投递它们。`setup` 和 `exit`
hook 以 owner-scoped registration 安装，回调只接收 `PromptSnapshot`；hook 不能持有或
改写 transient Buffer、View 与 Surface。

`PromptResult` 包含 session id、`accepted` 或 `aborted` 状态、最终值、选中的
completion candidate、origin view id 和 request data。接受结果先关闭 session
并恢复 origin view，再投递给 responder。取消值和 candidate 为 `#f`；没有 abort
responder 时只完成清理。

## 扩展边界

PromptSession 是读取和资源生命周期，不规定候选如何生成、选择或显示。每个 session
公开一个不可变 `PromptSnapshot`：request、input revision、point、origin context、当前
selection、completion generation 和 presentation constraints。adapter 只能从 snapshot
派生新的候选或预览请求；它通过命令消息提交选择、接受或取消，不能直接改写 prompt
Buffer、View 或 Surface。

completion controller 由 request 的 `completion-source` 创建，并维护：

```text
CompletionController {
  source,
  generation,
  candidates,
  selected_candidate?,
  selection_policy,
  matcher,
  preview?
}
```

source 可以同步或异步地产生结构化 candidate。异步回复必须携带 session id、input
revision 和 generation；任一值不匹配时丢弃。candidate 保存稳定 identity、字符坐标的
replacement range、insert text、label、annotation、group、payload、accept behavior 与可选 preview target。accept behavior
为 `final` 或 `continue`：前者结束读取，后者用 insert text 更新 prompt 并开始下一段读取。
controller 负责筛选、排序、
候选选择和接受策略，presenter 只读取其已发布快照。

minibuffer candidate adapter 接收 controller snapshot，负责固定候选高度、scroll/index
和 candidate 行的显示。候选 View 作为当前 prompt 的 companion，不获取输入焦点；
Surface 在小终端中压缩 companion 并为 root View 保留可编辑行。adapter 不拥有
completion source，也不解释 candidate payload。`free` reader 允许 index 为 `#f` 并接受 raw input；
`must-match` reader 要求有效候选或 source validator。

Consult 类 adapter 通过 source 的 `preview`、`restore`、`accept` 三个 action 接口提供
预览。controller 在选中候选变化时提交可取消 preview request；关闭、取消、generation
切换和 source 替换时调用 restore；restore 接收建立该 preview 时保存的 snapshot，
而不是触发撤销的新输入 snapshot。同一输入 revision 上刷新并保留候选时，controller
先恢复旧 preview，再以刷新后的候选重新建立 preview。成功的最终接受只调用 accept。预览目标由 source payload
解析，避免让 minibuffer 保存 project、buffer 或 window 的可变引用。accept 回调失败时，
controller 使用来源 snapshot 尽力恢复 preview，并继续传播原始失败。

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
prompt 与 transient input 分别使用 `minibuffer.prompt` 和 `minibuffer.input`
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

history 由 MinibufferService 按 symbol 标识并保存，条目以最新值优先。首次向后浏览前保存当前
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
候选分别保存 insert text、label、annotation、group、source、payload 和 accept behavior，显示文本
不承担返回值或对象身份。

`boundaries(input, point)` 使用字符索引返回当前 field 的 `[start, end)`，candidate 将
该范围固化为自己的 replacement range。completion query 是 `[start, point)`；应用候选时原子替换 `[start, end)`，因此光标位于 field
中间时不会留下旧后缀。路径、复合命令和其他分段 reader 可以在插入候选后返回一个
新的空 field，例如 `root/usr/|`。`RET` 遇到这种边界会提交当前 field 并继续读取，
直到候选没有引入后续 field 才结束 prompt。`TAB` 始终只提交当前 field。

Prompt completion 使用 session identity、完整 input revision、point 和 selection 作为 source
context identity。Document 编辑或 selection 移入另一个 field 时，controller 在新的候选可用于
preview、application 或 accept 前刷新 source，并清除旧 context 的 selection。query 不变但
field 外文本发生变化时仍会推进 generation 并重新产生候选。例如从路径末尾删除一个目录
分量后，新目录的空 query 不会复用旧目录的空 query 结果。

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
command symbol。它使用只包含 candidates 的 selection domain、大小写不敏感的
`fzf` 匹配，并默认选择第一项；输入变化后重新选择刷新结果的第一项。发起
`M-x` 的 prefix argument 作为 request data 跨 prompt
生命周期保存，`prompt.execute-command` 把它放入 interactive command message，
因此最终命令收到与直接按键调用相同的 `CommandContext`。
