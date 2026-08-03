# Soda Editor Kernel 与 Workbench Host

## 定位

Soda 由编辑器状态内核、Workbench host、TUI frontend 和功能包组成。四层共享同一套
transaction、identity、owner 和 extension 协议，但具有不同的职责边界：

```text
native substrate
  Text / Document / anchor / libuv / terminal / parser ABI
                              │
                              ▼
editor kernel
  text snapshot / ChangeSet / Selection / StateField / Facet / Transaction / RangeSet
                              │
                              ▼
workbench host
  Buffer / View / Window / Surface / command / input / runtime / package / condition
                              │
                              ▼
TUI frontend
  terminal decoder / layout / Frame / presenter
                              │
                              ▼
feature packages
  editing / files / modes / minibuffer / language / project / LSP / REPL / debugger
```

编辑器状态内核采用 CodeMirror 的边界：文档、selection 和 extension state 构成一个
不可变状态快照；所有状态变化由 transaction 描述和发布；扩展通过 StateField、Facet、
StateEffect、Compartment 和 RangeSet 组合。

Workbench host 增加多 Buffer、多 View、Window tree、Surface、Scheme command loop 和
资源生命周期。这些机制是 Soda 应用的稳定宿主协议，不进入编辑器状态内核。

输入模型采用 per-View InputState、具名 keymap 和分层纯解析器。terminal decoder 只把
物理输入规范化为 KeyStroke、committed text 和 paste，不决定 mode、命令或文本编辑策略。

## 架构不变量

1. 一个 Buffer 在任一时刻发布一个不可变 BufferState。
2. 一个 View 在任一时刻发布一个不可变 ViewState，并引用一个 Buffer identity。
3. 同一 Buffer 的多个 View 共享文本，不共享 Selection、viewport 或 InputState。
4. document、selection、extension state 和 configuration 只通过 transaction 更新。
5. transaction 以 start state 或 generation 标识其基线；过期 transaction 不能提交。
6. extension state 通过 StateField 更新；组合配置通过 Facet 读取；动态配置通过
   Compartment 重配置。
7. package owner 管理注册和外部资源生命周期，不充当任意 editor state 存储。
8. Window 只承载 View placement；Surface 只承载 Window tree、focus 和 terminal context。
9. Buffer 文本是文件和工具界面的公共内容表示。xref、diagnostics、debugger、dashboard
   和 completion candidate 都可以投影成普通 Buffer。
10. 输入分发、命令执行、异步结果和内部刷新通过同一 dispatch publication boundary。
11. renderer 只读取已发布的状态、RangeSet 和 ViewPlugin 输出，不运行语言分析。
12. editor kernel、workbench host 和 TUI frontend 不按功能包名称分派。

## 依赖结构

依赖保持单向，功能包不被底层 library 导入：

```text
(soda kernel value)
  identity, owner-neutral values, offset, range
          │
          ├──> (soda kernel document)
          │      DocumentSnapshot, ChangeSet, ChangeDesc
          │
          ├──> (soda kernel selection)
          │      SelectionRange, Selection
          │
          ├──> (soda kernel range-set)
          │      persistent mapped ranges
          │
          └──> (soda kernel extension)
                 StateField, Facet, StateEffect, Annotation, Compartment
                            │
                            ▼
                     (soda kernel state)
                      BufferState, Transaction
                            │
                            ▼
                  (soda kernel view-state)
                  ViewState, ViewUpdateContext

(soda host value)
  owner, registration, capability
          │
          ├──> buffer/view registry
          ├──> window/surface/placement
          ├──> input/command/dispatch
          ├──> runtime/task/condition
          └──> package/service

(soda tui ...)
  terminal input -> Surface input
  View update -> display stream -> Frame -> terminal presenter

(soda packages ...)
  depend on kernel and declared host capabilities
```

不提供聚合全部 API 的大 facade。package activation context 只暴露 manifest 声明的
capability。editor kernel 不导入 host，host 不导入 TUI，TUI 不导入功能包。

## Editor kernel

### Canonical offset 与 DocumentSnapshot

文档位置使用从零开始的 UTF-8 byte offset。一个 offset 只在其所属 DocumentSnapshot
中有意义：

```text
Offset = exact non-negative integer

TextRange {
  from: Offset,
  to: Offset
}
```

DocumentSnapshot 提供：

- byte offset 与 line/byte-column 的双向转换；
- byte offset 与 Unicode scalar、grapheme boundary 的查询；
- 按 byte range 读取而不复制整个文档；
- line、slice 和 iterator；
- snapshot identity、revision 和 byte length。

Buffer 以弱引用跟踪其发布过的 DocumentSnapshot，并在 Buffer 生命周期结束时关闭仍存活的
snapshot。失去 Scheme 引用的 snapshot 由 native handle guardian 回收。临时 transaction 和
change handle 由创建它们的动态作用域确定性关闭。

command 使用 grapheme、word、line、syntax node 等语义查询移动位置，不直接对 UTF-8 byte
offset 做字符级加减。LSP UTF-16、terminal cell column 和 Tree-sitter point 由各自 adapter
转换，不进入通用 Position 值。跨 revision 保存的位置使用 Anchor；transaction 内的位置
使用当前 state 的 offset。

### ChangeSet 与 ChangeDesc

文本变化是规范化、不可变的值：

```text
TextChange {
  from,
  to,
  insert
}

ChangeSet {
  old_length,
  new_length,
  changes: ordered non-overlapping TextChange
}
```

ChangeSet 提供：

- 应用到 DocumentSnapshot；
- 组合同时或顺序产生的 change spec；
- 生成逆变化所需的信息；
- 取得不含插入文本的 ChangeDesc；
- 映射 offset、range、Selection、StateEffect 和 RangeSet；
- 明确 before/after affinity 和被删除区间的处理策略。

所有多 range 编辑先产生一个规范化 ChangeSet，再一次提交。底层 native
DocumentTransaction 是实现 ChangeSet 的机制，不作为功能包直接修改 Buffer 的入口。

### Selection

Selection 是 ViewState 的固定组成部分：

```text
SelectionRange {
  anchor: Offset,
  head: Offset,
  affinity: before | after,
  granularity: character | line | block | node,
  metadata
}

Selection {
  ranges: nonempty ordered list<SelectionRange>,
  primary: index
}
```

range 有方向，`head` 是活动端。空 range 表示 caret。多个 range 经过规范化，重叠区间的
合并策略由创建 Selection 的操作显式选择。

ChangeSet 自动映射旧 Selection。transaction 可以提供更新后文档中的显式 Selection。
发起 Buffer 编辑的 View 使用显式结果；共享该 Buffer 的其他 View 使用 ChangeDesc 自动
映射其 Selection。

Selection after edit policy、motion、thing、verb、region、mark ring 和 mark activation
属于编辑功能包。kernel 提供 Selection 值、映射和 `change-by-range` 组合原语。

### BufferState 与 ViewState

BufferState 是不可变编辑状态：

```text
BufferState {
  document: DocumentSnapshot,
  configuration: Configuration,
  field_values: FieldTable,
  generation
}
```

ViewState 是不可变视图状态：

```text
ViewState {
  buffer_id,
  buffer_generation,
  selection: Selection,
  viewport: Viewport,
  input_state: InputStateStack,
  configuration: Configuration,
  field_values: FieldTable,
  generation
}
```

BufferState 不保存 file path、major mode、Project、process、modified flag 或 LSP session。
这些值由功能包的 StateField 提供。ViewState 不保存 Window、terminal 或领域 UI model。

State 对外只暴露不可变查询。Buffer 和 View host object 只保存 identity、owner、当前 state
引用和生命周期，不允许 package 直接修改 state 字段。

### Transaction

修改文档或 Buffer extension state 的动作使用 Buffer transaction：

```text
TransactionSpec {
  target_buffer_id,
  origin_view_id?,
  start_generation,
  changes?,
  selection?,
  effects: list<StateEffect>,
  annotations: list<Annotation>,
  scroll_request?,
  filter?: boolean
}

Transaction {
  start_buffer_state,
  changes: ChangeSet,
  explicit_selection?,
  effects,
  annotations,
  new_buffer_state
}
```

View-local state 使用独立的 transaction 形状，并复用同一个 publication boundary：

```text
ViewTransactionSpec {
  target_view_id,
  start_view_generation,
  selection?,
  viewport?,
  input_state?,
  effects,
  annotations,
  scroll_request?
}

ViewUpdateContext {
  target_view_id,
  origin?,
  buffer_transaction?,
  start_view_state,
  selection,
  viewport,
  input_state,
  effects,
  annotations
}
```

document transaction 更新来源 View，并映射同一 Buffer 的其他 View。view-local transaction
保持 BufferState 和 sibling ViewState 不变。两种 transaction 都发布包含 old/new
ViewState 的 EditorUpdate。

多个 TransactionSpec 可以合并成一个 transaction；同时 spec 的位置以起始文档为准，
sequential spec 的位置以前序 spec 产生的文档为准。

提交顺序固定为：

```text
resolve current states
  -> normalize specs and ChangeSet
  -> run transaction filters
  -> run transaction extenders
  -> realize native DocumentSnapshot
  -> update Buffer StateFields
  -> map/update all affected ViewStates
  -> publish EditorUpdate
  -> notify ViewPlugins and update listeners
  -> schedule render damage
```

transaction filter 可以拒绝或转换 transaction。filter 是纯状态变换，不执行 I/O，不进入
command loop，也不直接 dispatch 嵌套 transaction。update listener 观察已提交的
EditorUpdate，需要继续工作时向 runtime 投递 message。

Annotation 描述整个 transaction 的事实，例如：

- origin、user event 和 invocation identity；
- timestamp；
- history grouping hint；
- remote/internal 标记；
- scroll intent。

StateEffect 描述伴随文本和 Selection 一起发生的 extension state 变化。每个 effect 的
target 为 `buffer`、`origin-view` 或 `all-views`。Buffer StateField 只接收 buffer effect；
来源 View 接收 origin-view 和 all-views effect；共享同一 Buffer 的其他 View 只接收
all-views effect。包含位置的 effect 必须定义通过 ChangeDesc 的映射操作。mapper 返回
`state-effect-drop` 时丢弃 effect；`#f` 是普通 effect value。

### StateField

StateField 保存必须与 editor state 同步的扩展状态：

```text
StateField<T> {
  scope: buffer | view,
  create(state) -> T,
  update(T, Transaction | ViewUpdateContext) -> T,
  compare?(T, T),
  provide?(field) -> Extension
}
```

适合 StateField 的数据包括 syntax snapshot、history、mode state、diagnostics snapshot、
completion session identity、generated-buffer model identity 和 display configuration。

FieldTable 按 Configuration 的声明顺序保存字段，并用 StateField identity 建立索引。对外
查询保持不可变；字段初始化和更新不扫描其他 package registry。

外部 process handle、libuv request、file descriptor、LSP transport 和 continuation 由 package
instance 与 owner 管理；StateField 只保存稳定 identity 或不可变快照。

### Facet

Facet 收集多个 extension contribution，并组合成一个只读配置值：

```text
Facet<Input, Output> {
  combine(list<Input>) -> Output,
  compare_input?,
  compare_output?,
  default,
  scope: buffer | view | host
}
```

Facet 用于：

- transaction filters、extenders 和 update listeners；
- read-only/edit policy；
- keymap、mode 和 input policy contributions；
- language data、indentation、comment 和 structure providers；
- decorations、atomic ranges 和 display providers；
- command target、placement 和 condition handlers；
- settings 的组合值。

功能包读取 Facet 的组合结果，不遍历其他 package registry，也不根据 package 名称查找实现。

### Extension、precedence 与 Compartment

Extension 是声明式配置值，可以包含 StateField、Facet provider、ViewPlugin 或嵌套的
Extension list。Configuration 展平 extension，按 precedence 和声明顺序产生确定结果：

```text
highest -> high -> default -> low -> lowest
```

precedence 只决定同一 Facet 中 contribution 的顺序。输入 keymap 的领域层级由输入策略
单独组装，不以通用 extension precedence 代替。

Compartment 是可动态替换的一段 configuration：

```text
Compartment.of(extension)
Compartment.reconfigure(extension) -> StateEffect
```

major mode、minor mode 集合、input strategy、theme 和 buffer-specific settings 使用独立
Compartment。重配置与文本、Selection 和其他 StateEffect 在同一个 transaction 中发布。

### RangeSet、Anchor 与区间能力

RangeSet 是持久、排序且可通过 ChangeDesc 高效映射的 tagged range 集合。它提供 range
cursor、intersection query、spans 和 builder。不同语义共享 RangeSet 数据结构，而不是
共享一个全能 Extent record：

```text
ContentPropertySet   与内容/history 一起更新的文本属性
StateRangeSet        StateField 拥有的语义范围
DecorationSet        View/render 使用的显示范围
AtomicRangeSet       movement/edit policy 使用的不可分割范围
```

RangeValue 定义边界 affinity、是否跨删除保留，以及映射方法。renderer、hit test、
describe-char 和 command 按 Facet 查询相关 typed RangeSet。

Anchor 用于跨 transaction 长期保存单一位置，例如 jump、bookmark、异步 request origin 和
外部诊断定位。Selection 和 RangeSet 内部使用 transaction mapping，不为每个端点分配独立
Anchor 对象。

read-only、comint editable boundary 和 protected generated-buffer 区域通过 transaction
filter 与 range Facet 实现。narrowing 作为标准 extension 组合 accessible-range Facet、
View projection 和 edit filter，不扩充 Buffer 固定字段。

## Workbench host

### Buffer

Buffer 是有 identity 的状态容器：

```text
Buffer {
  id,
  owner,
  name,
  state: live | closing | closed,
  current: BufferState
}
```

Buffer registry 分配不复用的 identity。跨 command turn 和异步边界保存 BufferId，使用时
重新解析。关闭 Buffer 会先关闭关联 View 和 package attachment，再释放 DocumentSnapshot
及 owner resources。

所有面向用户的文本界面使用 Buffer。generated Buffer 将领域 model 投影为文本，并将
semantic id、location、action 和 face 保存到 package-owned StateField/RangeSet。command
通过 point 下的 range value 取得 payload，不解析显示字符串。

### View

View 是 Buffer 的独立交互投影：

```text
View {
  id,
  owner,
  current: ViewState,
  plugins: ViewPluginInstances,
  state: live | closed
}
```

ViewPlugin 保存只与一个 View 实例和渲染生命周期相关的缓存：

```text
ViewPlugin {
  create(view) -> value,
  update(value, ViewUpdate),
  destroy(value),
  decorations?(value) -> DecorationSet,
  provide? -> Extension
}
```

ViewPlugin 可以维护 viewport analysis、layout cache、completion popup projection 和增量
display cache。需要参与序列化、history 或 transaction 原子性的状态进入 StateField，
不放入 ViewPlugin。

### Window、Surface 与 active context

Window tree 表示 placement：

```text
Window = Leaf(view_id, rectangle)
       | Split(axis, ratio, children)
```

Window 不保存 point、mode、Project 或功能状态。DisplayRequest 由 placement service 解析，
功能包不直接修改 leaf：

```text
DisplayRequest {
  buffer_id,
  origin_view_id?,
  role,
  focus_policy,
  placement_hint?,
  provenance?
}
```

Surface 是一个输入和显示平面：

```text
Surface {
  id,
  frontend,
  size,
  capabilities,
  root_window,
  selected_window,
  generation
}

ActiveContext {
  surface_id,
  window_id,
  view_id,
  buffer_id,
  interaction_stack
}
```

selected Window 始终是 root tree 中的 live leaf。切换 focus、进入 interaction 或应用
DisplayRequest 产生 HostOperation 和 HostUpdate；异步结果不能隐式改变 active context。
headless frontend 可以创建没有 terminal writer 的 Surface。

### Dispatch 与 EditorUpdate

dispatch 是 editor state 的唯一 publication boundary：

```text
dispatch(TransactionSpec | Transaction)
  -> Transaction
  -> EditorUpdate {
       old/new BufferState,
       affected old/new ViewStates,
       ChangeSet,
       annotations,
       damage
     }
```

Window、focus、Buffer lifecycle 和 Surface mutation 使用 HostOperation，经同一个单线程
dispatcher 串行执行并产生 HostUpdate。command、runtime message、internal refresh 和测试
都只能调用 dispatcher，不持有 registry 内部可变表。

### Owner、package 与 service

Owner 管理可撤销资源：

- command、StateField、Facet provider、ViewPlugin 和 service registration；
- Compartment contribution；
- runtime request、task、timer、process 和 native handle；
- condition、interaction 和 continuation payload；
- Buffer/View attachment。

package activation 在 contribution transaction 中建立 extension 和 service。activation
失败会按逆序撤销注册并关闭 owner。deactivation 先 dispatch configuration removal，使
StateField 和 ViewPlugin 完成退出，再取消 task、关闭 native resource 和 owner。

service contract 是具名、带版本的 capability。package 只依赖 manifest 声明的 service，
可选依赖通过 capability query 发现。service procedure 返回普通值、TransactionSpec、
HostOperation、Effect 或 Request，不返回 registry 内部可变对象。

### Message、Effect 与异步任务

runtime message 是有目标和生命周期的 envelope：

```text
Message {
  target,
  owner,
  request_id?,
  scope?,
  generation,
  source?,
  payload
}
```

外部 I/O Effect 与 StateEffect 是不同类型：

- StateEffect 参与 editor transaction；
- Effect 请求 filesystem、process、timer、clipboard、terminal 或其他 host I/O。

异步 request 持有 owner、scope、request id、target generation 和 cancel operation。完成结果
只投递普通 Message。dispatcher 在调用 package callback 前验证 owner、target、request 和
generation；过期结果直接退役。

Scheme task 以有界 step 协作运行。每个 step 返回 done、yield、wait 或 cancelled。重计算
任务拆成可中断 step，native worker 只处理不持有 Scheme object 的纯数据工作。

### Condition boundary

每个 package callback、command、task step、ViewPlugin update 和 message handler 都经过
condition boundary。捕获结果保存为：

```text
EditorCondition {
  id,
  origin,
  owner,
  condition,
  continuation?,
  frames,
  restarts,
  state: pending | dismissed | resumed
}
```

condition service 保存 continuation 和 restart；debugger package 只负责将其投影为普通
Buffer。dismiss、resume 和 owner deactivation 是一次性状态转换。功能包异常不会退出
command loop 或破坏已发布 state。

## 输入系统

### Frontend decoder

TUI frontend 把 terminal bytes 转换为规范输入：

```text
terminal bytes
  -> Kitty / CSI / UTF-8 / bracketed-paste decoder
  -> KeyEvent | TextInputEvent | PointerEvent | ResizeInput
  -> Surface message queue
```

decoder 维护跨 read 的 partial sequence，只在完整输入单元形成后发布。Kitty、legacy CSI
和 terminal capability 不进入 keymap。function key 在 KeyStroke 构造时规范化；Meta 是
真实 modifier，不拆成 ESC prefix。用户级 key translation 不属于 decoder 或 kernel。

```text
KeyStroke {
  key,
  codepoint?,
  modifiers,
}

KeyEvent {
  key,
  codepoint?,
  shifted_codepoint?,
  base_layout_codepoint?,
  modifiers,
  type: press | repeat | release,
  committed_text
}
```

decoder 保留协议报告的物理字段，host 在 keymap 查询前把 KeyEvent 规范化为
KeyStroke。功能键的协议私有 codepoint 不进入 KeyStroke；Shift 标点使用其逻辑字符并
移除冗余 Shift，字母的 Shift 保留。core 接受 frontend 已提交的 text，不拥有平台
IME。KeyEvent 可以同时携带未消费时可插入的 committed text，从而遵循与独立
text event 相同的契约。

### Keymap

Keymap 是一等、具名、可内省的 trie：

```text
Keymap {
  name,
  parent?,
  root: KeyTrie,
  remaps: CommandId -> CommandId
}

KeyTrieEntry = CommandBinding | PrefixNode | Tombstone
```

parent 在定义期显式声明。子 keymap 遮蔽父 keymap 的同一完整序列，未定义分支继承父
行为。parent 和具名 prefix 的环在注册时拒绝。

同一 keymap 中一个完整 key sequence 要么是 command，要么是 prefix，不使用 timeout
区分短命令和长映射。keymap 支持 prefix enumeration、where-is 和完整 resolver trace。

解析出 CommandId 后，resolver 按相同 layer 顺序执行一次 remap pass。remap 不递归，
也不修改原始 binding。

### Layer composition 与纯 resolver

聚焦 View 的有效 keymap layer 按以下优先级组装：

```text
0. override
1. transient InputState，栈顶在前
2. durable InputState
3. Window
4. View
5. Buffer
6. minor modes，逆激活顺序
7. major mode，包含 parent 链
8. editor.default
9. application.global
```

重复出现的同一 Keymap 只保留最高优先级的一次。minibuffer interaction 使用自己的
Window、View、Buffer 和 application.global 层，并省略被遮文档的层与 editor.default。

resolver 是无副作用函数：

```text
resolve-key-sequence(layers, complete_sequence)
  -> command(binding, source_layer, trace)
   | prefix(completions, participating_layers, trace)
   | unbound(trace)
```

每次都以完整 pending sequence 对每一层独立求值。高优先层的稀疏 prefix 不遮蔽低层的
其他续键；第一个识别同一完整序列的层仍然获胜。prefix completions 跨层合并。

pending key sequence 属于 View input session，保存原始 KeyStroke list 和 resolver trace，
不锁定到单一 prefix map，也没有 timeout。dispatch、which-key、describe-key、keymap
introspection 和测试使用同一个 resolver。

override 在 pending sequence 和 InputState handler 之前解析。`C-g` 始终可产生统一 quit
request。

### Per-View InputState

InputState 是输入姿态定义：

```text
InputStateDefinition {
  name,
  keymaps,
  handler?,
  text_input: accept | ignore,
  cursor_shape?,
  indicator?,
  on_enter?,
  on_exit?,
  position_hints?
}

InputStateStack {
  durable,
  transient: stack<InputStateSession>,
  pending_sequence?,
  pending_argument?,
  feedback?
}
```

每个 View 拥有独立 InputStateStack。栈底 durable state 始终存在；其上可以压入 keypad、
operator、read-key、query-replace 和其他 transient state。core 不认识 normal、insert、
motion 或 emacs 等具体 state 名称。

push、pop、durable replacement 和 View close 具有确定的 on-enter/on-exit 顺序并发布
ViewUpdate。压入新 transient state 只遮蔽旧 session，不结束旧 session。reset 弹出全部
transient state，保留 durable state，清除 pending sequence、argument 和 feedback。

top state handler 返回：

```text
pass
consume
dispatch(command_id, arguments)
pending(sequence, hints)
```

handler 返回 pass 后进入普通 layer resolver；dispatch 进入同一 command invocation 路径。
position hints 是对 BufferState、Selection 和 mode policy 的纯查询，结果作为 View
DecorationSet 发布。

major/minor mode 保持 Buffer scope，InputState 保持 View scope。mode Facet 可以声明
`editing` 或 `interface` interaction class；InputStrategy 将 interaction class 映射到 durable
state：

```text
InputStrategy {
  name,
  editing_state,
  interface_state
}
```

每个 View 可以选择策略或继承应用默认策略。mode configuration 改变时，host 为关联 View
重新推导 durable state，并保留仍然有效的 transient session。具体的 Emacs、Vim、Helix
或结构化编辑 state 由策略包定义。

keypad、operator 和 leader 是 transient handler state，不是 terminal translation。handler
可以调用同一个纯 resolver 查询 base layers，即 Window 至 application.global，并根据结果
dispatch、继续 pending 或透明 pass。这样 modal scheme 可以复用 mode-local keymap，而无需
为每种 mode 建立适配分支。

### Key 与 text 归一

KeyEvent 的处理规则固定为：

1. KeyStroke 先经过 override、top handler 和 keymap resolver。
2. command、prefix 或 consume 处理该键时，丢弃与它配对的 committed text。
3. 未消费且 durable state 的 text policy 为 accept 时，committed text 产生输入
   transaction。
4. TextInput 和 PasteInput 直接经过聚焦 state 的 text policy 与 input filter。

insert/emacs state 不需要为可打印字符建立 self-insert binding。normal/motion state 通过
keymap 消费可打印键，或以 text policy ignore 丢弃文本。paste 保留一个 transaction 和
一个 history grouping boundary。

### Pending argument 与 read-key

pending command argument 与 pending key sequence 是独立状态：

```text
PendingArgument {
  count?,
  register?,
  extra: immutable map,
  raw_sequence
}
```

prefix command 返回完整 replacement，不直接修改全局变量。下一条非 prefix command 将其
移动到 CommandContext 并清空。quit、undefined command 和 condition 都会清空 pending
argument。

`read-key` 是共享 transient InputState。它捕获一个规范 KeyStroke，先 pop session，再向
原 invocation 投递结果。register、character argument、Thing 和 keypad 复用该机制。

### Interaction 与 minibuffer

interaction 创建 transient Buffer、View 和 Window，并把它压入 Surface interaction
stack。focus 切换自然改变 active layers；minibuffer 复用普通 Selection、InputState、
editing command、transaction 和 undo/history package。

InteractionRequest 是数据：

```text
InteractionRequest {
  id,
  owner,
  origin_context,
  reader,
  prompt,
  initial_value?,
  completion_source?,
  selection_policy?,
  continuation_token
}
```

fixed candidate、free filename、yes/no 和 expression reader 属于 interaction/minibuffer
package。core 只管理 request identity、focus、suspend/resume/cancel 和 owner lifecycle。

## Command 与 command loop

### Command protocol

command definition 保持稳定且与具体 reader 解耦：

```text
CommandDefinition {
  name,
  invoke,
  documentation?,
  class?,
  interaction_spec?,
  owner
}
```

`invoke` 接受显式 Scheme 参数。`interaction_spec` 是 command package 可解释的声明式数据；
kernel 和 input resolver 只保存它，不实现具体参数读取规则。

```text
CommandContext {
  invocation_id,
  surface_id,
  window_id,
  view_id,
  buffer_id,
  buffer_state,
  view_state,
  event?,
  key_sequence,
  prefix_argument?,
  target,
  source
}
```

target resolver 在 invocation 开始时产生稳定 identity。异步恢复使用保存的 context
identity 重新解析对象，不从当前 focus 猜测目标。

command 可以返回 handled、TransactionSpec、HostOperation、InteractionRequest 或它们的
有序组合。I/O 通过 Effect 请求。普通 Scheme 调用可以直接调用显式参数入口；keymap 和
M-x 使用 interactive invocation。

### CommandInvocation

```text
CommandInvocation {
  id,
  definition,
  context,
  phase: resolving | reading | executing | completed | cancelled,
  interaction_id?,
  result?,
  condition_id?
}
```

interaction suspend 不依赖 Scheme 栈上递归调用。InteractionRequest 完成后向同一个
invocation 投递 resume message。target、prefix 和已读参数保留在 invocation 中。

pre/post hook、advice、repeat、command history 和 macro recording 通过 command lifecycle
Facet 或 package service 实现，不进入 command registry 的分支逻辑。

### Command loop

command loop 是 host dispatcher 的驱动器，而不是 editor state 的旁路所有者：

```text
poll native/frontend events
  -> enqueue messages
  -> process one bounded message or input unit
  -> start/resume CommandInvocation
  -> dispatch transactions and host operations
  -> run effects
  -> render dirty surfaces
  -> advance presenter
```

同一线程上的 command、runtime result 和 internal refresh 都经 dispatcher 提交状态。
recursive interaction 复用同一 message queue，只增加 interaction/invocation frame。

`C-g` 产生高优先级 quit request，依次取消当前 read-key、interaction、pending key sequence、
pending argument、step task 或 invocation，并回到最近的 command loop boundary。没有 pending
工作时，quit 只清理 View input session。

## Display 与 TUI frontend

### Display contribution

显示由 BufferState、ViewState 和 Facet contribution 派生：

```text
BufferState
  + ViewState
  + ContentPropertySet
  + DecorationSet facets
  + ViewPlugin decorations
  + theme facets
      -> DisplayStream
      -> layout
      -> Frame
```

Decoration 描述 face、replacement、virtual text、invisibility、widget attachment 和 layer。
Decoration 是 View/render state，不自动进入 history。需要随内容 undo 的显示语义保存在
ContentPropertySet，由 display provider 转换为 DecorationSet。

DisplayMap 保存 document offset、display cell 和 virtual content 之间的映射。cursor、hit
test、vertical motion、describe-char 和 source location 使用同一映射。renderer 按可见
range 使用 RangeSet cursor/sweep，不为每个 cell 扫描全部 decoration。

syntax highlighting、diagnostics、selection、completion preview、fold 和 inlay hint 都是
typed provider，不由 renderer 主动调用语言分析。

### Damage 与 ViewUpdate

EditorUpdate 和 HostUpdate 产生 typed damage：

```text
document | selection | viewport | decoration | chrome | layout | theme | resize
```

ViewPlugin 只在依赖的 state、facet 或 viewport 变化时更新。没有 display damage 时不创建
新 Frame。layout cache 的 key 至少包含 Buffer generation、View generation、viewport、
width、tab policy、wrap policy、display facet generation 和 theme generation。

### Frame 与 presenter

Frame 是终端尺寸的 immutable cell grid，包含 grapheme、cell width、resolved face 和 source
mapping。frame diff 合并连续变化 cell 为 row span，再选择连续输出、相对移动、
erase-to-end 或整行重绘。

presenter 维护：

```text
committed_frame
desired_frame
pending_write
terminal_frame_after_pending
```

未开始发送的旧 diff 可以被新 desired frame 替换。已经部分发送的 ANSI transaction 必须
完整结束，再从已知 terminal frame 重算。terminal backpressure 不复制和累积过期 frame。

terminal decoder、ANSI encoder、Kitty capability 和 libuv readiness 属于 TUI frontend；
DisplayStream、Frame 和 damage contract 不依赖终端协议。

## 标准功能包

标准发行版通过 package manifest 组合功能，不为标准包增加 host 特权：

```text
fundamental-editing
  motion / selection / kill-yank / history / mark / search / replace

files
  resource / VFS / modified+saved state / find-file / save

modes-and-settings
  major mode / minor mode / hook / advice / Compartment configuration

minibuffer-and-completion
  interaction readers / completing-read / candidate buffer / inline completion

result-buffer
  tabulated list / xref / diagnostics / grep / compilation / buffer list

language
  Scheme / Tree-sitter / C++ analysis / indentation / text objects

project-and-lsp
  workspace attachment / process / JSON-RPC / diagnostics / completion / xref

comint-and-repl
  process transcript / prompt fields / Scheme evaluator / history package

condition-debugger
  frame buffer / restart action / continuation inspector

dashboard
  Buffer, project, LSP, Git, diagnostic and task projections
```

history 是 StateField 和 transaction annotation 的标准包。file modified/saved revision 是
files package 的 StateField。major/minor mode 通过 Compartment 和 Facet 提供语言、keymap、
input class、indentation 和 display contribution。

Project 不是 Buffer、language 或 Scheme index 的隐式前提。LSP package 可以使用 Project
service 取得 workspace，也可以接收显式 root。Scheme environment 和编译索引属于 Scheme
package。

result-buffer 把领域 model 投影成普通文本以及 package-owned RangeSet。`n`/`p` 修改真实
Selection，preview 通过 DisplayRequest 显示 Location。xref、diagnostics、project search、
Git 和 debugger 共享 result navigation package。

comint 通过 ContentPropertySet 和 edit filter 表达 prompt、只读 transcript 和 editable
input field。普通 line motion、soft beginning、kill/yank、history 和 completion 仍通过标准
Selection、transaction 和 input pipeline 工作。

## Native、构建与分发边界

native 层提供窄 ABI：

- `soda_document`：Text、DocumentSnapshot、native transaction、anchor 和 change mapping；
- `soda_runtime`：libuv source、timer、filesystem、process 和 terminal readiness；
- `soda_tree_sitter`：Tree-sitter core 与 grammar loading；
- `soda_cpp_analysis`：C/C++ token、CST、结构和缩进。

editor kernel 只直接依赖 document ABI。Workbench host 使用 runtime ABI。TUI frontend 使用
terminal ABI。Tree-sitter、C++ analyzer 和其他 parser ABI 由语言 package wrapper 使用。

发行构建产生分层 image：

```text
Chez runtime boot
Soda editor kernel + workbench host boot
standard package boot
user/package vfasl archive
native launcher + runtime resources
```

C launcher 注册 native symbol 和 boot image，再进入 host startup。application trailer/TOC、
boot section、library visibility 和资源 archive 属于 packaging contract，见
[17-packaging.md](17-packaging.md)。这些机制不进入 editor state 或 command loop。

源码边界：

```text
scheme/soda/kernel/           editor state kernel
scheme/soda/host/             workbench host
scheme/soda/tui/              terminal frontend and presenter
scheme/soda/packages/base/    editing, files, modes, minibuffer
scheme/soda/packages/tools/   result buffers, project, dashboards
scheme/soda/packages/lang/    language and LSP adapters
scheme/soda/packages/repl/    comint, evaluator and debugger
src/                          native mechanisms and launcher
```

kernel 不导入 host、TUI 或 package namespace。host 不导入 TUI 或 package namespace。
构建系统对依赖方向执行静态检查。

## 接口与规模约束

- kernel library 只导出 immutable value、constructor、query 和 transaction operation；
- registry、owner、I/O、command 和 terminal 类型不进入 kernel；
- host service 只导出 protocol 和 identity，不暴露可变 table；
- package state 进入 StateField、ViewPlugin 或 package instance，不向 Buffer/View record
  添加功能字段；
- renderer、input、dispatcher 和 condition boundary 中不出现 package-specific branch；
- 一个功能包可以从 manifest 移除，而无需修改 kernel、host 或 TUI source；
- 单个底层 library 保持一个职责，不提供跨层 re-export facade；
- Soda kernel 与 host 的非生成 Scheme 源码保持在可独立审查的固定规模预算内，新增机制
  需要证明至少被两个相互独立的功能包共享。

## Contract tests

kernel contract tests 覆盖：

- ChangeSet apply、compose、invert 和 offset/range mapping；
- Selection 多 range 规范化、显式更新和跨 change mapping；
- StateField create/update/reconfigure、Facet combine/precedence 和 Compartment isolation；
- StateEffect 通过 ChangeDesc 映射和过期 start state 拒绝；
- RangeSet intersection、cursor、mapping 和边界 affinity；
- 同一 transaction 中 document、Selection 和 StateField 的原子 publication。

host contract tests 覆盖：

- 同一 Buffer 多 View 的 Selection、viewport、InputState 和 terminal cursor 独立；
- Buffer/View close、owner unload 和 configuration removal 不产生悬空 identity；
- Window tree、selected Window、active context 和 interaction focus 的一致性；
- keymap parent/remap、完整序列跨层解析和 resolver introspection 一致；
- per-View durable/transient InputState 生命周期与 key/text 归一；
- pending key sequence、pending argument、read-key、interaction 和 `C-g` 取消；
- command invocation suspend/resume 保持原 target 和 arguments；
- request identity、scope、generation、cancel 和 stale result retirement；
- condition、restart、continuation 和 command loop recovery；
- package activation/deactivation 的 StateField、Facet、ViewPlugin、task 和 native resource
  清理顺序。

TUI contract tests 覆盖：

- Kitty、CSI、UTF-8、paste 和跨 read partial sequence 解码；
- DisplayMap 的 document/display 双向映射；
- RangeSet sweep、viewport rendering、wide grapheme 和 virtual content；
- typed damage 与无变化时不生成 Frame；
- row-span diff、partial write、backpressure 和 desired frame replacement；
- headless frontend 与 terminal frontend 对同一 EditorUpdate 产生一致 display semantics。

标准包 contract tests 复用公共抽象：result-buffer 测试 xref、diagnostics、buffer-list 和
debugger；interaction 测试 M-x、find-file 和 completing-read；comint 测试 prompt field、
soft line boundary 和普通编辑命令组合。

## 实现依赖顺序

实现按依赖层建立：

1. kernel value、DocumentSnapshot、ChangeSet、Selection 和 RangeSet；
2. StateEffect、Annotation、StateField、Facet、Compartment、BufferState 和 ViewState；
3. Buffer/View registry、dispatch、EditorUpdate、owner 和 package contribution；
4. Window、Surface、active context、HostOperation 和 DisplayRequest；
5. 具名 keymap、纯 layer resolver、per-View InputState 和 command invocation；
6. runtime message、Effect、task、condition 和 command loop；
7. ViewPlugin、DisplayStream、DisplayMap、Frame 和 TUI presenter；
8. fundamental editing、history、files、modes、minibuffer 和 completion；
9. result-buffer、language、Project、LSP、comint、REPL、debugger 和 dashboard。

每一层只依赖已固定的下层协议。功能以 transaction、StateField、Facet、Selection 和
RangeSet 为接入点，不创建聚合 editor state、隐式 Project 或领域 renderer 分支。
