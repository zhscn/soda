# Command 与扩展运行时

## 实现状态

| 能力 | 状态 |
|---|---|
| CommandDefinition、registry 与 owner-scoped registration | 已实现 |
| CommandContext、result/effect 与消息队列执行 | 已实现 |
| interactive plan、typed reader、suspend/resume/cancel | 已实现 |
| lifecycle hook 与 advice | 已实现 |
| prefix argument 与稳定 target | 部分实现 |
| `define-command` 声明宏与命令内省 UI | 未实现 |
| major/minor mode package | 未实现 |

## Command protocol

command 是 package 声明的普通 Scheme procedure 加稳定元数据：

```text
CommandDefinition {
  name,
  invoke,
  documentation?,
  class?,
  interaction_plan?,
  owner
}
```

procedure 接收 `CommandContext` 和已经解析的显式参数。直接 Scheme 调用可以复用同一 procedure；
keymap、M-x 和消息调用通过 registry/runtime 执行 definition。CommandDefinition 不持有 Buffer、
terminal、minibuffer 或 Dispatcher service。

注册返回 owner-scoped registration。owner 关闭后 definition、hook、advice 和 effect handler 一并
失效，队列中的 invocation 在执行前重新校验 definition 与 target。

## CommandContext

context 是 invocation 开始时冻结的输入与目标快照：

```text
CommandContext {
  invocation_id?,
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

异步 continuation 使用保存的 identity 重新解析对象，不从恢复时的当前焦点猜测目标。需要严格
revision 的命令验证冻结 BufferState generation；明确作用于当前焦点的后续命令创建新 context。

## Result 与 effect

command 返回一个 outcome 或有序 outcome 列表：

```text
handled
TransactionSpec
ViewTransactionSpec
HostOperation
CommandEffect(kind, payload)
```

runtime 规范化为 `CommandResult`，依次提交 transaction、View update 和 host operation。
I/O、process、clipboard、producer refresh 等 package 行为使用 `CommandEffect`；effect handler
按 kind 和 owner 注册。command procedure 不直接调用 terminal 或修改 service table。

## Interactive plan

interactive command 的参数读取是 reader 序列：

```text
InteractiveReader(context, preceding_arguments)
  -> InteractiveReady(values)
   | InteractiveSuspend(request, decoder)
```

ready value 立即追加参数。suspend 创建 invocation session 并把 request 交给 interaction handler；
主 command loop 继续处理输入、render 和其他消息。接受结果通过 decoder 变为参数并恢复 invocation；
取消使 invocation 进入 cancelled，并运行 lifecycle hook。

minibuffer 是一个 interaction adapter，而不是递归 command loop，详见
[06-minibuffer.md](06-minibuffer.md)。自定义 reader 只依赖 request/result 协议。

## Invocation lifecycle

```text
queued
  -> resolving arguments
  -> suspended | invoking
  -> applying outcomes
  -> completed | cancelled | failed
```

runtime 以 invocation id 管理存活状态。resume/cancel message 必须匹配仍 suspended 的 invocation；
重复或过期消息被拒绝。condition 在 command boundary 捕获并交给 ConditionService，不能留下部分
发布的 transaction。

## Hook

hook 观察 runtime lifecycle，例如 pre-command、post-command、error 和 cancel。hook registration
包含 owner、name、order 和 procedure。observer failure 被隔离并报告，不替换 command result。

需要改变参数或返回值的扩展使用 advice，不借用 hook。

## Advice

advice 依 command symbol 注册，支持：

```text
before
after
around
filter-args
filter-return
```

同 placement 按 depth 和 registration order 稳定排序。`filter-args` 必须返回参数列表；
`filter-return` 返回可规范化 command result；around advice 接收下一层 procedure。advice 不修改
registry definition，也不把 transient wrapper 写回 keymap。

## Mode 与命令可用性

mode 不属于 CommandRuntime。Buffer mode extension 通过 [03-buffer-ui.md](03-buffer-ui.md) 的
Facet 提供 local keymap、command category 和 enablement predicate。registry 保存全局可发现的
definition；输入层和 M-x presenter 根据 active context 过滤候选。

minor mode 是可卸载的 Buffer Compartment contribution，不是 command runtime 中的布尔变量。

## 声明接口

公开 constructor 是稳定底层接口。未来 `define-command` 宏只展开为普通 procedure、
CommandDefinition metadata 和显式安装入口，不创建隐藏全局 registry，也不改变调用语义。

```scheme
(define-command (goto-line context line)
  (documentation "Move point to LINE.")
  (class motion)
  (interactive (number-reader "Goto line: "))
  ...)
```

宏生成的 procedure 仍可直接以 `(goto-line context 42)` 调用；安装时必须提供 runtime 和 owner。

## Contract tests

Command contract tests 覆盖：

- owner close 原子移除 definition、hook、advice 和 effect handler；
- frozen context 不随焦点切换漂移；
- interactive reader 顺序、suspend/resume/cancel 和 stale reply；
- advice placement、depth、参数和结果验证；
- hook failure 隔离；
- command condition 不发布部分 transaction；
- keymap、直接 message 和 interactive invocation 使用同一 runtime boundary。
