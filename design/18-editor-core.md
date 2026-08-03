# Soda Core 与功能包

## 实现状态

| 能力 | 状态 |
|---|---|
| native `Text`、`Document`、terminal 与 libuv runtime | 已实现 |
| 精简的 Scheme core 与分层 boot image | 部分实现 |
| 统一的 Buffer、Extent、View 与 Window 模型 | 部分实现 |
| owner-scoped package、service 与资源生命周期 | 部分实现 |
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
  runtime -> buffer -> view/window -> input/command -> display/frame
                         │
                         ▼
owner-scoped services and packages
  editing / files / minibuffer / result-buffer / language / LSP / REPL / ...
```

## 内核不变量

core 保持以下不变量：

1. 所有可见内容都有 Buffer identity。
2. 每个 Buffer 都以 `Document` 文本作为公开、可搜索、可复制的内容投影。
3. 每个可见 cell 都映射到 Buffer 位置，或映射到附着于 Buffer 位置的虚拟内容。
4. point、viewport、selection 和瞬时输入状态属于 View；同一 Buffer 的多个 View
   共享文本，但不共享光标。
5. Window 只显示 View，不保存领域功能状态。
6. 功能包通过 Buffer transaction、Extent、command、service 和 display request
   组合，不直接修改终端、Window tree 或 Frame。
7. Document mutation、状态更新和 Frame publication 只发生在 editor thread。
8. 异步结果携带 owner、request identity 和 generation；过期结果在应用状态前退役。
9. package unload 会撤销该 owner 的注册项、任务、Extent、Buffer-local state 和资源。
10. renderer、input dispatcher 和 command loop 不按功能包名称分派。

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
               View, Window tree, focus and placement primitive
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
  input: InputService,
  commands: CommandService,
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

Buffer transaction 是文本与公开区间元数据的原子发布边界：

```text
begin(buffer)
  -> edit Document pending text
  -> add/remove/update transactional extents
  -> commit
  -> BufferChange { old snapshot, new snapshot, changes, extent damage }
```

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

## 输入与命令

### InputEvent

terminal decoder 把 Kitty、legacy CSI、UTF-8 和 bracketed paste 归一为 `KeyEvent`、
`TextInputEvent`、`PasteEvent`、`ResizeEvent` 和 pointer event。decoder 不查询 Buffer、
package 或 keymap。

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

Keymap 是具名、可继承的稀疏映射，值为 command call、prefix map、text action 或
tombstone。解析器返回完整 trace，供 dispatch、which-key、describe-key 和测试共享。

### Command

core command definition 保持最小：

```text
CommandDefinition {
  name,
  invoke,
  interactive_invoke?,
  documentation?,
  class?,
  owner
}
```

`invoke` 是接受明确 Scheme 参数的普通入口。`interactive_invoke` 是已经编译好的交互
入口；core 不保存 minibuffer reader plan，也不持有递归 command loop。interactive
功能包提供 `define-command` 和 typed reader 宏，把参数读取编译成显式 continuation，
并由 minibuffer 包保存 suspension。

keymap 和 M-x 调用 `interactive_invoke`。普通 Scheme 代码直接调用 `invoke`。
CommandContext 只包含 core identity 和输入事实：

```text
CommandContext {
  core,
  view_id,
  buffer_id,
  event?,
  prefix?,
  invocation_source
}
```

命令通过 service API 修改状态并返回 effect。pre/post hook、advice、repeat、command
history 和宏录制由 command-extensibility 包围绕 command service 注册，不扩张 core
invocation record。

## Message、effect 与异步任务

command loop 处理一种有目标的 message envelope：

```text
Message {
  target,
  owner,
  generation,
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
  cancellation_key?,
  payload
}
```

runtime adapter 按 kind 查找 handler。文件、目录、timer、process、socket 和 parser
任务由各自 package adapter 注册。core 只内建 terminal poll/write 和 command-loop
wakeup 所需的 adapter。

每个异步任务都有 owner token，并可选择 Buffer、View 或 package instance scope。
scope 销毁、owner unload、generation 变化或相同 cancellation key 被替换时，任务进入
cancelled；完成事件仍会被退役，但不再进入 package update。native callback 不调用
package procedure。

长计算使用分步 task。每一步有明确 budget，返回 continuation datum 和下一条 effect；
Document 派生任务同时携带 document identity 与 revision。

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
  source_context,
  timestamp
}
```

ConditionService 发布事件并保持 command loop 可用。debugger package 注册 condition
handler，把 condition、frame、restart 和 continuation action 投影成普通 Result
Buffer。debugger 不可用时，core 使用最小 emergency reporter 写入 stderr 和内部日志
Buffer；该 fallback 不依赖 minibuffer、theme 或 Window placement。

Chez continuation 和 restart 是 debugger service 的能力。core 只保证捕获边界、所有权
和生命周期，不实现 debugger 界面。

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
cursor，合并 row spans，并维护 committed Frame、desired Frame 与 partial-write suffix。

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
- owner unload 后 registration、task、Extent、InputLayer 和 local cell 完整释放；
- stale async result 退役且不调用 package procedure；
- generated Buffer 的 search、copy、result navigation 和 action 属性一致；
- renderer 只消费 published snapshot，Frame cell 均具有可追溯 source；
- package callback condition 不终止 command loop；
- core import graph 无环且不依赖 package namespace。

标准包另有独立 contract test。xref、diagnostics、buffer-list 和 debugger 必须通过同一
result-buffer 测试套件；minibuffer 和 inline completion 必须通过同一 InputLayer、
focus 与 candidate Buffer 契约。

## 构建顺序

实现按可独立运行的依赖层建立：

1. headless runtime、owner token、message/effect 和 condition boundary；
2. Document wrapper、Buffer transaction、Marker、Extent 和 undo；
3. View、Window、DisplayElement、Frame 与 terminal presenter；
4. InputLayer、keymap、command 和 package/service lifecycle；
5. fundamental-editing、files、modeline 和 theme；
6. generated/result Buffer、minibuffer 与 completion；
7. language、Project、LSP、comint、REPL、debugger 和 dashboard。

每一层只依赖已经固定的下层协议。native 机制和纯算法可以直接作为 package dependency；
依赖聚合 Editor state、领域 renderer 分支或隐式 Project 的实现不进入 core。兼容行为
由标准 package 提供，不在 core 中增加双路径或旧 API shim。
