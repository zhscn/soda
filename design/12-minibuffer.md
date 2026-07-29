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

TUI root 在 session 活动时按正文、modeline、可选 completion list 和 minibuffer
布局。minibuffer 与候选列表占用底部保留行并参与 reflow；prompt 使用独立 face，
输入 cell 保留 transient Document position 和 component source，因此光标与
`describe-char` 仍使用统一的 frame 数据。

## Keymap 与 history

`prompt.input` transient keymap 定义：

- `RET`、`C-j`：接受；
- `ESC`、`C-g`：取消；
- `Up`、`C-p`：上一条 history；
- `Down`、`C-n`：下一条 history。
- `TAB`、`S-TAB`：选择下一个或上一个 completion candidate。

history 由 Editor 按 symbol 标识并保存，条目以最新值优先。首次向后浏览前保存当前
draft；向前越过最新条目时恢复 draft。只有通过验证的非空接受值进入 history，
连续重复值只保留一份。default、initial 和 history 是彼此独立的输入来源。

## Completion 接口

带补全的读取在 `PromptSession` 上附加 `CompletionSession`，不改变 prompt 的接受、
取消和 reply 契约。completion 管线使用两类目标：

```text
CompletionTarget =
    DocumentTarget(document-id, revision, range)
  | PromptTarget(prompt-session-id, generation, range)
```

两类目标共享 `CompletionItem`、generation、候选身份、过滤排序、选择状态和 TUI
presenter。language provider 继续产生 revision-aware edit；命令、Buffer、路径和
Scheme binding 等离散集合通过 choice source 归一化成相同的候选条目。

choice source 显式提供 metadata、boundaries、candidates、validate 和 cancel 操作。
候选分别保存 insert text、label、annotation、group、source 和 payload，显示文本
不承担返回值或对象身份。

`M-x` 使用 command registry choice source 和 `extended-command` history 读取
command symbol。发起 `M-x` 的 prefix argument 作为 request data 跨 prompt
生命周期保存，`prompt.execute-command` 把它放入 interactive command message，
因此最终命令收到与直接按键调用相同的 `CommandContext`。
