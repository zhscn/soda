# Scheme 交互与调试

## 交互模型

Chez Scheme 运行在编辑器进程内。编辑器 command loop 是唯一的交互前端，终端
stdin 由 TUI input decoder 持有，Scheme 求值不会启动第二个终端 REPL。REPL、
源码求值和调试器都通过 Editor 的 message、effect 与 Buffer 模型呈现。

交互系统把生命周期、transcript 编辑和语言求值分成独立实体：

| 实体 | 身份与生命周期 | 责任 |
|---|---|---|
| `InteractionSession` | Editor registry 中的 session id | evaluator、求值世代、历史、失败状态与 transcript 所有权 |
| `InteractionTranscript` | session 所有的 Document anchors | prompt、输入边界以及最近一次 input/output ranges |
| `InteractionHistory` | session 所有的有界 ring | entries、浏览位置与浏览前草稿 |
| `EvaluationRequest` | session id + generation | 源码、来源 Buffer、resource、revision 与 byte range |
| `DebuggerSession` | 失败 request 的 generation | condition continuation、frame inspector、选择位置与工具 Buffer |
| transcript Buffer | 普通 Buffer id | prompt、输入和 stdout/stderr/value/condition 的文本投影 |

session 不以 Buffer 作为 namespace。关闭 transcript 需要先关闭所属 session；
同一个 session 的视图可以重新创建，求值环境与 request identity 保持独立。

通用 comint 层负责激活 transcript View、提交和替换当前输入、追加输出、浏览历史
以及维护 caret 可见性。Scheme REPL 层负责 Chez reader 完整性判断、构造求值
request、格式化 result 和提供 debugger command。其他 interaction mode 可以复用
comint 层而不依赖 Chez evaluator。

`Document.editable-start` 同时是 comint 输入边界和通用 editor service 的可见下界。
completion-at-point、当前输入读取和编辑命令通过该 Document 契约工作，不读取
prompt 文本，也不依赖 InteractionSession 类型。语言 REPL adapter 独立提供 runtime
completion source。

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

每个 editor message 构成一个顶层异常边界。正常 command result 继续进入 effect
executor；未处理的 Scheme condition 被保存为 Editor 所有的 `DebuggerSession`，
当前 update 返回空 effect 列表，下一轮 command loop 继续处理输入和绘制。TUI
host 对 effect handler 使用同样的边界，因此异步回调或 adapter 中的异常也不会
越过 libuv poll loop。

`editor-user-error` 表示可预期且可恢复的交互失败，例如修改只读区域或使用已经
过期的 xref 位置。这类 condition 只更新 status message。普通 `error`、
assertion violation 和未分类的 condition 视为实现异常，立即打开 debugger
Buffer。异常边界清理尚未完成的 interactive invocation、prefix argument 和
pending key sequence，但不关闭 Editor、Buffer 或 runtime。

## Transcript 与输入

transcript Buffer 由不可编辑的历史前缀和一个可编辑的当前输入区组成。
`InteractionTranscript.output-mark`、`input-start` 与 `Document.editable-start`
指向当前 prompt 之后的同一位置。transcript 使用 Document anchors 保存以下
结构位置：

```text
last-input-start  last-input-end
last-output-start last-output-end
prompt-start      prompt-end
output-mark       input-start
```

提交输入时，comint 记录 last-input range 并将边界推进到终止换行之后。应用结果
时记录 last-output range，追加新 prompt，再把 output mark、input start 和
Document editable boundary 推进到 prompt 末尾。Buffer 中发生插入或替换时，
这些位置通过 anchor 语义保持有效。

新建 transcript View 继承当前编辑 View 的 viewport，并保证初始内容和 caret 所在
行列都能容纳在占位 viewport 中。终端 resize 随后设置实际 viewport。重新激活
已有 View 时，caret 位于 Buffer 末尾，因此尚未提交的草稿仍是当前编辑位置。

Enter 使用 Chez reader 检查当前输入是否包含完整 forms。完整输入作为一个
`EvaluationRequest` 提交；因输入结束而无法闭合的 form 在 caret 处插入换行并
继续编辑。其他 reader condition 作为完整请求提交，由 evaluator 将 condition
呈现在 transcript 中。

session 保存有界、按提交顺序排列的输入历史，忽略空输入和连续重复项。REPL
keymap 提供以下操作：

- `M-p` 选择较早的输入；
- `M-n` 选择较新的输入，并在越过最新记录时恢复开始浏览前的草稿；
- `C-c C-u` 清空当前输入并结束历史浏览。

由源码 Buffer 发起的 `scheme.eval-expression` 与当前 REPL 草稿共享同一个
session。求值命令暂存草稿，将待求值 source 投影到 transcript；结果和新 prompt
写入后再恢复草稿。debug retry 使用相同机制保留失败 prompt 后正在编辑的输入。

源码求值命令共享同一提交入口：

- `scheme.eval-region` 提交 active region；
- `scheme.eval-buffer` 提交当前 Buffer 的完整 snapshot；
- `scheme.eval-last-sexp` 用 Chez reader 在 point 前定位最后一个完整 datum；
- `scheme.eval-expression` 接受调用者直接提供的 string 或 UTF-8 bytes。

range 命令在切换到 transcript View 前捕获 Buffer identity、resource、revision
和 byte range，并把它们写入 `EvaluationOrigin`。last-sexp 的 reader position 是
字符 offset，命令在创建 origin 前按 UTF-8 编码转换为 byte offset。源码命令使用
现有持久 evaluator 和 effect 回流，不创建独立 environment 或递归 command loop。

## 编辑器 API

evaluator 在 session environment 中提供：

- `*editor*`：当前 Editor，供查询和 Scheme-first 扩展使用；
- `*interaction-session*`：发起求值的 session；
- `editor-command!`：按 command symbol 和可选参数创建后续 command message。

求值期间调用 `editor-command!` 只记录 internal command message。求值结果先应用
到 session 和 transcript，随后 command loop 依次处理这些消息。该顺序避免从
evaluator 栈中递归调用 `editor-update!`，并让普通 command registry 继续作为
编辑器 mutation 的序列化入口。

`current-output-port` 与 `current-error-port` 在每次求值中重定向到结果对象。
`current-input-port` 是该 request 私有的 EOF port，不能读取终端输入。需要用户
输入的工作流由 interaction command 创建
[PromptSession](12-minibuffer.md)，接受结果通过后续 internal command message
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
Editor command 或 effect handler 失败则创建 Editor 所有的 debugger，并立即把
触发异常的 View 切换到 debugger Buffer。两类 debugger 使用相同的数据模型和
命令，不创建递归 REPL 或第二个事件循环。

evaluator 在编译和执行 request 时保留 Chez inspector information。condition
continuation 由 `DebuggerSession` 投影为有序 frame；每个 frame 保存 procedure
name、可用的源码位置和 variable inspector。局部值只在显示时生成有界 preview，
原始 Scheme 对象留在 Chez heap 中。没有 raise continuation 的 condition 仍可
进入 debugger 并显示结构化 condition 信息，其 frame 列表标记为不可用。

debugger 分为数据模型和 editor adapter。数据模型只负责 continuation inspection、
frame selection 与 frame-relative evaluation；adapter 管理 command、major mode、
generated Buffer、prompt 和返回 Buffer 切换。`debugger-mode` 是 interface mode，
其 Buffer 是 session 状态的只读文本投影。投影包含异常来源、`who`、message、
irritants、frame 列表和选中 frame 的 locals。选择 frame 后重新生成投影，caret
跟随选中的 frame 行。每个 debugger 使用独立的 generated resource，因此不同
interaction 的失败状态可以同时保留。

失败状态提供以下动作：

- `scheme.debug-open` 打开或重新激活 debugger Buffer；
- `scheme.debug-next-frame` 与 `scheme.debug-previous-frame` 循环选择 frame，接受
  prefix count；
- `scheme.debug-eval-frame` 通过 minibuffer 读取一个 datum，并使用选中 frame 的
  inspector environment 求值；
- `scheme.debug-visit-source` 通过异步 VFS open request 打开选中 frame 的 source
  path，并按行与字符位置定位 caret；
- `scheme.debug-retry` 关闭当前 debugger，使用新的 generation 重放原始 source
  和 origin；
- `scheme.debug-exit` 关闭 debugger Buffer 并返回触发异常的 Buffer，同时保留
  condition、continuation 和 frame inspector；
- `scheme.debug-discard` 释放 debugger Buffer、condition 与 continuation；对
  interaction failure 同时退出 `failed` 状态。

debugger Buffer 的 `n`、`p`、`e`、`v`、`r`、`x`、`q` 分别映射到导航、求值、
源码访问、重试、保留退出与丢弃操作。源码访问复用普通 `file.read` effect，文件
读取期间 command loop 保持可用；打开完成后 debugger 状态仍可重新激活。重试和
丢弃会先把所有显示 debugger Buffer 的 View 切回来源 Buffer。Editor 关闭时释放
Editor 与 interaction 持有的所有 debugger continuation。frame inspection 和
frame-relative evaluation 都作为普通 command 执行，不接管 terminal stdin，也
不进入递归 command loop。

成功求值产生的顶层 binding 保存在 session 的 Chez environment 中。
`scheme-repl` completion provider 将 environment symbol 投影为通用
`CompletionItem`；它不从 transcript 文本恢复 binding。静态 Scheme semantic
provider 的职责与组合边界见 [11-scheme-semantics.md](11-scheme-semantics.md)。
