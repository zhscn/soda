# 输入系统与 TUI

## 输入管线

输入从终端 byte stream 到编辑命令只经过一条管线：

```text
terminal bytes
  -> incremental decoder
  -> InputEvent
  -> focused View input state
  -> layered keymap
  -> command invocation
  -> Buffer transaction
```

decoder 处理协议，不决定编辑语义；keymap 解析命令，不直接修改 Document；command
通过显式 context 访问当前 view、buffer、selection 和 prefix argument。

## 终端协议

TUI 进入 raw mode 和 alternate screen 后启用 Kitty keyboard protocol 的
disambiguate escape codes 标志和 bracketed paste，并在退出前恢复先前模式。
decoder 同时接受 Kitty `CSI u`、传统 CSI/SS3 序列、控制字符、UTF-8 文本和
bracketed paste。

decoder 是增量状态机：一个 read 可能只包含 UTF-8 code point 或 escape sequence
的一部分，也可能包含多个事件。无法识别的序列以受控的 unknown event 呈现，
不会让 decoder 永久停在 pending 状态。

规范事件：

```text
KeyEvent {
  key,                 // character 或具名功能键
  codepoint,
  shifted_codepoint,
  base_layout_codepoint,
  modifiers,           // shift/control/alt/super/hyper/meta/caps/num
  type,                // press/repeat/release
  text                  // 可插入 UTF-8 bytes；可为空
}
```

Kitty 修饰位和事件类型在 decoder 边界归一化。legacy Alt 前缀、控制字符与
Backspace/Enter/Tab 也映射到同一结构。普通 UTF-8 字符产生 `character` key，
同时携带 Unicode code point 和可插入的 UTF-8 bytes。

独立文本输入使用另一种事件：

```text
TextInputEvent {
  kind,                // text | paste
  text                 // UTF-8 bytes
}
```

bracketed paste 可以跨多个 read 增量收集，结束后产生一个 `paste` event。粘贴内容
不解释为按键序列，其中的控制字节也不会触发 command。

传统终端中的单独 Escape 与后续序列在 byte stream 上有歧义。decoder 暂存不完整
序列，command loop 用 libuv 单次 timer 安排 flush；timer 到期时，单字节 Escape
成为 `escape` event，其他不完整序列成为 `unknown` event。Kitty `CSI u` 事件不
依赖该超时完成按键判定。

## Keymap

keymap 是一等、具名 trie。节点可以包含 command、显式 undefined tombstone 或
续键子树。完整按键序列逐层查询，最高优先级中第一个认识该完整序列的层决定结果；
稀疏高优先级 keymap 不会遮蔽低层的其他续键。

基础 command loop 实现的层次从高到低：

```text
Editor override
InputState keymap layers, top state first
View keymap layers
Major mode and parents
Editor default
```

解析结果是 `none | prefix | command | undefined`。显式 undefined 在当前层终止
查找并屏蔽低层绑定；移除本地 binding 后，低层 binding 会重新可见。同一个纯查询
服务实际 dispatch、按键帮助和配置内省。keymap 可以枚举全部 binding 或指定前缀
下的 binding；Editor catalog 可以枚举已注册的 keymap 名称。View 层承载持久的
window 和 buffer policy，InputState 层承载临时输入策略。

## Input state

input state 栈属于 View。栈底是 durable state，栈顶可以有 transient state：

```text
InputState {
  name,
  keymap_layers,
  text_policy: accept | ignore,
  text_command
}
```

state 回答“这个 view 以什么姿态解释输入”；major mode 回答“buffer 的内容是什么”。
因此同一 buffer 的两个 view 可以处于不同输入状态，但共享 language mode。

每个 View 始终有一个栈底 state。push 和 pop 操作管理 transient state；切换 View
的 buffer 会恢复栈底 state。`keyboard.quit` 清除 pending sequence 和 transient
state，并保留栈底 state。该命令位于 Editor override 层，因此普通 state keymap
和 tombstone 都不能屏蔽它。

`KeyEvent` 先尝试 layered keymap。事件未被消费、携带文本且当前 state 接受文本时，
文本交给 state 的 `text_command`。`TextInputEvent` 清除 pending sequence，并按
当前 state 的 text policy 原子地交给同一 text command，不经过 keymap。支持 IME
的前端可以用 `text` kind 提交组合文本。

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
caret 与 selection endpoint 使用 Document anchor，多个 View 显示同一 Buffer
时会随提交、undo 和 redo 结算，不会保留失效的裸 byte offset。viewport 同时保存
首行和首个 display column；纵向 motion 按 tab 与宽字符展开后的 display column
维持目标列。

结构化 frame 是 renderer 与 terminal presenter 之间的边界：

```text
Frame {
  rows,
  columns,
  cells,
  layout,
  cursor
}

Cell {
  text,
  width,
  continuation,
  faces,
  style,
  document_position?,
  sources
}

CellSource {
  layer,
  owner,
  detail
}
```

`faces` 保留语义 face 栈，`style` 是用于终端呈现的最终样式。`sources` 记录组成
cell 的正文、chrome 和 decoration 来源；映射正文的 cell 同时保留 document byte
position。tab 展开的每个空格和宽字符的 continuation cell 都保持该映射。

frame 的 `layout` 保存实际使用的 component tree：

```text
Component {
  id,
  render(context, frame, rect)
}

ComponentNode {
  id,
  rect,
  component?,
  children
}
```

component 不拥有 command loop，也不直接处理 terminal bytes。它读取 render
context，只在分配的 Rect 中绘制。父节点先绘制，children 按顺序覆盖；坐标查询按
相反顺序选择最上层的 component，并可返回从 root 到 leaf 的完整路径。

layout 使用纯 Rect 运算。fixed extent 保留指定 cell 数，flex extent 按整数权重
确定性分配剩余空间。正文和 modeline 是 root 下的两个独立 component；同一 split
机制供后续 WindowLayout、minibuffer 保留行和工具区域复用。

renderer 只读取 viewport 覆盖的行，向 frame 写入 cell，并计算结构化 cursor。
presenter 是唯一生成 ANSI 控制序列的组件。首帧与尺寸变化使用完整重绘，后续帧
比较 cell 的 text、width、continuation 与 style，只写入发生显示变化的 cell。
光标、modeline、minibuffer、popup 和工具区域都使用 cells 表达，不会向 Document
写入控制序列或虚拟文本。

`describe-caret` 从 snapshot 与最终 frame 生成结构化字符描述，包括 code point、
document position、screen cell、component path、显示宽度、faces、style 和 sources。
`help.describe-char` 通过 `C-x =` 显示该描述。REPL、generated buffer 和调试
overlay 可以消费同一个描述值，不需要解析 ANSI 输出。

终端生命周期使用同一个清理作用域恢复 Kitty keyboard mode、bracketed paste、
alternate screen、cursor visibility 和 termios。

## 设计依据

分层 trie 保留 Emacs keymap 的组合能力，同时用单一解析规则避免多套翻译 map。
per-view state 吸收 modal 编辑中的临时状态，而不会污染 buffer mode。Kitty
协议在终端边界提供无歧义按键；其结果归一化为前端无关的 `InputEvent`，command
系统不依赖具体终端编码。
