# TUI Application Framework

## 定位

Soda 同时提供文本编辑器和可嵌入 Workbench 的 TUI application framework。TUI
application 以 Buffer 作为公开身份，以 Window 中的 View rectangle 作为显示区域，
并复用编辑器的 command loop、effect runtime、keymap、theme、minibuffer、
modeline、异常边界和 display placement。

TUI application 不拥有终端。raw mode、alternate screen、Kitty keyboard protocol、
bracketed paste、terminal cursor、输出队列和 ANSI presenter 由 Soda TUI host 统一
管理。一个 application 可以显示在任意 Window leaf 中，与普通文本 Buffer、
minibuffer、completion popup 和其他 application 同时存在。

框架使用 Elm/Bubble Tea 风格的数据流：

```text
Init(context) -> Model + Commands

Message
  -> Update(Model, Message, context)
  -> Model + Commands
  -> View(Model, view-context)
  -> TuiNode
  -> layout + paint
  -> Window rectangle in Frame
```

应用状态是独立的 `TuiSession`，不是 Document 文本。Buffer 提供 Workbench identity
和编辑器能力边界；TuiSession 提供应用运行时；每个显示该 Buffer 的 View 另有
per-view 状态。

## Buffer presentation

每个 Buffer 声明一种 presentation：

```text
BufferPresentation =
    DocumentPresentation
  | TuiPresentation { session_id }
```

`DocumentPresentation` 使用 Text、Document snapshot、selection、decoration 和
DisplayMap 绘制正文。`TuiPresentation` 使用 TuiSession 的 `view` procedure 绘制
结构化界面。

TUI Buffer 仍持有一个内部 Document，以维持 Buffer、View anchor 和通用 API 的
统一不变量。该 Document 保存应用发布的可选文本投影，不保存应用 Model。内部投影
更新不进入用户编辑事务，Buffer 使用：

```text
track-modified? = false
read-only?      = true
interaction-class = interface
```

因此应用的选择、展开、排序、请求状态和组件焦点不会污染 Document undo，也不会触发
保存确认。需要真正编辑文本的组件通过普通 document Buffer、minibuffer 或显式
editable child session 承载。

TUI Buffer 自动参与：

- Buffer registry、MRU、switch-buffer 与 Buffer list；
- Window split、display intent、tools/doc/jump slot 与 Workbench layout；
- major/minor mode、keymap、hook、advice、setting 与用户配置；
- modeline、theme、minibuffer、completion 与帮助系统；
- command/effect 序列化、异常捕获和 Scheme debugger；
- Buffer close、Editor close 与 session persistence。

Project 不拥有 TuiSession。应用可以显式使用 Project root、VFS、language session
或 build service，也可以作为无 Project 的全局工具运行。

## Application definition

Editor 持有按名字索引的 `TuiApplicationCatalog`。定义是无运行状态的构造契约：

```text
TuiApplicationDefinition {
  name,
  init,
  update,
  view,
  close?,
  text_projection?,
  default_mode,
  default_display_intent,
  capabilities
}
```

- `init` 创建初始 Model，并可返回初始化 commands；
- `update` 是唯一改变 Model 的入口；
- `view` 是无副作用投影，同一个 Model 和 view context 产生等价的 TuiNode；
- `close` 释放由应用持有、但不属于 effect runtime 的资源；
- `text_projection` 产生可复制、可搜索和可测试的纯文本快照；
- `default_mode` 提供 application keymap、interaction class 和 Buffer settings；
- `capabilities` 声明应用使用的 runtime service。

应用定义可由内建 Scheme library、用户配置或插件注册。重载定义只影响后续创建的
session；正在运行的 session 保持其 definition identity，显式 reload command
负责状态迁移。

## Session、Model 与 View state

一个打开的应用对应一个 `TuiSession`：

```text
TuiSession {
  id,
  definition,
  buffer_id,
  model,
  generation,
  command_generation,
  view_states: ViewId -> TuiViewState,
  pending_commands,
  state: initializing | ready | failed | closed
}
```

Model 是 Buffer 级共享状态。同一个 TUI Buffer 显示在多个 Window 时，各 View
看到相同的业务数据。viewport、局部 focus 和 geometry 属于 `TuiViewState`：

```text
TuiViewState {
  view_id,
  width,
  height,
  focused?,
  focused_node?,
  viewport,
  transient_state,
  cursor?
}
```

常见的共享状态包括数据集合、筛选条件、排序规则、加载状态和领域 selection。
per-view 状态包括可见范围、组件焦点、hover、局部滚动位置和光标形状。应用可以把
某项选择声明为共享或 per-view，但该所有权必须由 Model 明确表达，不能从 Window
数量推导。

关闭 View 只移除对应 TuiViewState。关闭 Buffer 关闭 TuiSession，取消其 pending
commands，并运行 definition 的 close procedure。切换 Buffer、删除 Window 或切换
Workbench 不关闭全局 Buffer，因此 session 和尚未显示的 view state 按普通 Buffer
生命周期保留。关闭 Editor 按 session registry 顺序关闭所有 application。

## Message

所有应用事件统一表示为目标明确的 `TuiMessage`：

```text
TuiMessage {
  session_id,
  session_generation,
  origin_view_id?,
  payload
}
```

内建 payload 包括：

```text
TuiInit
TuiKeyPress       { key_event }
TuiKeyRelease     { key_event }
TuiTextInput      { bytes }
TuiPaste          { bytes }
TuiFocus          { view_id }
TuiBlur           { view_id }
TuiResize         { view_id, width, height }
TuiCommandResult  { command_id, result }
TuiTimer          { timer_id, instant }
TuiUserMessage    { datum }
TuiClose
```

terminal decoder 只产生规范 InputEvent。TUI framework 在焦点和 session identity
确定后构造 TuiMessage。外部 runtime 和其他 Scheme 代码也只能通过 TuiMessage
投递应用事件，不能直接调用应用 update。

消息进入 Editor command loop，与文件读取、补全响应和 REPL result 使用相同的串行
更新边界。应用 update 返回：

```text
TuiUpdateResult {
  model,
  commands,
  view_actions
}
```

`view_actions` 只描述 focus、scroll、cursor 和 overlay 等 View 状态改变。更新完成
后，session generation 前进，相关 View 以 `application` dirty reason 失效。
update 中抛出的 `editor-user-error` 成为 status message；其他 condition 进入 Soda
debugger，command loop 保持可用，session 进入 `failed`。debugger 的 retry 可以
重放产生失败的 TuiMessage。

## Command 与异步 effect

`TuiCommand` 描述一次 effect，不执行 effect：

```text
TuiCommand {
  id,
  kind,
  payload,
  scope: session | view,
  origin_view_id?,
  generation,
  cancellation_key?
}
```

应用 update 可以返回零个或多个 command。框架把 command 转换为普通
`command-effect`，由已注册的 effect handler 执行。文件、目录、timer、process、
build、language service 和其他 libuv 操作均沿用这一入口。

effect 完成后产生 `TuiCommandResult`。应用结果前必须验证：

- session 仍存在且未关闭；
- result 的 session generation 与 command contract 兼容；
- view-scoped command 的 origin View 仍存在；
- cancellation key 没有被更新的 command 取代；
- 携带 Document resource/revision 的结果仍满足其专用 revision contract。

并发 commands 不保证完成顺序。需要顺序的工作流由 update 在收到前一个 result 后
返回下一个 command。`batch` 只表示无顺序依赖的并发集合；`sequence` 把 commands
变成逐 result 推进的显式状态机。

应用不能阻塞 command loop 等待 I/O，也不能递归调用 `editor-update!`。纯计算若
不能在单次 command budget 内完成，使用分块 command 和 continuation datum 在多次
message 中推进。

## 完整输入管线

### 终端归一

输入共用编辑器的单一终端管线：

```text
terminal bytes
  -> incremental Kitty/legacy decoder
  -> InputEvent
  -> focused View
  -> Editor override
  -> InputState handler
  -> layered keymap
  -> application or editor command
```

规范输入只有两类：

```text
KeyEvent {
  key,
  codepoint,
  shifted_codepoint,
  base_layout_codepoint,
  modifiers,
  type: press | repeat | release,
  text
}

TextInputEvent {
  kind: text | paste,
  text
}
```

decoder 处理 Kitty `CSI u`、legacy CSI/SS3、UTF-8、控制字符、Escape timeout 和
bracketed paste。decoder 不查询 Buffer presentation，不运行应用代码，也不把粘贴
内容解释成按键序列。

### 焦点所有权

Editor 始终只有一个 keyboard focus owner：

```text
active Prompt View
  or active Window leaf's View
```

minibuffer 活动时，Prompt View 完全拥有输入；被遮住的 application 不收到 key、
text、paste 或 focus message。prompt 关闭后，active Window View 重新获得 focus，
application 收到 `TuiFocus`。

Window 切换、Buffer 替换、Workbench 切换和 prompt 打开/关闭产生配对的
`TuiBlur`/`TuiFocus`。重复选择同一 View 不重复发送 focus 消息。resize 针对每个
可见 application View 发送局部 rectangle 的 width/height，而不是 terminal 总尺寸。

### InputState

InputState 是 per-view 栈，完整形式为：

```text
InputState {
  name,
  keymap_layers,
  text_policy: accept | ignore | application,
  text_command?,
  handler?,
  cursor: beam | block | underline | hidden,
  indicator?,
  on_enter?,
  on_exit?
}
```

栈底是 durable state，栈顶可以包含 prompt、单键捕获、operator、query decision、
应用 dialog 和其他 transient state。状态生命周期由栈成员身份定义：

- push 完成后调用 `on_enter`；
- pop、durable replacement 和 View close 在移除后调用 `on_exit`；
- 上层 transient 遮蔽下层 state，但不结束被遮 state；
- View close 从栈顶向栈底运行退出流程；
- `keyboard.quit` 清空 transient state，保留 durable state。

`editing` major mode 通常使用接受文本的 durable state。`interface` major mode
通常使用 `application` text policy 和 application input handler。同一 Buffer 的
两个 View 可以具有不同 transient stack 和 focused component。

### 输入分发优先级

一次 KeyEvent 按以下顺序解析：

```text
0. Editor override keymap
1. active Prompt View（存在时终止后续 application 分发）
2. InputState transient handlers，栈顶在前
3. durable InputState handler
4. InputState keymap layers，栈顶在前
5. View keymap layers
6. active minor modes，逆激活顺序
7. major mode 与 parent keymaps
8. Editor default keymap
9. 未消费文本策略
```

Editor override 保存不可遮蔽的逃生和 host control bindings。`C-g` 至少清除
pending key sequence、prefix argument、completion、prompt、应用 transient state
和 handler pending feedback。应用、major mode tombstone 和 focused component
都不能覆盖 Editor override。

TUI application 的 durable handler 位于 application mode keymap 之前，因此应用
可以像 Bubble Tea Update 一样查看规范 KeyEvent。它对希望留给 Workbench 的键返回
`pass`，例如 `C-x` prefix、`M-x`、Buffer/Window 切换和帮助键。应用定义可以提供
`host_passthrough_keymaps`，由共享 helper 使用同一个 keymap resolver 判断某序列
是否应穿透，不需要手写控制键列表。

### Handler contract

InputState handler 是无终端副作用的过程：

```text
handle(event, input-context) -> InputDisposition
```

`input-context` 包含：

```text
editor_id
workbench_id
window_id
view_id
buffer_id
presentation
input_state_stack
pending_sequence
prefix_argument?
application_session_id?
focused_node?
```

返回值为：

```text
Pass
Consume
DispatchCommand { name, argument? }
DispatchApplication { payload }
Pending { sequence, hints, continuation }
```

- `Pass` 继续下一个 handler 或 keymap 层；
- `Consume` 结束该事件，不产生 command；
- `DispatchCommand` 退出输入解析并通过普通 command registry 调用命令；
- `DispatchApplication` 构造目标 TuiMessage，调用一次 application update；
- `Pending` 消费当前事件并保存规范 sequence、帮助 hints 和 continuation。

handler 不直接改变 Buffer、Model、View 或 Frame。`DispatchApplication` 的 Model
改变仍由 update 完成；`DispatchCommand` 仍经过 interactive command、hook、
advice、prefix 和异常边界。handler condition 被捕获为 scripting/debugger
condition，并消费当前事件，不能越过 terminal poll loop。

`Pending` 属于产生它的 InputState。state pop、View blur、`keyboard.quit` 或下一个
不匹配事件使 pending 失效。pending hints 使用与 prefix/which-key 相同的 overlay
通道。

### Keymap 与 prefix

keymap 仍是一等具名稀疏树，definition 为 command、prefix、undefined 或 parent
fallback。application major mode 可以把稳定操作声明为普通 editor command：

```text
n       -> package.next
p       -> package.previous
RET     -> package.visit
g       -> package.refresh
```

这类命令可被用户重绑定、describe、where-is、hook 和 advice。需要完整原始事件或
组件内部路由的输入由 application handler 接收。两条路径最终都产生 TuiMessage，
不会各自修改 Model。

prefix argument 保存在 Editor pending slot。`DispatchCommand` 取得并消费 prefix；
`DispatchApplication` 把 prefix 作为 message metadata 传入 update。`Pass` 不消费
prefix。未定义序列、取消、handler error 和应用拒绝带 prefix 的操作清除 pending
prefix，并按普通 Editor 规则设置 status。

### Key 与文本提交

KeyEvent 始终先经过 handler 和 keymap。框架保证一个物理输入只提交一次文本：

1. handler 或 keymap 消费 KeyEvent 时，`KeyEvent.text` 不再形成文本提交；
2. KeyEvent 未消费且当前 state 的 text policy 为 `accept` 时，文本交给
   `text_command`；
3. KeyEvent 未消费且 text policy 为 `application` 时，非空文本成为一个
   `TuiTextInput`；
4. text policy 为 `ignore` 时丢弃未消费文本；
5. 独立 TextInputEvent 清除 pending key sequence，并按同一 text policy 原子提交；
6. `paste` 始终作为一个 `TuiPaste` 或一次 text command 调用，不拆成 KeyEvent。

TUI application 的文本组件使用 `application` policy。组件收到 `TuiTextInput`
后更新 Model；它不直接写内部 Document。需要 Emacs 式编辑命令、undo、kill ring
和 completion 的输入框使用 PromptSession 或真正的 editable child Buffer，而不是
在 widget 中重新实现文本编辑器。

### Application 内部 focus

TuiViewState 保存 `focused_node`。TuiNode 通过稳定 key 声明 `focusable?`、focus
group 和 tab order。layout 完成后产生可见 focus ring：

```text
FocusEntry {
  node_key,
  rect,
  order,
  enabled?
}
```

应用 update 处理 Tab、Backtab、方向导航或自定义消息，并通过 view action 改变
focused node。节点消失或 disabled 时，框架按同组下一个可用节点、父 focus scope、
无 focus 的顺序回退。focus identity 使用 node key，不使用上一次 frame 的坐标。

focused component 不直接接收 terminal bytes。application update 根据
`origin_view_id` 和 `focused_node` 把 TuiKeyPress、TuiTextInput 与 TuiPaste 路由给
组件 update。父应用先决定 host passthrough、全局快捷键和 modal state，再委派给
focused component。

### Mouse 与坐标输入

mouse support 使用同一 focus 和 message 模型。terminal host 把 mouse event 归一为
screen cell；Frame layout 用 component path 和 Window rectangle 转换为：

```text
TuiPointer {
  view_id,
  node_key?,
  local_row,
  local_column,
  button,
  modifiers,
  type
}
```

应用只看到自身 rectangle 内的局部坐标。pointer capture 绑定到 session、View 和
node key，在 release、View blur、node 消失或 `keyboard.quit` 时释放。应用声明
mouse capability 后，host 才把相关事件路由给它；terminal mouse mode 仍由整个
Workbench 的 capability aggregate 决定。

### 可重放性

规范 InputEvent、TuiMessage、TuiCommand 和 generation 都是数据。headless 测试直接
投递消息并比较 Model、commands、TuiNode 和文本投影。宏录制记录 editor command
invocation；应用专用回放记录 TuiMessage payload。测试不生成 ANSI，也不读取
terminal stdin。

## 声明式 View

应用 `view` 返回结构化 TuiNode，不返回 ANSI string：

```text
TuiNode {
  key,
  kind,
  layout,
  faces,
  content,
  children,
  focus,
  semantic_source,
  accessibility
}
```

内建 kind 包括：

```text
Text
StyledText
Row
Column
Stack
Padding
Border
Scroll
List
Table
Spacer
Custom
```

字符串是 Text node 的内容。ANSI escape sequence 不进入节点文本；颜色和属性使用
Theme face。应用可以使用任意稳定 Scheme datum 作为 node key，framework 在
session namespace 内规范化 key；同一父节点的子 key 必须唯一。

### Layout

layout 分成 measure 和 arrange：

```text
measure(node, constraints) -> desired size
arrange(node, rect) -> positioned tree
```

constraint 支持 fixed、content、flex weight、minimum、maximum 和 percentage。
Row/Column 在扣除 fixed/content 后按整数 flex weight 分配剩余 cells；余数按稳定
child order 分配。Border、Padding 和 Scroll 明确缩减 child rectangle。所有布局
运算使用 terminal cell width，支持宽字符、combining mark 和 tab policy。

Window layout 先分配 application View rectangle，application layout 只能在该
rectangle 内继续分配。节点 paint 被 rectangle clip；Custom node 不能写出其 clip。

### Paint 与 Frame

arranged tree 绘制到 `TuiSurface`：

```text
TuiSurface {
  rows,
  columns,
  cells,
  cursor?,
  component_tree,
  focus_ring
}
```

surface cell 使用 Soda Frame cell：

```text
Cell {
  text,
  width,
  continuation,
  faces,
  style,
  document_position: false,
  sources
}
```

应用 cell 的 `sources` 至少包含：

```text
CellSource {
  layer: application,
  owner: session_id,
  detail: node_key
}
```

因此 `describe-char`、hit testing、mouse routing 和 inspector 可以定位 application
与 component，而不从字符或 ANSI 反推结构。Theme resolver 把 faces 解析为 style；
应用不能持有 RGB terminal state，也不能绕过 active theme。

TuiSurface 合成到 Window text rectangle。该 Window 的 modeline 仍由 Editor 绘制；
应用可以通过只读 modeline contribution 提供 process、状态和 mode segment，不能
覆盖其他 Window 或 root minibuffer。completion、help 和 prompt overlay 最后由
Editor root compositor 绘制。

### Cursor

应用 View 声明逻辑 cursor：

```text
TuiCursor {
  node_key,
  local_row,
  local_column,
  shape,
  visible?
}
```

只有 active Window 的 focused application View 可以设置 terminal cursor。坐标在
arranged tree 中解析并 clip；无效 node 或坐标隐藏 cursor。非 active View 保留
逻辑 cursor，但不影响 terminal。

## 文本投影与通用编辑能力

application definition 可以提供：

```text
text_projection(model, view-state?) -> string
```

框架在 Model generation 改变后按需更新内部 Document。文本投影用于：

- copy-buffer、save-to-file 和日志导出；
- incremental search 与只读搜索结果；
- headless snapshot test；
- accessibility 和外部工具；
- 应用崩溃时的降级展示。

projection 不是 Model 的反序列化格式。对内部 Document 的编辑不会回写 Model，
也不产生应用消息。需要语义复制时，node accessibility 数据可以提供 label、value、
role 和 selection；普通 copy command 优先使用 focus node 的 copy action，再回退
到文本投影。

## Workbench 与 display

打开 application 使用普通 display request：

```text
tui.open(application, arguments, intent, origin)
  -> Buffer
  -> TuiSession
  -> display(buffer, intent, origin)
```

definition 的默认 intent 通常为 `tools` 或 `doc`。调用方可以请求 `edit`、`pop` 或
显式 Window。placement policy 只处理 Buffer identity 和 intent，不读取应用 Model。

应用 Buffer 可以 pinned 到具名 Window slot。切换 Workbench 保留 session 和 layout；
异步 result 沿 origin workbench 更新 Model，但不抢占当前 focus。应用显式请求
attention 时发布 status/notification message，不能自行切换 active Workbench。

## Scheme API

定义应用：

```scheme
(define-tui-application package-browser
  (init
    (lambda (context arguments)
      (values
        (make-package-model arguments)
        (list
          (tui-command 'packages.fetch arguments)))))

  (update
    (lambda (model message context)
      (match (tui-message-payload message)
        [('packages.loaded packages)
         (tui-result
           (package-model-with-packages model packages)
           '()
           '())]
        [('key 'down)
         (tui-result
           (package-select-next model)
           '()
           '())]
        [else (tui-result model '() '())])))

  (view
    (lambda (model context)
      (tui-column
        'root
        (list
          (tui-text 'title "Packages" '(heading))
          (tui-list
            'packages
            (package-model-rows model)
            (package-model-selection model))
          (tui-text
            'status
            (package-model-status model)
            '(status.info))))))

  (text-projection
    package-model->string)

  (mode 'package-browser-mode)
  (display-intent 'tools)
  (capabilities '(vfs timer)))
```

打开和投递消息：

```scheme
(tui-open! editor 'package-browser arguments 'tools)
(tui-send! editor session-id payload)
(tui-close! editor session-id)
```

应用命令仍注册到通用 command registry：

```scheme
(define-command package.refresh (context)
  (interactive)
  (tui-dispatch-active context '(packages.refresh)))
```

major mode 把 `package.refresh` 绑定到 `g`。应用 update 只处理
`(packages.refresh)` message；命令定义负责 interactive documentation、keymap、
hook、advice 和用户调用入口。

## Theme、帮助与 inspection

application node 使用语义 face：

```text
application
application.heading
application.border
application.selection
application.disabled
application.error
```

具体应用可以使用层级 face，如 `package.status.installed`，并声明
`application.status.success` fallback。Theme 不需要认识每个应用的全部 face。

TuiNode 的 accessibility metadata 包含：

```text
role
label
value
description
commands
keymap
```

`describe-char` 从 Frame source 显示 session、node path、local coordinate、faces 和
style。`describe-mode` 枚举 application major mode 与 active keymaps。
`describe-key` 使用同一个 handler/keymap resolution trace，说明事件由 Editor
override、InputState handler、application handler 或具体 keymap 消费。

## 生命周期与持久化

Workbench session 持久化：

```text
application name
Buffer resource
display intent and Window placement
definition-defined serialized Model
per-view durable viewport/focus state
```

pending command、Scheme procedure、native handle、timer、transient InputState、
popup 和在途 result 不持久化。恢复时重新查找 application definition，反序列化
Model，再调用 resume hook 返回新的 commands。definition 没有 serializer 时，
只恢复 application name 和 arguments，并重新运行 init。

session close 顺序为：

```text
blur visible Views
cancel commands
remove per-view state
run application close
detach Buffer presentation
close internal Document and Buffer
```

close procedure 发生 condition 时由 Editor debugger 保存 condition，资源清理继续
执行其余幂等步骤。

## 运行边界

框架保持以下所有权规则：

- application 不读 terminal stdin，不写 terminal stdout；
- application 不切换 raw/alternate screen 或 terminal protocol；
- update 和 view 不递归运行 command loop；
- view 不执行 I/O、不修改 Model、不创建 command；
- handler 不修改 Model、Buffer、View 或 Frame；
- effect handler 不直接调用 application update，只返回 TuiMessage；
- application 只绘制分配给其 View 的 rectangle；
- 跨异步边界的结果携带 session、generation 和 origin；
- Buffer close 和 Editor close 释放 session 持有的 Scheme 与 native 资源。

这些边界使 application 与文本 Buffer 共享一个 Workbench，而不会形成第二套终端
runtime、第二个事件循环或递归 REPL。

## 实现分层

框架按以下机制层组织：

1. `TuiApplicationDefinition`、catalog、TuiSession 和 lifecycle；
2. Buffer presentation 与 Window renderer dispatch；
3. TuiMessage、TuiCommand、generation 和 effect adapter；
4. 完整 InputState handler、application text policy 和 focus/resize message；
5. TuiNode、measure/arrange、TuiSurface 与 Frame composition；
6. Text、Row、Column、Padding、Border、Scroll、List 和 Table 基础组件；
7. accessibility projection、inspection、pointer routing 与 persistence。

最小一致性样例包含 counter、异步 list 和可输入 form：

- counter 验证 key、Model update、多 View 和 repaint；
- 异步 list 验证 command result、generation、scroll、focus 和取消；
- form 验证文本提交、paste、prompt child、Tab focus 和 host key passthrough。

Debugger、package browser、Buffer list、diagnostic list 和 project task dashboard
使用同一 framework；这些应用不在 renderer 中增加专用分支。
