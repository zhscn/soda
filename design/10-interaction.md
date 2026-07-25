# Scheme 交互与调试

## 交互模型

Chez Scheme 运行在编辑器进程内。编辑器 command loop 是唯一的交互前端，终端
stdin 由 TUI input decoder 持有，Scheme 求值不会启动第二个终端 REPL。REPL、
源码求值和调试器都通过 Editor 的 message、effect 与 Buffer 模型呈现。

交互系统包含三个相互独立的实体：

| 实体 | 身份与生命周期 | 责任 |
|---|---|---|
| `InteractionSession` | Editor registry 中的 session id | 持久 namespace、求值世代、历史、失败状态 |
| `EvaluationRequest` | session id + generation | 源码、来源 Buffer、resource、revision 与 byte range |
| transcript Buffer | 普通 Buffer id | prompt、输入和 stdout/stderr/value/condition 的文本投影 |

session 不以 Buffer 作为 namespace。关闭 transcript 需要先关闭所属 session；
同一个 session 的视图可以重新创建，求值环境与 request identity 保持独立。

## Command loop 边界

求值使用标准 update/effect 流程：

```text
command message
      │
      ▼
protect input + create request
      │
      ▼
scheme.evaluate effect
      │
      ▼
Chez evaluator
      │
      ├── values / stdout / stderr / condition
      └── queued editor command messages
      │
      ▼
scheme.apply-evaluation-result message
      │
      ▼
session state + transcript Buffer + View
```

update 阶段只创建 request。evaluator 在 effect 阶段读取并执行全部 forms，使用
session 持有的可变 Chez environment，因此顶层定义在后续 request 中可见。结果
只有在 session id、generation 和 `evaluating` 状态仍匹配时才能应用；过期结果不
能修改 transcript 或 Editor。

求值与 command loop 位于同一线程。一次求值返回前，输入分发和 frame rendering
不会推进。交互命令应保持有界；需要跨 turn 推进的工作通过显式 effect 和带
revision 的后续 message 表达。

## 编辑器 API

evaluator 在 session environment 中提供：

- `*editor*`：当前 Editor，供查询和 Scheme-first 扩展使用；
- `*interaction-session*`：发起求值的 session；
- `editor-command!`：按 command symbol 和可选参数创建后续 command message。

求值期间调用 `editor-command!` 只记录消息。求值结果先应用到 session 和
transcript，随后 command loop 依次处理这些消息。该顺序避免从 evaluator 栈中
递归调用 `editor-update!`，并让普通 command registry 继续作为编辑器 mutation
的序列化入口。

`current-output-port` 与 `current-error-port` 在每次求值中重定向到结果对象。
`current-input-port` 是该 request 私有的 EOF port，不能读取终端输入。需要用户
输入的工作流由 interaction command 创建输入状态或专用 Buffer，再用后续 request
继续计算。

## 来源与 revision

每个从 Buffer 发起的 request 保存 `EvaluationOrigin`：

```text
EvaluationOrigin {
  buffer-id,
  resource,
  revision,
  start?,
  end?
}
```

REPL transcript 输入保存精确 byte range；由命令传入的表达式保存来源 Buffer 和
revision。源码跳转、错误定位和 debugger 展示使用 origin，而不从复制后的 source
string 猜测位置。使用 origin 前必须确认 Buffer 仍存在；需要对原文应用操作时还
必须确认 revision 匹配。

## 失败与 debugger

求值失败产生 `condition` result。session 进入 `failed` 状态并保留原始 request、
Chez condition 和可用的 continuation；transcript 只显示 condition 的文本投影。
debugger command 从进程内对象构造工具 Buffer 或 overlay，因此不需要把 frame、
局部变量或任意 Scheme 值序列化成远程协议。

失败状态提供以下基础动作：

- `scheme.debug-retry` 使用新的 generation 重放原始 source 和 origin；
- `scheme.debug-dismiss` 退出失败状态并保留结果供检查。

stack frame、局部变量、restart 与 continuation 操作属于同一个 debugger 数据
模型。呈现层通过 generated Buffer、selection 和 describe 组件访问这些对象，
不接管 terminal stdin，也不进入递归 command loop。
