# 输入与 Keymap

## 实现状态

| 能力 | 状态 |
|---|---|
| Kitty keyboard、legacy key、paste 与 resize 解码 | 已实现 |
| canonical InputEvent 与增量 decoder | 已实现 |
| keymap、prefix、remap 与 tombstone | 已实现 |
| per-View InputState、layer composition 与 text policy | 已实现 |
| terminal session、alternate screen 与 host message queue | 已实现 |
| Buffer mode/minor-mode input Facet | 已实现 |
| prefix argument、M-x、where-is 与输入内省 UI | 部分实现 |

## 边界

输入管线把 terminal bytes 规范化为事件，再由 active View 的显式 input context 解析。terminal
decoder 不认识 command、mode 或 Buffer。keymap resolver 不修改 editor state；执行 command
与插入 committed text 都经过 CommandRuntime。

```text
terminal bytes
  -> TerminalDecoder
  -> InputEvent
  -> Surface message queue
  -> active View + InputContext
  -> InputDisposition
  -> CommandRuntime / text command
```

minibuffer 的 transient input layer 由 [06-minibuffer.md](06-minibuffer.md) 定义。Buffer mode
对 input context 的贡献由 [03-buffer-ui.md](03-buffer-ui.md) 定义。

## Canonical event

物理输入规范化为互斥事件：

```text
KeyEvent      key identity, modifiers, action, raw bytes
TextInput     committed UTF-8 text
PasteEvent    bracketed payload
ResizeEvent   terminal columns and rows
```

Kitty protocol 保留物理 key、shifted key、modifier 和 press/repeat/release。legacy terminal 只
解码明确支持的序列，不恢复 `C-h = Backspace` 等历史兼容。未知或不完整序列由增量 decoder
保留到后续 bytes；非法序列产生受控 condition，不把半个事件交给 keymap。

legacy `ESC + printable/control` 表示 Meta 修饰键；连续 `ESC` 分别产生 Escape KeyEvent，使
application-level `ESC ESC ESC` 不受 stdin 分块方式影响。末尾单个 `ESC` 在 escape timer 到期后
提交。Kitty report 直接携带 modifier，不经过该歧义规则。

Soda TUI 不实现平台 IME。终端已经提交的 text 进入 `TextInput`；key event 与 committed text
保持不同通道，避免把键帽字符误当作文本提交。

## KeyStroke 与 Keymap

`KeyStroke` 使用规范 key identity 和 modifier bitset。keymap 支持：

- 单键与多键 sequence；
- sequence prefix 查询；
- command symbol binding；
- command remap；
- 显式 unbind/tombstone；
- owner-scoped keymap contribution。

keymap 本身不执行 procedure。解析结果是 `InputDisposition`：command、text、consume、pass 或
pending prefix。command symbol 由 runtime registry 解析，因此 keymap 不持有可失效 closure。

## InputContext 与 layer

每次事件从 active Surface/Window/View 构造不可变 InputContext：

```text
InputContext {
  surface_id,
  window_id,
  view_id,
  buffer_id,
  layers,
  input_stack,
  translation
}
```

`InputTranslation` 把 frontend-neutral 的原始 KeyStroke sequence 投影为 resolver sequence，并为
introspection 提供等价输入序列。pending sequence 保留原始按键，因此 echo area 反映用户实际输入；
dispatch、prefix guidance 和 command lookup 使用同一个 translation。Emacs application 将
`ESC + key` 规范化为对应的 Meta KeyStroke，连续 Escape 保持独立 prefix key。其他 application
使用 identity translation。

frontend 生成的 `CommandContext` 保留触发该 command 的有序 InputLayer 与 Keymap 快照。`M-x`、Help、
`describe-command` 与 `where-is` 使用该快照构造用户命令可达性投影；临时 interaction keymap
因此与实际 dispatch 一致，且不会由后续的配置重组替代。没有 frontend 快照的直接或测试调用使用
Buffer mode 与 application fallback 重建等价层。

声明式键位属于 `ConfigurationSource`。每个 source 独立验证和 materialize 为 InputLayer；同一
source 内相同 context、mode、semantic rank 与 sequence 的重复声明是配置错误。编辑 context
按 source 的配置优先级组合：较晚注册的 user source 覆盖较早的 user source，user source 覆盖
application source。source 的一次 reload 在 settings 和键位声明均通过验证后才替换活动 generation，
失败时保留先前的 input composition。诊断保留 binding 的 source location，并区分未知 command、
未知 mode 与 mode capability 不匹配。

layer 按高到低组合：

```text
transient interaction
View-local session
Buffer minor mode
Buffer major mode
fundamental editing
global
```

Buffer mode layer 由 Buffer extension Facet 接入。resolver 对同一 context/event 是纯函数。

## Per-View InputState

InputState 属于 ViewState，包括 pending sequence、prefix argument、transient session 和反馈。
同一 Buffer 的两个 View 可以分别停在不同 prefix 或 minibuffer/read-key 会话。输入解析先通过
View transaction 发布新 InputState，再构造 command context，使 command 观察到与下一事件一致
的状态。

application override layer 在所有 View 中提供 `C-g` 与 `ESC ESC ESC` 的统一 quit。单次 `ESC`
只建立 prefix，临时界面不把它单独解释为取消。

`PrefixGuidance` 是 active pending sequence 对同一 resolver 的只读投影，只包含仍可到达的下一键
及 command name。没有 pending sequence 时投影为空；Surface 不承载常驻快捷键列表。

焦点切换不复制 InputState。View 关闭会取消其 transient input session；Buffer 关闭由 host
先关闭关联 View。

## Text policy

每个 layer 声明 text policy：accept、pass 或 capture。普通编辑 View 把 `TextInput` 转换为
`fundamental.insert-text`；只读/generated mode 可以拒绝或把 text 解释为 mode command；
minibuffer 接受文本但覆盖部分按键。

Paste 是单个输入事件和单个编辑 command，不逐字符经过 keymap。文本内容仍受 Buffer edit
filter、selection replacement 和 transaction validation 约束。

## Terminal session

terminal frontend 负责 raw mode、alternate screen、Kitty enable/disable、bracketed paste、
cursor shape、OSC 52 和 ANSI output。所有设置由 terminal session 成对恢复；退出和 condition
unwind 使用同一 cleanup path。

stdin readiness、resize 和 writable notification 进入 host message queue。terminal callback 不
调用 Scheme command，也不直接触发 render。render generation 改变后 frontend 才建立目标 Frame。

## Contract tests

输入 contract tests 覆盖：

- Kitty、legacy、paste 和分块序列解码；
- modifier 与 committed text 分离；
- keymap prefix、remap、unbind 和 layer precedence；
- 每个 View 独立的 pending sequence/InputState；
- command disposition 统一进入 CommandRuntime；
- paste 作为单一 transaction；
- terminal cleanup 恢复 raw mode 与 alternate screen。
