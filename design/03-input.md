# 输入系统与 TUI

## 输入管线

输入从终端 byte stream 到编辑命令只经过一条管线：

```text
terminal bytes
  -> incremental decoder
  -> KeyEvent
  -> focused View input state
  -> layered keymap
  -> command invocation
  -> Buffer transaction
```

decoder 处理协议，不决定编辑语义；keymap 解析命令，不直接修改 Document；command
通过显式 context 访问当前 view、buffer、selection 和 prefix argument。

## 终端协议

TUI 进入 raw mode 和 alternate screen 后启用 Kitty keyboard protocol 的
disambiguate escape codes 标志，并在退出前恢复先前模式。decoder 同时接受 Kitty
`CSI u`、传统 CSI/SS3 序列、控制字符和 UTF-8 文本。

decoder 是增量状态机：一个 read 可能只包含 UTF-8 code point 或 escape sequence
的一部分，也可能包含多个事件。无法识别的序列以受控的 unknown event 呈现，
不会让 decoder 永久停在 pending 状态。

规范事件：

```text
KeyEvent {
  key,                 // Unicode scalar 或具名功能键
  modifiers,           // shift/control/alt/super/hyper/meta/caps/num
  type,                // press/repeat/release
  text,                // 可插入文本；可为空
  raw                   // 调试所需原始 bytes
}
```

Kitty 修饰位和事件类型在 decoder 边界归一化。legacy Alt 前缀、控制字符与
Backspace/Enter/Tab 也映射到同一结构。

## Keymap

keymap 是一等、具名 trie。节点值可以是 command、子 keymap 或未绑定。完整按键序列
逐层查询，最高优先级中第一个认识该完整序列的层决定结果；稀疏高优先级 keymap
不会遮蔽低层的其他续键。

默认层次从高到低：

```text
override
transient input state
durable input state
window
view
buffer
minor modes
major mode and parents
editor
application
```

解析结果是 `none | prefix | command`。同一个纯查询服务实际 dispatch、按键帮助和
配置内省。命令解析后执行一次 remap pass，remap 不递归。

## Input state

input state 栈属于 View。栈底是 durable state，栈顶可以有 transient state：

```text
InputState {
  keymaps,
  text_input: accept | ignore,
  cursor_shape,
  indicator,
  handler,
  on_enter,
  on_exit
}
```

state 回答“这个 view 以什么姿态解释输入”；major mode 回答“buffer 的内容是什么”。
因此同一 buffer 的两个 view 可以处于不同输入状态，但共享 language mode。

transient state 表达 prefix、单键捕获、operator pending、incremental search 和
picker 会话。`keyboard.quit` 清除 pending sequence、prefix 和 transient state，
并保留 durable state。override 层确保取消命令始终可达。

带文本的 event 先尝试 keymap。事件未被消费且当前 state 接受文本时，`text`
进入插入命令。TUI 的按键与文本位于同一事件中；支持 IME 的前端可以把组合文本
作为独立 text-input event 接入同一规则。

## Selection、motion 与 verb

Selection 属于 View：

```text
Range {
  anchor: DocumentAnchor,
  head: DocumentAnchor,
  granularity: char | line | block | node
}

Selection {
  ranges: non-empty vector<Range>,
  primary,
  metadata
}
```

primary range 的 head 是 caret。多 range 命令把全部 edit 放进一个 transaction。
selection 使用 Document anchor，因此可跨普通编辑存活。

motion 是纯函数：

```text
(snapshot, selection, count) -> selection
```

同一 motion 可以由 move 或 extend command 使用。thing 把当前位置解析为 inner
或 bounds range，可由 delimiter、syntax provider 或字符类实现。verb 消费
selection 并返回 transaction 与 resulting selection。这组原语能组合 Emacs
式命令、Vim operator、Helix 多选区和结构化 selection，而不把某一种 modal
模型固化进 Document。

prefix argument 是下一次 command invocation 的显式字段：

```text
Prefix { count, register, extra }
```

普通命令消费它；取消、解析失败和 view 切换按 input policy 清理它。

## TUI view 与渲染

View 持有 selection、viewport 和输入状态；Window 把 View 放入 layout。frame
从固定 revision 的 snapshot 与 editor state 组合，终端写入只是 frame 的呈现。

完整重绘与 cell diff 是可替换的 presenter 策略，不改变 View、Window 或 Buffer
模型。光标、modeline、minibuffer、popup 和工具区域都使用 terminal cells 表达，
不会向 Document 写入控制序列或虚拟文本。

终端生命周期使用同一个清理作用域恢复 Kitty keyboard mode、alternate screen、
cursor visibility 和 termios。

## 设计依据

分层 trie 保留 Emacs keymap 的组合能力，同时用单一解析规则避免多套翻译 map。
per-view state 吸收 modal 编辑中的临时状态，而不会污染 buffer mode。Kitty
协议在终端边界提供无歧义按键；其结果仍归一化为前端无关的 `KeyEvent`，command
系统不依赖具体终端编码。
