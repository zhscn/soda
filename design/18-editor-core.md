# Soda Core 与功能包

## 实现状态

| 能力 | 状态 |
|---|---|
| native `Text`、`Document`、terminal 与 libuv runtime | 已实现 |
| 精简的 Scheme core 与分层 boot image | 部分实现 |
| 统一的 Buffer、Extent、View 与 Window 模型 | 部分实现 |
| owner-scoped package、service 与资源生命周期 | 部分实现 |
| TUI Surface、selected Window 与 active context | 未实现 |
| character/byte Position、restriction 与 Buffer change bus | 未实现 |
| command loop、recursive invocation 与 command lifecycle | 未实现 |
| canonical terminal/input decoder | 未实现 |
| key translation/remap 与 declarative interactive spec | 未实现 |
| command target、prefix 与 interactive invocation | 部分实现 |
| request identity、取消和分步 task budget | 部分实现 |
| committed/desired frame 与 presenter transaction | 部分实现 |
| condition continuation 与 restart contract | 部分实现 |
| 基于普通 Buffer 的标准功能包 | 未实现 |

## 定位

Soda 由一个稳定、精简的编辑器内核和一组可独立装载的 Scheme 功能包组成。core
只提供承载编辑器所必需的机制：事件循环、文本 Buffer、View、Window、输入分发、
命令调用、显示投影、Frame 合成、终端提交以及扩展生命周期。

文件访问、minibuffer、补全、major mode、语言分析、Project、LSP、xref、REPL、
debugger、dashboard 和具体编辑命令属于功能包。标准 Soda 发行版只是 core 与一组
默认功能包的组合，不为这些功能增加内核特权。

Chez Scheme 是组合根和扩展语言。native 层提供 `Document`、libuv、terminal、
Tree-sitter core 和专用语言机制；native callback 只发布普通事件值，不保存 Scheme
对象，也不进入 Scheme 调用栈。

```text
native mechanisms
  Text / Document / terminal / libuv / parser ABI
                         │
                         ▼
Soda core
  runtime -> buffer -> view/window -> surface/context
                                  ├──> input/command loop
                                  └──> display/frame/presenter
                         │
                         ▼
owner-scoped services and packages
  editing / files / minibuffer / result-buffer / language / LSP / REPL / ...
```

## Core、功能包与构建层边界

Core 拥有跨功能包共享的机制：terminal service 的输入读取与 Kitty/ANSI 解码、
Surface 与 active context、command loop、command target/prefix/interactive invocation、
Buffer Position/restriction/change bus、request identity 与取消、分步 task 调度、
DisplayMap 到 Frame 的投影、frame diff、ANSI presenter transaction，以及 condition
boundary 与 restart 生命周期。它们只处理稳定的记录值、identity、所有权和状态转换，
不包含具体编辑策略或领域 UI。

功能包拥有基于这些机制组合出来的行为：基础编辑命令、file buffer、minibuffer 与
completion、major mode、Tree-sitter query、result buffer、xref、Project、LSP、
comint/REPL，以及 debugger 的 frame/restart 展示。它们可以注册 command、InputLayer、
service、display layer 和 condition handler；移除功能包不改变 core 的消息、Frame 或
terminal contract。

构建与分发层拥有应用打包的 trailer/TOC 容器、boot 注册、launcher 分派和运行时
library visibility contract test。这些内容验证可执行文件和 package archive 的组合，
不进入 editor state、command loop 或 renderer。具体容器格式和 library 可见性规则见
[17-packaging.md](17-packaging.md)。

## 内核不变量

core 保持以下不变量：

1. 所有可见内容都有 Buffer identity。
2. 每个 Buffer 都以 `Document` 文本作为公开、可搜索、可复制的内容投影。
3. 每个可见 cell 都映射到 Buffer 位置，或映射到附着于 Buffer 位置的虚拟内容。
4. point、viewport、selection 和瞬时输入状态属于 View；同一 Buffer 的多个 View
   共享文本，但不共享光标。
5. Window 只显示 View，不保存领域功能状态。
6. Surface 只保存 terminal surface、root Window、selected Window 和 active context；
   它不保存 Project、mode 或其他领域状态。
7. 功能包通过 Buffer transaction、Extent、command、service 和 display request
   组合，不直接修改终端、Window tree 或 Frame。
8. Document mutation、状态更新和 Frame publication 只发生在 editor thread。
9. 异步结果携带 owner、request identity 和 generation；过期结果在应用状态前退役。
10. package unload 会撤销该 owner 的注册项、任务、Extent、Buffer-local state 和资源。
11. renderer、input dispatcher 和 command loop 不按功能包名称分派。

这些规则使普通文件、xref 列表、诊断列表、debugger、REPL transcript、dashboard 和
completion candidates 共享相同的 Buffer、View、搜索、导航、复制、帮助和窗口行为。

## 依赖结构

core 使用单向依赖的 Scheme library，不提供聚合全部 API 的大 facade：

```text
(soda core value)
  identity, owner token, generation, range, condition values
        │
        ├──> (soda core runtime)
        │      message queue, effect, task and native event adapter
        │
        └──> (soda core document)
               native Text/Document wrapper
                     │
                     ▼
              (soda core buffer)
               Buffer, transaction, marker, extent, local state
                     │
                     ▼
              (soda core view)
               View, Window tree and placement primitive
                     │
                     ▼
              (soda core surface)
               terminal surface, selected context
                     │
              ┌──────┴──────┐
              ▼             ▼
       (soda core input)  (soda core display)
        event/keymap       display stream, layout, Frame
              │             │
              ▼             ▼
       (soda core command) (soda core terminal)

(soda core package)
  owner lifecycle, service registry and contribution transaction
  depends only on explicit core protocols
```

组合根 `(soda core startup)` 只创建这些 service 并进入 command loop。功能包不导入
startup，也不取得可任意修改的全局 Editor record；它们只接收 activation context 中
声明的 capability。

## Core state

core state 由多个所有权明确的 service 组成，而不是一个持续扩张的 Editor record：

```text
Core {
  runtime: RuntimeService,
  buffers: BufferService,
  views: ViewService,
  surface: SurfaceService,
  input: InputService,
  commands: CommandService,
  command_loop: CommandLoop,
  display: DisplayService,
  packages: PackageService,
  conditions: ConditionService
}
```

每个 service 只暴露操作协议和不可变查询值。跨 service 修改由 command loop 中的
显式 operation 协调。功能包状态保存在 package instance、Buffer-local cell 或
View-local cell 中，不通过向 Core 添加字段实现。

identity 由所属 service 分配且不复用。调用方跨 turn 保存 identity，查询时重新解析；
不长期保存可变 registry 内部对象。公开快照携带 generation，写操作通过 service API
推进 generation 和 damage。

## Buffer 是唯一的公开 UI 容器

### Buffer

core Buffer 只保存通用编辑器状态：

```text
Buffer {
  id,
  name,
  document,
  state: live | closing | closed,
  generation,
  edit_policy,
  local_cells: OwnerKey -> value,
  extents: ExtentIndex,
  input_layers,
  display_layers
}
```

resource、file path、major mode、language attachment、Project 和 process 属于拥有它们
的功能包，通过 Buffer-local cell 关联。core 不根据这些值决定 Buffer 生命周期或
显示方式。

Buffer-local cell 保留 `unbound` 与显式 `#f` 的区别，并由 owner 负责清理。settings 和
mode package 可以在其上实现 default value、buffer-local override、mode-local keymap
和 hook 变量；这些语义不通过向 Buffer record 添加固定字段实现。

### Position 与 restriction

编辑器 command、Marker、Extent 和 DisplayMap 使用字符位置；native Text、Tree-sitter
和文件 I/O 可以使用 byte position。两种坐标通过 Document 提供的显式转换操作关联，
任何跨层传递的 range 都声明其坐标系，不把 byte offset 当作通用 point。

```text
Position { document_id, character_offset, byte_offset? }
Range    { start: Position, end: Position }

Restriction {
  buffer_id,
  start: Marker,
  end: Marker,
  owner,
  state: narrowed | widened
}
```

Buffer 默认以完整 Document 作为 accessible range。restriction 改变搜索、point、region、
显示和普通 edit command 的可见边界；owner-scoped widen 可以恢复完整范围。限制范围与
Document 文本分离，因此 comint 的 editable boundary、read-only Extent 和普通 narrowing
可以同时存在。

Buffer transaction 是文本与公开区间元数据的原子发布边界：

```text
begin(buffer)
  -> edit Document pending text
  -> add/remove/update transactional extents
  -> commit
  -> BufferChange { old snapshot, new snapshot, changes, extent damage }
```

commit 也是 Buffer change bus 的发布点。core 按固定顺序向订阅者发送
`before-change`、Document mutation 和 `after-change`，事件携带 Buffer identity、旧/新
revision、affected range、origin、transaction identity 和 undo group。before-change
observer 可以拒绝违反 edit policy 的 mutation；after-change observer 只能通过新的
message 或 effect 安排工作，不能从回调直接进入下一层 command。订阅随 owner 一起撤销。

command loop 为每次 interactive invocation 建立 undo group；连续且声明兼容的命令可以
合并到同一 group。Buffer 保存 modified generation、saved revision 和当前 undo group
边界，undo/redo 同时恢复文本和 `content` Extent，不恢复 package-owned transient state。

普通文件编辑、generated buffer 刷新和结果列表更新使用同一 transaction。read-only
策略在 transaction 入口验证；拥有明确 capability 的内部刷新可以使用受 owner
约束的 internal transaction。

### Marker 与 Extent

`Marker` 是 Buffer 中带 affinity 的稳定位置。它包装 `DocumentAnchor`，并在 Buffer
关闭时失效。View point、mark、跳转位置和 Extent 边界都使用 Marker，不保存裸 byte
offset 作为跨 revision identity。

所有文本区间元数据使用同一种 `Extent`：

```text
Extent {
  id,
  owner,
  start: Marker,
  end: Marker,
  lifetime: content | buffer | view | transient,
  insertion_policy: front | rear | split,
  layer,
  priority,
  properties
}
```

properties 是 symbol-keyed immutable map。core 解释一组最小属性：

```text
face
display                 virtual text or replacement
invisible
read-only
keymap
action
semantic-id
source
```

`insertion_policy` 定义文本插入恰好位于 extent 边界时的归属；`front`、`rear` 和
`split` 分别对应向前扩展、向后扩展和在插入点分裂。它与 Marker affinity 分开：
Marker 决定位置本身的移动，Extent policy 决定区间元数据是否覆盖新文本。

功能包可以增加领域属性，例如 `result-item`、`location`、`diagnostic`、`frame` 或
`completion-candidate`。core 保留这些值并提供 range query，不理解其领域语义。

`content` Extent 与对应文本 mutation 一起进入 Buffer undo；`buffer` Extent 随
Buffer 存活；`view` Extent 属于某个 View；`transient` Extent 由 owner token 或输入
层关闭时统一释放。一个按 range 排序的 ExtentIndex 同时服务渲染、hit test、属性
查询和 `describe-char`，不再为 annotation、decoration、result property 和 display
replacement 建立彼此独立的区间容器。

### Generated Buffer

工具界面把领域 model 投影成普通 Buffer 文本和 Extent：

```text
model
  -> rows
  -> Buffer transaction {
       text,
       face extents,
       semantic-id extents,
       action/location extents
     }
```

文本是界面对编辑器公开的内容；领域 model 可以继续作为功能包的权威业务状态。
selection 使用稳定 `semantic-id` 恢复，command 通过 point 下的属性取得 payload，
不解析显示字符串。

统一的 `tabulated-list` 和 `result-buffer` 包在这一机制上提供列布局、group、标记、
next/previous、preview、refresh 和批量 action。xref、diagnostics、project search、
buffer list、Git、compilation 和 debugger 只提供 model、row projection 和 action。

## View、Window 与显示请求

### View

View 是某个 Buffer 的独立观察状态：

```text
View {
  id,
  buffer_id,
  point: Marker,
  viewport,
  input_layers,
  local_cells,
  view_extents,
  display_generation
}
```

mark ring、completion selection、search state、fold state 和 language provenance 可以
由各功能包保存在 View-local cell。core 只直接拥有 point、viewport、输入层和显示
失效状态。

每个 Window leaf 引用一个 View。只有 active Window 的 focused View 发布 terminal
cursor；其他 View 的 point 仍可绘制为普通装饰，但不会生成第二个 terminal cursor。

### Window

core Window service 只提供：

- leaf/split tree；
- active leaf 与 keyboard focus；
- View rectangle 分配；
- reserved slot 和 overlay anchor；
- display request 的原子应用。

Workbench、多套 layout、Project dashboard 和恢复策略属于功能包。minibuffer 可以使用
bottom reserved slot，completion 可以使用 anchored overlay，modeline 可以使用 Window
footer slot；core 不认识这些功能名称。

功能包通过数据请求显示 Buffer：

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

placement service 按 role 和当前 Window tree 产生计划。调用方不直接选择或修改 leaf，
异步结果也不抢占当前 focus，除非请求显式携带 focus policy。

### Surface 与 active context

TUI surface 是终端显示平面和编辑器活动上下文的拥有者，不等同于 GUI frame：

```text
Surface {
  id,
  terminal,
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
  recursive_depth,
  minibuffer_stack
}
```

surface service 保证 selected Window 是 root tree 中的 live leaf，并根据它解析
command 的默认 target、point、mark 和输入层。切换 Window、显示请求或进入 nested
interactive reader 都是 active context 的原子更新；异步结果不能通过修改 context
抢占焦点。headless host 可以创建没有 terminal writer 的 surface，以复用同一 command
和 render contract。

## 输入与命令

### InputEvent

terminal service 按以下阶段处理输入：

```text
terminal bytes
  -> Kitty/legacy/UTF-8 decoder
  -> terminal input translation
  -> canonical InputEvent
  -> key sequence resolver
  -> ordered InputLayer
  -> CommandInvocation or text action
```

decoder 维护跨 read 的 escape/paste 状态，只在一个完整序列结束后发布事件；不把
Kitty、legacy CSI 或终端 capability 泄漏给 keymap。translation layer 允许 terminal
profile 和用户把不同物理序列映射到同一个 canonical key，但不能把 text input 伪装成
command key。

```text
InputEvent {
  kind: key | text | paste | resize | pointer,
  value,
  modifiers,
  physical_key?,
  sequence,
  terminal_source?
}
```

`key` 的 value 是 canonical key identity，`text` 的 value 是已经完成的 Unicode 文本，
`paste` 保留完整输入边界。decoder 不查询 Buffer、package 或 keymap，也不把同一按键
同时发布为 key 和 text；无法解析的序列变成带 source 的输入错误事件，由 command loop
决定如何报告。

每个 View 持有有序 `InputLayer`：

```text
InputLayer {
  id,
  owner,
  keymap?,
  event_handler?,
  text_handler?,
  cursor_shape?,
  transient?,
  cancel?
}
```

buffer-local layers、View-local layers 和 terminal-global escape layer 使用同一解析器。
major/minor mode、minibuffer、completion、query replace 和应用对话框只是不同 owner
注册的 layer。`C-g` 产生统一 cancel 操作：从顶层 transient layer 开始调用 cancel，
再清除未完成 key sequence 和 prefix state。

Keymap 是具名、可继承的稀疏映射，值为 command call、prefix map、text action、command
remap 或 tombstone。resolver 按 terminal translation、global、major mode、minor
mode、buffer/view local 和 transient layer 的固定顺序查询，并返回完整 trace，供
dispatch、which-key、describe-key 和测试共享。command remap 改变 command identity 的
解析结果，不复制原始 key binding。

未完成的 prefix sequence 是 Surface-scoped input state，保存原始 key sequence、当前
prefix map、source layer 和 deadline；View 销毁、`C-g` 或 timeout 会统一清除它。无法
完成的 prefix 会把原始事件退回 unread queue 或产生明确的 undefined-key message，
不会静默丢弃输入。

### Command

core command definition 保持最小：

```text
CommandDefinition {
  name,
  invoke,
  interactive_spec?,
  documentation?,
  class?,
  owner
}
```

`invoke` 是接受明确 Scheme 参数的普通入口。`interactive_spec` 是描述 target、prefix
和参数 reader 的数据；Scheme command macro 在装载时把它编译成该记录，不把 reader
逻辑隐藏在任意 command procedure 中。minibuffer package 提供具体 reader、completion
和 prompt display，但 core 保存 invocation 的 suspension 和恢复状态。

keymap 和 M-x 创建 `CommandInvocation`，普通 Scheme 代码直接调用 `invoke`。一次交互
调用具有可观察的状态机：

```text
CommandInvocation {
  id,
  definition,
  context,
  phase: resolving | reading | executing | completed | cancelled,
  reader_continuation?,
  undo_group,
  result?
}
```

reader 可以在 `reading` 阶段挂起 command loop；输入返回后由同一 invocation 继续，
而不是重新猜测 target 或重新解析 prefix。`C-g` 将 invocation 标记为 cancelled，
清除其 transient InputLayer、reader continuation 和未完成 prefix。

CommandContext 包含 core identity 和本次调用的输入事实：

```text
CommandContext {
  core,
  target,
  view_id,
  buffer_id,
  event?,
  prefix_argument?,
  key_sequence,
  invocation_source
}
```

`target` 是由 core target resolver 解析的稳定 identity，而不是命令自行从当前全局状态
猜测的对象。target 可以是 core、Window、View、Buffer、region anchor 或 package-owned
entity；命令只通过 resolver 重新取得当前对象。`prefix_argument` 同时保留语义化值和
原始 key sequence，支持 universal argument、重复参数和 which-key trace。

交互调用分成解析 command definition、解析 target/prefix、读取参数和执行四个阶段。
command loop 在 invocation 开始和结束时发布 command lifecycle message，并以 invocation
identity 关联 Buffer change、undo group、effects 和 condition。pre/post hook、advice、
repeat、command history 和宏录制由 command-extensibility package 注册到这些生命周期
事件；core 不把它们实现成按功能名称分派的分支。

### Command loop

command loop 是唯一推进 Editor state 的执行器。它维护当前 turn 的不可变
`ActiveContext`、当前和上一条 command identity、prefix argument、unread event queue、
pending invocation stack 和 quit state；package procedure 不能绕过 loop 直接提交
Window、Frame 或 terminal mutation。

```text
poll terminal/native events
  -> decode and enqueue messages
  -> resolve one bounded key sequence
  -> start or resume CommandInvocation
  -> run update and publish BufferChange/effects
  -> render dirty surfaces
  -> presenter submits latest frame transaction
```

recursive interactive reader 使用同一个 loop 和 message queue，只增加
`recursive_depth` 与 invocation frame。`C-g` 是高优先级 quit request：它可以取消当前
reader、prefix、step task 或 command invocation，然后回到最近的可恢复 loop boundary。
没有 pending work 时，quit request 只清除输入状态而不产生隐式编辑。

## Message、effect 与异步任务

command loop 处理一种有目标的 message envelope：

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

target 可以是 core、Buffer、View、package instance 或 task。一次 turn 固定为：

```text
drain native events
  -> enqueue messages
  -> dispatch one bounded update batch
  -> execute returned effects
  -> render dirty Views
  -> submit latest desired Frame
```

effect 是由 owner 声明的普通值：

```text
Effect {
  kind,
  owner,
  scope,
  request_id?,
  generation,
  cancellation_key?,
  payload
}
```

每一个 effect 都可以产生一个 `Request`：

```text
Request {
  id,
  owner,
  scope,
  generation,
  cancellation_key?,
  state: pending | completed | cancelled | retired
}
```

request identity 与 owner、scope、generation 一起构成异步结果的接受条件。仅携带
generation 而没有 request identity 的结果不能区分同一 Buffer 上并行的两个请求。
相同 owner/scope/cancellation key 的新 request 会取消旧 request；scope 或 owner 关闭
时 request 进入 `cancelled`，已到达的结果进入 `retired`，不再调用 package procedure。

runtime adapter 按 kind 查找 handler。文件、目录、timer、process、socket 和 parser
任务由各自 package adapter 注册。core 只内建 terminal poll/write 和 command-loop
wakeup 所需的 adapter。

每个异步任务都有 owner token，并可选择 Buffer、View 或 package instance scope。
scope 销毁、owner unload、generation 变化或相同 cancellation key 被替换时，任务进入
cancelled；完成事件仍会被退役，但不再进入 package update。native callback 不调用
package procedure。

长计算使用分步 task。task 每次运行接收明确的 step budget，只能返回 `yield`、`done`
或 `cancelled`，并通过 runtime 在后续 turn 继续执行；task step 不得绕过 command loop
修改 Buffer 或 Window。Document 派生任务同时携带 document identity 与 revision。

## Package 与 service

### Package definition

功能包是一个无全局状态的定义：

```text
PackageDefinition {
  name,
  requires,
  provides,
  activate,
  deactivate?
}
```

PackageService 解析依赖，创建唯一 owner token，再调用 `activate`。ActivationContext
只含 package 声明的 core capability 和 required service。activation 返回 package
instance state；其他包只能通过 provides 中的 service interface 访问它。

service interface 是带具名 procedure 字段的 Scheme record。provider registry 属于
提供该 service 的 package，例如 xref package 拥有 XrefBackend registry，completion
package 拥有 CompletionSource registry。core 不预置这些领域 registry。

### Owner-scoped contribution

注册 API 返回 owner-scoped handle：

```text
register-command(owner, definition) -> Registration
register-keymap(owner, keymap)       -> Registration
register-service(owner, service)     -> Registration
register-effect(owner, handler)      -> Registration
register-face(owner, face)           -> Registration
```

activation 运行在 contribution transaction 中。失败时按逆序关闭已建立的 registration
和 resource；成功后由 PackageService 保存完整 handle 集合。unload 同样按逆序关闭，
不通过恢复整个 Editor configuration snapshot 或重新执行其他 package 实现撤销。

Buffer-local 和 View-local cell 使用 `(owner, key)` 作为身份。owner 关闭时，core 遍历
owner resource index，运行 cell cleanup、移除 Extent、pop InputLayer、取消 task 并
关闭 package 创建的临时 Buffer。

同名 package replacement 先在隔离 transaction 中激活新实例。新实例完整建立后再
切换 service bindings，并关闭旧 owner；失败时旧实例与 service identity 保持有效。

### 功能间通信

功能包通过明确 service 组合：

| consumer | service | provider 示例 |
|---|---|---|
| completion UI | completion source | Scheme、LSP、Buffer words |
| xref command | xref backend | Scheme index、LSP |
| diagnostics list | diagnostics store | parser、LSP、build |
| major mode | syntax service | delimiter、Tree-sitter、C++ analyzer |
| result buffer | location resolver | file、Buffer、remote resource |
| dashboard | project/Git/build service | 对应领域 package |

service request 和 response 是普通值，包含明确的 Buffer/View identity、revision 和
owner provenance。provider 不直接打开 Window，consumer 不读取 provider 私有 state。

## Condition 与 debugger 边界

core 在 message dispatch、command、package callback、display provider 和 effect result
入口建立 condition boundary。未处理 condition 被保存为：

```text
CapturedCondition {
  owner,
  origin,
  condition,
  continuation?,
  restarts,
  source_context,
  state: pending | dismissed | resumed
}

Restart {
  name,
  documentation?,
  invoke,
  owner
}
```

ConditionService 发布事件并保持 command loop 可用。debugger package 注册 condition
handler，把 condition、frame、restart 和 continuation action 投影成普通 Result
Buffer。debugger 不可用时，core 使用最小 emergency reporter 写入 stderr 和内部日志
Buffer；该 fallback 不依赖 minibuffer、theme 或 Window placement。

Condition boundary 在保存 condition 的同时捕获可恢复 continuation；恢复只能通过
owner-scoped `Restart` action 进入，dismiss 会使 continuation 和 restart 全部失效。
Chez continuation 的 inspector、frame 展示和 debugger UI 是 debugger service 的能力，
core 只保证捕获边界、所有权、一次性状态转换和生命周期。

## Display 与 terminal

### Display stream

renderer 只消费 Buffer snapshot、Extent cursor 和 View state：

```text
BufferSnapshot + ViewSnapshot
  -> ordered text/extent sweep
  -> DisplayElement stream
  -> line layout and wrap
  -> Window surface
  -> Frame compositor
  -> terminal presenter
```

DisplayElement 只有少量通用种类：

```text
TextSlice
VirtualText
Replacement
LineBreak
WidgetAttachment
```

WidgetAttachment 必须声明 Buffer source range、替代文本、尺寸、hit-test source 和
focus action。独立 TUI framework 可以作为 package 在此扩展点上构造复杂组件，但其
公开文本、导航位置和输入焦点仍附着于 Buffer，不建立第二种顶层 presentation。

syntax、diagnostic、selection、completion preview、fold 和 inlay hint 都发布 Extent
或 display layer。renderer 不调用语言分析，不扫描 package registry，也不保存领域
session。

### Theme 与 chrome

core face 是 interned semantic identity。Theme package 注册 `FaceSpec` 和 resolver；
没有 Theme package 时使用 terminal default style。modeline、line number、gutter、
minibuffer、popup 和 dashboard chrome 都是普通 display layer 或 reserved Window slot。

一次 render 使用不可变 snapshot，并按 dirty Buffer range、View state、Window layout、
face generation 和 terminal capability 计算 damage。presenter 只比较 Frame cell 和
cursor，合并 row spans，并维护单一提交事务：

```text
committed_frame  -> 已知完整写入终端的 frame
desired_frame    -> 最新发布的逻辑 frame
pending_write    -> committed_frame 到当前目标的 ANSI transaction
```

终端可写时 presenter 只继续 `pending_write` 的未发送部分；没有 pending write 或
dirty reason 时不产生输出，也不隐藏或恢复 cursor。终端阻塞期间，尚未开始发送的旧
目标可以由最新 `desired_frame` 替代；已经开始发送的 ANSI transaction 必须先完整写完，
然后以新的 committed frame 重新计算到最新目标的 diff。presenter 不把每个 cell 的
绝对定位作为唯一操作，而是优先提交连续 row span、相对移动、整行重绘或擦除操作。

所有 Frame cell 保存 source：

```text
CellSource {
  buffer_id,
  byte_position?,
  extent_ids,
  owner,
  semantic_id?
}
```

hit test、pointer routing、copy、describe-char 和 accessibility 消费该 source，不从
ANSI 或最终字符反推领域对象。

## 标准功能包

标准发行版按以下层次组合：

```text
core
├── fundamental-editing
├── files + vfs
├── modes + settings + command-extensibility
├── modeline + theme + help
├── minibuffer
│   └── completing-read
│       ├── candidate-list
│       └── inline-completion
├── result-buffer
│   ├── buffer-list
│   ├── xref
│   ├── diagnostics
│   ├── compilation
│   └── dashboard
├── language
│   ├── scheme-mode
│   ├── tree-sitter
│   └── cpp-analysis
├── project
│   └── LSP
├── comint
│   └── Scheme REPL
└── condition-debugger
```

包之间只依赖 service contract。Project 不是 Buffer、language 或 Scheme index 的隐式
前提；LSP 可以使用 Project service 取得 workspace，也可以由调用方提供显式 root。
SchemeEnvironment 和编译索引属于 Scheme package，不进入 core 或 Project service。

### Minibuffer 与补全

minibuffer 是显示在 bottom slot 的普通 Buffer 和 View。Prompt state 保存在
minibuffer package，输入通过 View InputLayer 路由。completing-read 把候选投影到一个
candidate Buffer；selection 是 View-local Extent。fixed candidate、free filename 和
inline composition 是 completion package 的 selection policy，不改变 core focus。

### Xref、诊断和搜索

producer 返回 Location 值。result-buffer package 把 LocationList 投影为带
`result-item`、`location`、`group` 和 `action` Extent 的普通 Buffer。`n`/`p` 修改结果
View 的真实 point，preview 通过 DisplayRequest 更新 source View。diagnostics、grep、
xref 和 compilation 共用这一机制。

### REPL 与 debugger

comint transcript 是普通可编辑边界受限的 Buffer；prompt 区间、只读历史和 process
identity 使用 Extent 与 Buffer-local cell。Scheme REPL 在 comint service 上增加 Chez
evaluator。debugger 使用 result-buffer 显示 frame 和 action，continuation 保存为
owner-scoped payload。

### Dashboard 与 TUI package

dashboard 是 generated Buffer，由 tabulated-list、result-buffer 和领域 service
组成。Bubble Tea 风格 package 可以保留 Model/Message/Update，但每次 Model publication
同时产生 Buffer text、Extent 和可选 WidgetAttachment；Window、input、Frame 和
terminal 生命周期仍由 core 持有。

## Native 与构建边界

native 机制按窄 ABI 复用：

- `soda_document`：Text、Document、snapshot、transaction、anchor 和 undo；
- `soda_runtime`：libuv source、timer、filesystem、process 和 terminal readiness；
- `soda_tree_sitter`：Tree-sitter core 与 grammar loading；
- `soda_cpp_analysis`：C/C++ token、CST、结构和缩进。

core 只直接依赖 document、terminal 和 runtime ABI。Tree-sitter、C++ analyzer 与其他
parser ABI 由语言 package wrapper 使用。

发行构建产生分层 image：

```text
Chez runtime boot
Soda core boot
standard package boot
user/package vfasl archive
native launcher + runtime resources
```

C launcher 注册 native symbols 和 boot image，再进入 `(soda core startup)`。standard
package manifest 决定发行版功能集合；增加或移除 Scheme package 不修改 launcher 或
core boot。开发环境可以从目录加载编译后的 package vfasl，发行版把同一制品嵌入或
安装到 package archive。

源码按以下边界布局：

```text
scheme/soda/core/             stable core libraries
scheme/soda/packages/base/    default editing and UI packages
scheme/soda/packages/tools/   result buffers, project and dashboards
scheme/soda/packages/lang/    language providers and LSP adapters
scheme/soda/packages/repl/    comint, evaluator and debugger
src/                          reusable native mechanisms and launcher
```

core 不导入 `scheme/soda/packages`。构建系统对该依赖方向执行静态检查。

## 规模与接口约束

core 使用明确的规模预算：

- Scheme core 非生成源码保持在 15 KLOC 以内；
- 单个 core library 保持在 1,500 行以内；
- core library 只导出该领域的协议，不提供全量 re-export facade；
- core record 新增字段需要属于其固定职责，package state 使用 owner-local cell；
- renderer、input 和 event loop 中不出现 package-specific branch；
- 一个功能包可以从 manifest 移除，而无需修改或重新编译 core source。

规模预算是依赖边界的可执行约束。超过预算时先拆分职责或把策略移入 package，不通过
扩大 core facade 维持调用方便。

## 验证契约

core 提供 headless host，以 message、Buffer snapshot、View snapshot 和 Frame 作为
测试输入输出。核心契约测试覆盖：

- transaction、Marker 和 Extent 在 undo/redo 与跨 revision 编辑后的正确性；
- 同一 Buffer 多 View 的 point、viewport 和 terminal cursor 独立性；
- Surface 的 root/selected Window、active context 和 nested invocation 不产生悬空或
  重复 focus；
- character/byte Position 的双向转换、restriction 边界和 owner-scoped widen；
- before/after change 的顺序、Buffer change bus 的退订、modified/save revision 与 undo
  group 的合并边界；
- owner unload 后 registration、task、Extent、InputLayer 和 local cell 完整释放；
- Kitty、legacy CSI、UTF-8、bracketed paste 以及跨 read 的 partial sequence 归一化为
  唯一 InputEvent；
- terminal translation、keymap precedence、command remap、prefix sequence 和 unread
  event 的生命周期；
- declarative interactive spec 产生的 target/prefix/reader 参数顺序，以及 invocation
  suspend/resume/cancel 状态；
- command loop 的 pre/update/post/render 顺序、recursive reader 和高优先级 `C-g`；
- request identity、scope、generation、cancellation 以及 stale result 退役，且不调用
  package procedure；
- 分步 task 在每个 step budget 后 yield，并在取消或 owner unload 后停止；
- generated Buffer 的 search、copy、result navigation 和 action 属性一致；
- renderer 只消费 published snapshot，Frame cell 均具有可追溯 source；
- presenter 在 partial write、terminal backpressure 和 desired frame 替换时保持
  committed frame 一致，且无 dirty 时不提交 ANSI；
- condition 捕获、restart invoke、dismiss、owner unload 与 command loop 恢复之间的
  一次性状态转换；
- package callback condition 不终止 command loop；
- core import graph 无环且不依赖 package namespace。

标准包另有独立 contract test。xref、diagnostics、buffer-list 和 debugger 必须通过同一
result-buffer 测试套件；minibuffer 和 inline completion 必须通过同一 InputLayer、
focus 与 candidate Buffer 契约。

## 构建顺序

实现按可独立运行的依赖层建立：

1. headless runtime、terminal service、owner token、message/effect 和 condition boundary；
2. Document Position 转换、Buffer transaction、Marker、Extent、restriction、change bus
   和 undo group；
3. View、Window、Surface、active context、DisplayElement、Frame 与 terminal presenter；
4. Input decoder/translation、InputLayer、keymap、command invocation 和 command loop；
5. fundamental-editing、files、modeline 和 theme；
6. generated/result Buffer、minibuffer 与 completion；
7. language、Project、LSP、comint、REPL、debugger 和 dashboard。

每一层只依赖已经固定的下层协议。native 机制和纯算法可以直接作为 package dependency；
依赖聚合 Editor state、领域 renderer 分支或隐式 Project 的实现不进入 core。兼容行为
由标准 package 提供，不在 core 中增加双路径或旧 API shim。
