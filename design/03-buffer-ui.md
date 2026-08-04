# Buffer、局部扩展与文本 UI

## 实现状态

| 能力 | 状态 |
|---|---|
| Buffer identity、immutable BufferState 与多 View | 已实现 |
| StateField、Facet、Compartment 与事务重配置 | 已实现 |
| owner-scoped Buffer close listener | 已实现 |
| canonical BufferKey 与 open-or-reuse registry | 已实现 |
| 标准 mode、input、edit policy 与 display Facet | 已实现 |
| BufferAttachment 生命周期与 close query | 部分实现 |
| generated projection、semantic item 与 action registry | 部分实现 |
| identity-preserving refresh 与多 View 位置恢复 | 部分实现 |
| editable projection session | 未实现 |
| message/update/effect application Buffer | 未实现 |

## 定位

Buffer 是有身份的共享编辑状态容器，也是 Soda 文本 UI 的统一承载边界。源文件、目录、
xref 结果、搜索结果、dashboard、REPL 和 debugger 都使用普通 Buffer；功能差异来自 extension
与 package attachment，不来自 Buffer 子类或 renderer 分支。

设计采用 CodeMirror 的 immutable state 与 extension 模型：可观察、可撤销或需要和文本原子
更新的状态进入 `BufferState`；行为由 `Facet` 聚合，运行时切换由 `Compartment` 表达。Emacs
Buffer 提供的局部模式、keymap、revert、read-only 和生命周期能力映射到这些显式机制。

```text
Document
  immutable text snapshot / revision / anchor
        │
        ▼
BufferState
  document + configuration + StateField values
        │
        ▼
Buffer
  identity + owner + lifecycle + current BufferState
        │
        ├── View A  selection / viewport / input state
        ├── View B  selection / viewport / input state
        └── BufferAttachment  producer / process / watcher / refresh
```

## 所有权边界

### Document

Document 只拥有文本、revision、anchor 和原子 change。它不知道文件、mode、只读策略、
semantic item、View 或显示位置。其完整契约由 [02-document.md](02-document.md) 定义。

### BufferState

`BufferState` 是所有 View 共享的不可变值：

```text
BufferState {
  document: DocumentSnapshot,
  generation,
  configuration,
  fields: StateField -> immutable value
}
```

文本 change、StateEffect、configuration reconfigure 和 transaction annotation 在同一
transaction 中产生新的 `BufferState`。package 不在 Buffer record 上增加功能字段。

### Buffer

host Buffer 保持最小固定形状：

```text
Buffer {
  id,
  owner,
  name,
  lifecycle: live | closing | closed,
  current: BufferState
}
```

`name` 是用户可见标签，不承担资源身份。异步请求和跨 command turn 的引用只保存
`BufferId`，使用时重新向 registry 解析。

### View

point、selection、mark、viewport、scroll target 和 input state 属于 View。同一 Buffer 可以
被多个 View 同时显示，每个 View 保持独立交互位置。Buffer extension 可以声明 View scope
StateField 或 ViewPlugin，但不能把某个 View 的位置写入 Buffer 局部状态。

### Surface 与 display

Buffer 创建和 Buffer 显示是两个操作。package 先 open-or-create Buffer，再提交
`DisplayRequest`；当前窗口、其他窗口、弹出区域和后台创建由 placement policy 决定。
Buffer 不保存 selected window 或最近显示 rectangle。

## Buffer identity 与复用

需要稳定复用的 Buffer 使用 canonical `BufferKey`：

```text
BufferKey {
  namespace: symbol,
  identity: immutable value
}
```

示例：

```text
(file, canonical path)
(directory, canonical directory resource)
(repl, evaluator session id)
(dashboard, workbench scope id)
(xref-result, producer session id)
```

`BufferCatalog` 维护 `BufferKey -> BufferId`。`open-or-create` 原子检查 live Buffer、创建新
Buffer 并安装初始 extension/attachment。没有稳定复用语义的临时 Buffer 不提供 key。
Buffer 关闭时 catalog 删除映射；name 冲突只影响显示名生成。

BufferKey 不等同于 Project。文件、目录和 Scheme environment 可以在没有 Project 的情况
下拥有稳定资源 identity。

## Buffer 局部状态

Soda 不提供任意可变的 buffer-local variable alist。局部能力分为三种：

### StateField

需要随 transaction 更新、参与 history、序列化或 revision 校验的数据使用 Buffer scope
`StateField`。典型值包括：

- generated model snapshot；
- semantic item ranges；
- Dired mark set；
- comint prompt boundary；
- file save point；
- diagnostics 或 fold state。

StateField value 必须视为不可变值。更新函数只消费旧 field、resolved transaction 和 effect，
不执行 I/O，不读取 terminal，也不修改 host service。

### Facet

多个 extension 对同一行为的声明通过 `Facet` 合并。标准 Buffer Facet 包括：

```text
buffer-mode              mode descriptor
buffer-input-layers      ordered local keymaps / input policy
buffer-edit-filters      transaction filters
buffer-display-profile   title, modeline and wrapping contributions
buffer-item-ranges       semantic item RangeSet providers
buffer-update-listeners  post-publication observers
```

Facet output 是由 configuration 派生的只读结果。命令和 presenter 查询 Facet，不根据
buffer name、package type 或 major mode symbol 分支。

### Compartment

需要在 Buffer 生命周期内替换的一组 extension 使用 Buffer scope `Compartment`：

- major mode；
- enabled minor mode；
- generated / editable projection mode；
- language profile；
- Buffer 级 display policy。

切换 mode 是一次 configuration transaction。旧 StateField 的销毁、新 StateField 的创建、
Facet 重算和 ViewPlugin reconciliation 在同一 publication boundary 发生。

## Mode 与输入贡献

`ModeDescriptor` 是 package 声明的数据：

```text
ModeDescriptor {
  id,
  display_name,
  parent?,
  extensions,
  command_categories,
  modeline_contribution?
}
```

major mode compartment 至多包含一个 descriptor。minor mode 是独立、可组合的 extension
compartment，不写入 Buffer 固定字段。派生 mode 组合 parent extension，不依赖运行时
`derived-mode-p` 式全局变量查询。

mode 通过 `buffer-input-layers` 提供 keymap。frontend 的 input resolver 按 transient layer、
View layer、Buffer mode/minor-mode layer和全局 layer 组合输入上下文。命令仍通过统一
CommandRuntime 执行。

## EditPolicy

read-only 是 transaction policy，不是禁止所有 BufferState 更新的布尔开关：

```text
EditPolicy {
  content_changes: allow | reject | validate,
  state_effects: allow,
  protected_ranges?,
  authority?
}
```

普通用户命令受 `buffer-edit-filters` 约束。producer refresh、process output 和 mode conversion
使用 owner-scoped edit authority 提交受信 transaction；authority 只能绕过自身安装的 policy，
不能全局关闭所有 transaction filter。

因此只读 Dired Buffer 仍可更新 mark、refresh listing 或接受文件系统事件。comint 可以保护
transcript 但允许 prompt 后输入。narrowing、atomic range 和局部可编辑 generated Buffer 都由
相同 filter/range 机制组合。

## BufferAttachment

StateField 不保存 mutable process、watch handle、pending request 或回调注册。此类资源属于
host package attachment：

```text
BufferAttachment {
  key,
  owner,
  buffer_id,
  generation,
  close_query?,
  refresh?,
  destroy
}
```

attachment 由独立 `BufferAttachmentService` 按 `(BufferId, key)` 管理。安装返回 owner-scoped
registration。Buffer 关闭时先运行 close query，再销毁 attachment；owner 卸载时仅移除该
owner 的 attachment 和 extension contribution。

attachment 与 BufferState 交互只能通过 command message、StateEffect、host operation 或
Dispatcher transaction。它不能直接替换 BufferState，也不能从异步回调修改 View。

`close_query` 返回允许关闭或一个 interaction request。关闭进入 `closing` 后冻结新的 package
attachment；请求取消则恢复 `live`，确认后统一关闭关联 View、attachment 和 Document。

## Generated Buffer 与语义投影

generated Buffer 仍有真实 Document，但 Document 是领域 model 的物化投影。producer 的
StateField 保存权威 model snapshot，单次 refresh 原子发布：

```text
ProjectionUpdate {
  model_generation,
  document_change,
  item_ranges,
  decorations,
  semantic_position_map
}
```

显示文本不承担领域身份。每个可操作区域使用标准 semantic item：

```text
BufferItem {
  provider_id,
  item_id,
  kind,
  payload,
  actions: symbol set,
  primary_action?
}
```

`buffer-item-ranges` Facet 提供映射到当前 Document revision 的 `RangeSet<BufferItem>`。
`item-at-point`、`next-item`、`previous-item` 和 `activate-item` 是通用命令；它们查询当前
View selection 下的 item，不解析显示字符串。

action 以 symbol 标识，并通过 owner-scoped action registry 解析。StateField 和 RangeSet
不保存可失效的 procedure closure。action 收到稳定 `BufferItem`、CommandContext 和 producer
generation，再产生普通 command outcome。

face、不可见、replacement 与虚拟文本仍由 Decoration/DisplayMap 提供。semantic item 与
decoration 可以覆盖同一 range，但没有继承或所有权关系。

## Refresh 与位置恢复

刷新以 model generation 为异步有效性边界。旧 generation 的结果直接丢弃。接受 refresh
时，host 在一个 dispatch turn 内发布 Buffer transaction 和所有相关 View transaction。

每个 View 在 refresh 前取得 `SemanticPosition`：

```text
SemanticPosition {
  provider_id,
  item_id?,
  offset_within_item,
  fallback_anchor,
  desired_column?
}
```

新 item set 中仍存在相同 identity 时，selection 恢复到对应 item；identity 消失时使用
mapped anchor，再退化到最近可导航 item。每个 View 独立恢复，Buffer 不保存共享 point。

mark、展开状态和 producer selection 同样按 item identity 映射。刷新不得依赖行号、旧 byte
offset 或重新解析渲染文本。

## Editable projection

可编辑 generated UI 使用显式 `EditableProjectionSession`，而不是临时关闭全局 read-only：

```text
EditableProjectionSession {
  baseline_model,
  baseline_generation,
  editable_ranges,
  edit_mode_compartment,
  commit_action,
  abort_action
}
```

进入 session 时切换 mode/keymap/edit filter，并保存权威 model baseline。普通编辑命令只允许
修改 editable ranges。提交时 package 从结构化 range 与 Document change 生成领域 operation，
验证外部 generation 后执行 effect；成功后重新投影。取消恢复 baseline projection。

该机制覆盖 WDired 式批量重命名、wgrep、可编辑 diagnostics fix list 和结构化表单。

## Dired 映射

Dired 类目录 Buffer 由以下普通能力组成：

```text
BufferKey(directory, canonical resource)
DirectoryAttachment(directory watcher + refresh producer)
DirectoryModelField(entries, subdirectories, generation)
DirectoryMarkField(set<entry_id>)
BufferItemRangeSet(entry_id -> filename range)
directory-mode compartment
read-only EditPolicy
directory actions(open, mark, delete, rename, refresh)
```

`directory.open` 先 open-or-reuse Buffer，再单独提交 DisplayRequest。mark command 更新
`DirectoryMarkField`，投影用 decoration 显示 `*` 或删除标志，Document 不保存 mark 字符。
refresh 按 entry identity 保留所有 View 的位置和 mark。可编辑重命名通过
`EditableProjectionSession` 完成。

## Application Buffer

需要 Bubble Tea 式状态机的工具仍以普通 Buffer 暴露 identity、文本语义和 command 行为：

```text
ApplicationDefinition {
  init(context) -> model + effects,
  update(model, message, context) -> model + effects,
  project(model, projection_context) -> text + items + decorations
}
```

model 是 Buffer scope StateField；message 通过 command/runtime queue 进入；I/O 使用
CommandEffect；project 产生 ordinary generated projection。不同 View 共享 model 和 Document，
但保持独立 selection、viewport、focus path 和 ViewPlugin cache。

application package 可以用 decoration、replacement 和 virtual line 增强显示，也可以提供局部
input layer；它不能拥有 terminal screen、绕开 Frame compositor，或把 cell grid 作为唯一状态。
文本投影和 semantic item 保证 describe、copy、search、navigation 与其他 Buffer command 仍可
组合。dashboard、debugger inspector 和结构化表单使用这一模型。

## 生命周期与错误边界

Buffer 生命周期顺序为：

```text
live
  -> close requested
  -> close queries
  -> closing
  -> detach Views
  -> destroy attachments
  -> remove BufferKey mapping
  -> close Document
  -> closed
```

extension 的纯 create/update 失败使对应 transaction 失败，不发布部分状态。ViewPlugin 失败按
View plugin policy 隔离并 retire。attachment 的异步错误进入 ConditionService；Buffer 仍保持
live，除非 package 明确提交关闭操作。

## 实现边界

新增机制按以下目录组织：

```text
scheme/soda/kernel/
  BufferState、StateField、Facet、Compartment、RangeSet

scheme/soda/host/
  Buffer registry、BufferCatalog、BufferAttachmentService、close lifecycle

scheme/soda/packages/base/
  standard mode/input/edit/display Facet、semantic item navigation

scheme/soda/packages/tools/
  generated projection、directory、result buffers、dashboard
```

kernel 不认识 file、directory、result、REPL 或 Project。host 不解释 package StateField 和
BufferItem payload。renderer 不运行 producer，也不根据 Buffer kind 分支。

## Contract tests

Buffer contract tests 覆盖：

- 相同 BufferKey 并发 open 只产生一个 live Buffer；
- 同一 Buffer 的多个 View 保持独立 selection、viewport 和 input state；
- mode compartment reconfigure 原子替换 StateField、Facet 和 input contribution；
- read-only policy 拒绝用户 content change，但允许 state-only transaction 和授权 refresh；
- owner close 移除其 attachment、action 和 extension contribution；
- close query 取消时 Buffer 恢复 live，确认时按固定顺序释放资源；
- generated refresh 原子发布文本、item ranges 和 decorations；
- refresh 按 item identity 独立恢复所有 View selection；
- item navigation 与 activation 不解析显示文本；
- editable projection 只允许声明范围，并能提交或恢复 baseline。
