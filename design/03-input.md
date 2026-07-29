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
文件 I/O、补全 provider 和其他异步设施把结果包装成 command-loop message，并在
同一更新入口完成 identity、generation 与 revision 校验。

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
Pending prefix argument
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

View 持有一个 primary region：

```text
PrimaryRegion {
  mark: DocumentAnchor?,
  head: DocumentAnchor,       // caret
  active: bool
}
```

mark 与 caret 都使用 Document anchor，因此 region 可跨普通编辑、undo 和 redo
存活。普通 motion 在 mark active 时移动 head 并扩展 region；插入、删除、kill
和 yank 把 active region 作为替换范围。切换 View 的 Buffer 或关闭 View 会释放
mark anchor。

Editor 拥有有界 kill ring。copy-region 和 kill command 把 UTF-8 bytes 复制到
ring，yank 插入最新条目。连续的 kill class command 共享最新条目：向前 kill
追加，向后 kill 前置。每次删除仍是独立的 Buffer transaction，因此 kill ring
合并与 undo 粒度彼此独立。copy command 可以承接前一次 kill，但自身不属于 kill
class。ring 不属于 Document，不进入 undo tree。

yank 保存 view、buffer、revision、替换范围和 ring index 组成的 transient state。
紧随其后的 yank-pop 用下一条 ring entry 替换同一范围；正负 count 分别向两个方向
旋转并按 ring 长度回绕。yank 和 yank-pop 属于同一 command class。其他交互命令、
view/buffer 不匹配或 revision 改变都会使该范围失效。

范围修改通过共享的 Buffer edit mechanism 提交。普通 replace/delete、open-line、
horizontal-space 删除和 kill range 使用相同的 transaction 生命周期；kill 在
transaction 成功后才更新 ring。不带参数的 `kill-line` 计算当前 point 到行内容
末尾；point 已在内容末尾时删除换行符。显式正参数按整行向前计算边界，负参数向后
计算边界，零参数不修改 Buffer。连续调用沿用普通 kill command 的
append/prepend 规则，同时保留独立 undo 单元。

多 range selection 可以把 primary region 泛化为：

```text
Selection {
  ranges: non-empty vector<Range>,
  primary,
  metadata
}
```

多 range 命令把全部 edit 放进一个 transaction。

motion 是纯函数：

```text
(snapshot, selection, count) -> selection
```

同一 motion 可以由 move 或 extend command 使用。thing 把当前位置解析为 inner
或 bounds range，可由 delimiter、syntax provider 或字符类实现。verb 消费
selection 并返回 transaction 与 resulting selection。这组原语能组合 Emacs
式命令、Vim operator、Helix 多选区和结构化 selection，而不把某一种 modal
模型固化进 Document。

word motion 是 motion policy 的一个可替换实例。命令按 Buffer local setting、
language profile、Unicode 默认实现的顺序解析 policy。默认实现把 Unicode 字母、
数字、组合字符、connector punctuation 和下划线视为 word constituent。major
mode 可以替换 policy，实现语言 identifier、subword 或自然语言分词，而
move-word、kill-word 等消费者保持不变。

prefix argument 是下一次 command invocation 的显式字段：

```text
PrefixArgument {
  sign,
  magnitude,
  kind: universal | digits | negative
}

CommandContext {
  editor,
  view,
  event?,
  argument?,
  prefix?
}
```

`C-u` 建立数值 4，连续 `C-u` 乘以 4；`M-0` 至 `M-9` 输入数字，`M--`
切换符号。prefix 存在时临时 keymap 也接受普通数字和减号。prefix command 更新
pending 值而不成为普通 command class；下一条普通命令把值移入
`CommandContext` 并清除 pending 状态。command 通过 `command-context-count`
取得默认值为 1 的有符号重复次数。

字符、word 和纵向 motion 接受正负 count；self-insert、newline 和 open-line
接受非负 count；kill-line 使用 prefix 是否显式存在来区分默认行为与显式数值
行为。取消、未定义按键和命令错误清除 pending prefix。

transpose-character、transpose-word 和 word case command 先从 motion 与当前
snapshot 计算 UTF-8 byte range，再通过普通 Buffer replace transaction 提交。
大小写转换使用 Unicode string case mapping，替换后按转换结果的实际 byte 长度
安置 point。

## Incremental search 与 query replace

incremental search 使用 PromptSession 读取 query，并把 SearchSession 作为 request
data。PromptRequest 的 change continuation 在每次输入 revision 改变后重新匹配；
搜索逻辑不依赖 completion candidate。session 保存 origin View、live
EditorLocation、方向、query、当前 match 和 wrap 状态。

`C-s` 和 `C-r` 分别启动前向和后向搜索；搜索 prompt 活动时再次调用会从当前
match 后或前继续。query 改变时从 origin 重新匹配。成功 match 临时使用 origin
View 的 active region 呈现，失败保留最后位置并报告 failing 状态，越过 Buffer
边界后回绕。接受搜索先恢复 origin，再通过 navigation jump 落到 match，因此写入
View 的 location walk；取消清除临时 region 并恢复 live origin。

query replace 由 query、replacement 和 decision 三个非递归阶段组成。前两个阶段
使用普通 minibuffer；decision 阶段压入忽略文本输入的 transient InputState，只
解释：

- `y` 或 Space：替换当前 match；
- `n` 或 Delete：跳过当前 match；
- `!`：替换全部剩余 match；
- `q`：保留已经完成的替换并结束。

每次替换使用 Buffer range transaction，并从 replacement 末尾继续扫描，从而不会
重复匹配刚插入的 replacement。`C-g` 在读取阶段恢复 origin；在 decision 阶段停止
遍历并保留已经提交的 transaction。

## TUI view 与渲染

View 持有 selection、viewport 和输入状态；Window 把 View 放入 layout。frame
从固定 revision 的 snapshot 与 editor state 组合，终端写入只是 frame 的呈现。
caret 与 selection endpoint 使用 Document anchor，多个 View 显示同一 Buffer
时会随提交、undo 和 redo 结算，不会保留失效的裸 byte offset。viewport 同时保存
首行和首个 display column；纵向 motion 按 tab 与宽字符展开后的 display column
维持目标列。

Editor 的 WindowLayout 是由 leaf 和 split 组成的树：

```text
WindowNode =
    WindowLeaf { id, view_id }
  | WindowSplit {
      id,
      orientation: horizontal | vertical,
      children
    }
```

leaf 引用 durable View，split 的 children 按相等 flex weight 分配矩形。切分 active
leaf 时复制当前 View 的 Buffer、point、mark、viewport 和 keymap policy，两个
View 随后独立维护 point、selection、completion 和 location walk。选择已有 View
时把它换入 active leaf；若该 View 已显示在另一 leaf，则两个 leaf 交换 View，
避免一个 View 同时占据多个 Window。

`C-x 2` 产生上下 split，`C-x 3` 产生左右 split，`C-x o` 按 leaf 顺序切换焦点，
`C-x 0` 删除 active leaf 并折叠单子节点 split，`C-x 1` 只保留 active leaf。
negative prefix 可让 `other-window` 反向遍历。Window 删除时同时释放其 View 和
per-View navigation anchors；直接关闭仍被 leaf 显示的 View 是生命周期错误。

TUI renderer 递归映射 Window tree。每个 leaf rectangle 由 text 区和一行 modeline
组成，只有 active leaf 设置终端 cursor。minibuffer 和 prompt completion 位于
整棵 Window tree 下方；出现或消失时 resize 从根重新分配所有 leaf viewport。
document completion popup 使用 active leaf 的局部 text rectangle 定位，并作为
根级 overlay 最后绘制。

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
确定性分配剩余空间。正文、modeline 和活动 minibuffer 是 root 下的独立
component；同一 split 机制供 WindowLayout、保留行和工具区域复用。

renderer 只读取 viewport 覆盖的行，向 frame 写入 cell，并计算结构化 cursor。
presenter 是唯一生成 ANSI 控制序列的组件。首帧与尺寸变化使用完整重绘，后续帧
比较 cell 的 text、width、continuation 与 style，只写入发生显示变化的 cell。
光标、modeline、minibuffer、popup 和工具区域都使用 cells 表达，不会向 Document
写入控制序列或虚拟文本。

presenter 输出进入有序 byte queue。terminal ABI 尝试 partial write；would-block
时由 runtime 注册 output fd writable interest，后续事件继续发送未写 suffix。
frame 的逻辑提交顺序与 byte queue 顺序一致，短写不会导致 ANSI 序列截断。

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
