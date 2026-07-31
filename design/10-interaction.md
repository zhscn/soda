# Scheme 交互与调试

## 实现状态

| 能力 | 状态 |
|---|---|
| 编辑器内 Chez REPL、transcript 与来源跟踪 | 已实现 |
| 通用子进程 comint、prompt boundary 与 process transport | 已实现 |
| 异常边界、continuation capture 与 debugger Buffer | 已实现 |
| restart/action、继续执行、检查与源码定位 | 已实现 |
| 长时间求值的协作中断与 engine 调度 | 已实现 |
| 跨进程持久历史 | 未实现 |

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

首次激活 interaction transcript 时，adapter 在当前源码窗口下方显示其 View；
已有 transcript View 则直接选择所属 window。`scheme.open-repl` 在 transcript
window 与另一个可见编辑 window 之间切换 focus，两个 View 保持同时显示。源码
求值因此可以把结果写入下方 transcript，而来源 Buffer、point 和 viewport 保留在
原 window。

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

求值与 command loop 位于同一线程，并由 Chez engine 划分为有界 slice。每个
`EvaluationTask` 持有可续跑 engine；libuv 单次 timer 触发一个带固定 tick fuel 的
slice。engine 完成时产生 result，fuel 耗尽时保存后继 engine 并重新安排 timer。
timer turn 之间，command loop 继续分发输入、处理 I/O 和绘制 frame。Scheme
计算因此具有协作式抢占，而 Editor 状态仍由单线程串行持有。

`scheme.interrupt-evaluation` 在下一个 timer turn 把运行中的 task 转为
`suspended`，保留其后继 engine，并为该 generation 打开 debugger。`continue`
重新安排同一个 engine；`abort` 释放 engine、结束该 request，并在 transcript
写入中断结果与新 prompt。已经执行的顶层副作用不会回滚。engine 的 tick 抢占
发生在 Chez 安全点；不可分割的 native FFI 调用必须自行保持有界或使用异步
runtime。

每个 editor message 构成一个顶层异常边界。正常 command result 继续进入 effect
executor；未处理的 Scheme condition 被保存为 Editor 所有的 `DebuggerSession`，
当前 update 返回空 effect 列表，下一轮 command loop 继续处理输入和绘制。TUI
host 对 effect handler 使用同样的边界，因此异步回调或 adapter 中的异常也不会
越过 libuv poll loop。

`editor-user-error` 表示可预期且可恢复的交互失败，例如修改只读区域或使用已经
过期的 xref 位置。这类 condition 只更新 status message。普通 `error`、
assertion violation 和未分类的 condition 视为实现异常，立即打开 debugger
Buffer。异常边界撤销处于进行状态的 interactive invocation，并清理 prefix
argument 和 pending key sequence，但不关闭 Editor、Buffer 或 runtime。

## Transcript 与输入

transcript Buffer 由不可编辑的历史前缀和一个可编辑的当前输入区组成。
`InteractionTranscript.output-mark`、`input-start` 与 `Document.editable-start`
指向当前 prompt 之后的同一位置。transcript 使用 Document anchors 保存当前
结构位置，并维护按显示顺序排列的 field ledger：

```text
output field
prompt field
input field
```

固定的历史 output、prompt 和 input field 使用成对 anchor；当前 input field 的
末端是 Buffer 末端。提交输入时，comint 固定当前 input field，并将边界推进到
终止换行之后。应用结果时追加 output field 和新 prompt field，再把 output mark、
input start 和 Document editable boundary 推进到 prompt 末尾。Buffer 中发生插入
或替换时，这些位置通过 anchor 语义保持有效。移动、复制、历史导航和子进程 adapter
查询 field，不解析 prompt 文本。

交互 adapter 可以设置 continuation prompt，并通过 Buffer 的 display-run provider
从 input field ledger 生成投影。DisplayMap 在每个多行 input 的第二行及后续行行首
投影该文本，使当前输入和历史输入具有相同的视觉基线。continuation prompt 是
virtual run，不进入 Document、input field 或求值 source；缩进、补全、history 和
reader 始终处理原始输入。field anchor 移动后，下一帧从新位置重新生成投影。

新建 transcript View 继承当前编辑 View 的 viewport，并保证初始内容和 caret 所在
行列都能容纳在占位 viewport 中。终端 resize 随后设置实际 viewport。重新激活
已有 View 时，caret 位于 Buffer 末尾，因此尚未提交的草稿仍是当前编辑位置。

## 子进程 interaction

子进程复用 InteractionSession、InteractionTranscript、history 和
通用 comint command。每个 session 的 `ProcessComint` 拥有一个独立于 Buffer 的
`ManagedProcess`，并保存 `ProcessComintProfile`。profile 定义 argument vector、
工作目录、transport、PTY 初始尺寸、固定 prompt byte sequence、input sender、
output filter 与 exit sentinel。Scheme 扩展通过 `process.start` 提交 profile；
`process.run` 提供 pipe-backed shell command 的交互入口。profile 默认使用
`pipe`；需要 terminal line discipline 的 REPL、debugger 和交互式命令使用 `pty`。

transcript 的 `input-start` 同时是 process mark。子进程输出插入 process mark，
而不是追加到 Buffer 末端；未提交输入和位于输入区的 caret 随插入向后移动。这样
异步输出不会覆盖或打散用户草稿。output filter 按 stdout、stderr 或 terminal
stream 接收原始 byte chunk，可以返回 bytes、string 或丢弃该 chunk。

固定 prompt detector 在 byte stream 上工作，保留可能跨 chunk 的 prompt prefix。
完整 prompt 被记录为 prompt field，其余内容记录为 output field。软行首、历史
prompt 导航和 field inspection 因此沿用同一 transcript 查询，不扫描显示文本。
进程退出时先排空未决 prompt prefix，再调用 sentinel 生成最终 output。

Enter 固定当前 input field、记录 history，并通过 profile input sender 生成写入
stdin 的 bytes。`C-c C-c` 向子进程发送 SIGINT，`C-c C-d` 关闭 stdin，
`C-c C-r` 重启逻辑进程。`process.terminate` 和 `process.kill` 分别发送 SIGTERM
和 SIGKILL。所有 spawn、write、close、signal、restart 和 output/exit 回传都经过
ManagedProcess effect/runtime adapter，libuv callback 不直接进入 Editor update。
pipe profile 的 EOF 关闭 stdin；PTY profile 的 EOF 向 line discipline 写入 EOT。
PTY 尺寸属于 ManagedProcess 状态，resize effect 同步更新 native terminal 和逻辑
进程记录。

Enter 使用 Chez reader 检查当前输入是否包含完整 forms。完整输入作为一个
`EvaluationRequest` 提交；因输入结束而无法闭合的 form 在 caret 处插入换行并
继续编辑。换行缩进由 Scheme lexical scanner 根据 caret 前的 entry prefix
计算：字符串、quoted symbol、字符字面量、行注释和嵌套块注释不贡献结构
delimiter；未闭合 form 优先与较近的第二个 datum 对齐，否则相对 opener 使用
`indent-width`。换行与缩进属于同一个 Buffer transaction。其他 reader
condition 作为完整请求提交，由 evaluator 将 condition 呈现在 transcript 中。

session 保存有界、按提交顺序排列的输入历史，忽略空输入和连续重复项。历史搜索
保留搜索开始时的输入作为 key 和草稿；向较新方向越过最后一个匹配项时恢复该
草稿。prefix 搜索忽略历史项的前导空格，输入自身以空格开头时则把空格作为
prefix 的一部分。

REPL 把 prompt 之后的完整输入视为一个 entry。`M-<` 和 `M->` 在 entry
边界之间移动；`Home` 和 `C-a` 移动到所在行的软行首：含 prompt field 的行停在
该 field 末端，续行和普通 output 行停在物理行首。该规则同样适用于历史 entry；
prefix argument 请求物理行首。
垂直移动和历史访问形成连续导航：

- `Up`、`C-p` 和 `Down`、`C-n` 在多行 entry 内移动，到首行或末行后访问相邻
  历史项；
- `M-Up` 和 `M-Down` 直接按提交顺序访问历史；
- `M-p` 和 `M-n` 按当前 entry 的 prefix 向前、向后搜索；
- `M-P` 和 `M-N` 按当前 entry 包含的文本向前、向后搜索；
- `Tab` 按 Scheme 结构重新缩进当前行；
- `M-q` 重新缩进完整 entry，并把修改记录为一次 undo transaction；
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

evaluation debugger 占用对应 interaction window，并在关闭、重试、继续或丢弃时
恢复 transcript View。Editor command debugger 在来源 window 下方建立临时
debugger window；关闭 debugger 时若来源 Buffer 已在另一 window 可见，则删除该
临时 window 并选择来源 View。`scheme.debug-visit-source` 在另一个 window 显示
源码并保留 debugger window；`scheme.debug-open` 从源码 window 重新选择仍可见的
debugger。该布局让 frame/Inspector 操作、源码查看和 transcript 保持在同一
command loop 中切换 focus。

evaluator 在编译和执行 request 时保留 Chez inspector information，并为交互式
求值关闭 CP0 源级优化。该编译策略保留异常点之后的 continuation 结构，使
replacement value 可以返回原计算的剩余上下文。condition continuation 由
`DebuggerSession` 投影为有序 frame；每个 frame 保存 procedure name、可用的源码
位置和 variable inspector。局部值只在显示时生成有界 preview，原始 Scheme 对象
留在 Chez heap 中。没有 raise continuation 的 condition 仍可进入 debugger 并
显示结构化 condition 信息，其 frame 列表标记为不可用。

debugger 分为数据模型和 editor adapter。数据模型只负责 continuation inspection、
frame selection 与 frame-relative evaluation；adapter 管理 command、major mode、
generated Buffer、prompt 和返回 Buffer 切换。Chez inspector object 由
`InspectorNode` 包装。节点公开 `preview`、`children`、`evaluate`、`set-value`、
`apply`、`code`、`call`、`closure` 和 `source` 等显式 capability，调用者只依赖
节点声明的 capability，不按 Chez object type 猜测可用操作。变量节点保留原始
variable inspector，读取时动态解引用，因此赋值后不需要重建 inspection path。

`debugger-mode` 是 interface mode，其 Buffer 是 session 与 InspectorNode 状态的
只读文本投影。投影包含异常来源、`who`、message、irritants、frame 列表、选中
frame 的 locals、可用 action，以及当前 InspectorNode 的 path、type、capabilities、
preview 和带序号的 children。continuation 的 children 是 frame；frame 进一步
暴露 pending call、procedure code、closure、source、局部变量和自由变量。选择
frame 或 InspectorNode 后重新生成投影，caret 跟随选中的 frame 行。每个 debugger
使用独立的 generated resource，因此不同 interaction 的失败状态可以同时保留。

每个可恢复或终止的操作由 `DebuggerAction` 描述。descriptor 包含稳定 id、显示
名称、说明、`resume | restart | terminate` 类别、参数规格、执行 command 和
default 标记。同一 action set 的 id 唯一，且至多一个 action 是默认项。
`DebuggerActionParameter` 使用 `none | expression | source` 表示参数类型，并为
带参数的 action 提供 prompt、默认值和 validator。默认值可以是字符串，也可以根据
执行上下文延迟计算；validator 在打开 prompt 和接受结果时都使用同一份执行上下文
校验字符串。

`DebuggerActionContext` 捕获 editor、interaction session、debugger、选中 frame、
condition、continuation、action 和参数。action 被选中时固定 frame、condition 与
continuation；参数 prompt 的回调携带该 context，不从当前 View 或全局 debugger
重新发现目标。action command 只通过 command argument 接收 context，并在执行前
确认 debugger 仍属于对应 editor 或 interaction session、action id 仍存在且
command 未被替换。

`DebuggerSession` 持有 action set；Buffer、minibuffer picker 和命令校验读取该
集合，不根据 session state 重复推导操作。Editor 的具名 action provider registry
允许扩展根据创建上下文返回一个 action、action 列表或 `#f`。创建 debugger 时先
安装状态监听器，再按注册顺序应用 provider，然后运行 `debugger-created` hook，
最后创建或激活 Buffer。provider 适合声明 condition-specific action；hook 可以
完成依赖完整 debugger session 的初始化。扩展通过
`debugger-session-register-action!` 添加或替换 descriptor，
`debugger-session-set-actions!` 原子替换完整 action set。

每个 `DebuggerSession` 保存单调递增的 revision。action set、frame selection、
frame-relative evaluation、Inspector path、赋值和 apply 结果发生变化时推进
revision，并同步通知 editor adapter。adapter 将 session 状态重新投影到已有
debugger Buffer，因此扩展修改 session 后不需要调用刷新函数。Buffer identity、
返回位置和关闭清理属于生命周期状态，不参与该投影 revision。

condition failure 提供默认的 `retry`、有 continuation 时的 `use-value`、
`edit-and-retry` 和 `abort`。suspended evaluation 提供默认的 `continue`、`retry`、
`edit-and-retry` 和 `abort`。源码 stop 额外提供 `step`、`next` 和 `finish`。
Editor command condition 提供 `dismiss`。默认 action 在模糊排序前具有 selection
priority，因此 picker 初始选择与 Buffer 中的 `>` 标记一致。

## 源码断点与步进

evaluator 使用 Chez annotated reader 读取交互 request 和源码文件，并在可执行
expression 前插入 source probe。probe 保存 resource 与 UTF-8 byte range；顶层
definition 中的 probe 通过 evaluator environment 动态取得当前
`EvaluationControl`，因此文件加载完成后调用该 definition 仍能参与后续 task 的
调试。Inspector information 与关闭 CP0 源级优化的编译策略同时用于异常 continuation
和源码步进。

源码断点由 evaluator 的 `SourceDebugController` 持有，不依附某个 Buffer 或
InteractionSession。断点位置是 resource 中的一段行范围；probe 的起点位于该范围
时命中。`F9` 执行 `scheme.debug-toggle-breakpoint`，在当前 View 所在物理行切换
断点。`scheme.debug-list-breakpoints` 把所有断点投影到只读
`*scheme-breakpoints*` Buffer。关闭源码 Buffer 不移除断点。

probe 命中断点时捕获当前位置的 continuation 和 continuation depth，并显式
`engine-block`。task 把该 stop 转成带 `SourceDebugStop` 的 suspended result，
DebuggerSession 继续使用普通 condition、frame、action 与 revision 模型。恢复操作
复用原 EvaluationTask 和 engine：

- `continue` 清除步进计划并恢复执行；
- `step` 在下一个不同的 probe 停止，包括进入被调用 procedure；
- `next` 在下一个不同且 continuation depth 不深于当前位置的 probe 停止；
- `finish` 在下一个 continuation depth 浅于当前位置的 probe 停止。

断点恢复时暂时抑制同一断点，执行离开该行后恢复匹配，避免 continue 立即再次停在
同一个 probe。源码 stop 的 resource 与 byte range 优先于 continuation frame 的
source metadata，`scheme.debug-visit-source` 使用已有 Buffer 或异步 VFS open 定位
该范围。

源码 probe 覆盖 evaluator 读取的 source forms。预编译 vfasl、native procedure
和 FFI 调用没有 Scheme source probe；这些帧仍可由 Chez continuation inspector
检查。

失败状态提供以下动作：

- `scheme.debug-open` 打开或重新激活 debugger Buffer；
- `scheme.debug-next-frame` 与 `scheme.debug-previous-frame` 循环选择 frame，接受
  prefix count；
- `scheme.debug-eval-frame` 通过 minibuffer 读取一个 datum，并使用选中 frame 的
  inspector environment 求值；
- frame 求值结果保存在 debugger Buffer 中，并作为 Chez inspector object 的根。
  `scheme.debug-inspect-condition` 把原始 condition 设为 inspector 根对象；
  `scheme.debug-inspect-local` 直接选择当前 frame 中按序号标识的局部值；
  `scheme.debug-inspect-ref` 按子项序号进入 pair、vector、record、procedure 等对象，
  `scheme.debug-inspect-up` 返回父对象，`scheme.debug-inspect-top` 返回当前根；
  `scheme.debug-inspect-code`、`scheme.debug-inspect-call`、
  `scheme.debug-inspect-closure` 和 `scheme.debug-inspect-source` 选择节点公开的
  专用 child。每个 child 保存对象内稳定的逻辑 index；Buffer 每次显示固定大小的
  page，`scheme.debug-inspect-next-page` 和
  `scheme.debug-inspect-previous-page` 只移动显示窗口，因此跨页后
  `scheme.debug-inspect-ref` 的参数含义保持不变；
- `scheme.debug-inspect-print` 使用 Chez Inspector 的 `print` 操作生成 pretty
  representation，`scheme.debug-inspect-write` 使用 `write` 生成可写表示；完整结果
  保存在 debugger session 中并投影到 Buffer，对象预览仍保持有界；
- `scheme.debug-inspect-find` 在选中 frame 中求值一元 predicate，并通过 Chez
  object finder 搜索当前对象可达图。匹配结果到搜索根的对象路径成为 Inspector
  path，因此 `up` 和 `top` 继续可用；`scheme.debug-inspect-find-next` 复用 finder
  的遍历状态查找下一个匹配对象；
- `scheme.debug-set-value` 在选中 frame 中求值 replacement expression，并通过
  assignable variable inspector 更新局部值；
- `scheme.debug-apply` 在选中 frame 中求值一个 procedure，并把当前对象传给它。
  普通对象的结果成为新的 InspectorNode 根；continuation application 作为
  evaluation resume request 进入 engine。transformer 可以直接调用 continuation，
  也可以返回一个或多个 replacement value，由 engine 传给 continuation；
- `scheme.debug-visit-source` 通过异步 VFS open request 打开选中 frame 的 source
  path，并按行与字符位置定位 caret；
- `scheme.debug-continue` 恢复用户中断时保存的 engine；
- `scheme.debug-step`、`scheme.debug-next` 与 `scheme.debug-finish` 按当前
  SourceDebugStop 安装步进计划并恢复同一个 engine；
- `scheme.debug-use-value` 在选中 frame 中求值 replacement expression，把产生的
  多值传给 condition continuation，并在新的 engine 中继续原计算；
- `scheme.debug-retry` 关闭当前 debugger，使用新的 generation 重放原始 source
  和 origin；
- `scheme.debug-edit-and-retry` 读取替换后的 source，并以新的 generation 求值；
- `scheme.debug-action` 接受 action id 直接执行，未提供 id 时用 minibuffer 展示
  当前 session 的 action set；picker 根据 descriptor 的 command 调用同一组
  interactive command；
- `scheme.debug-exit` 关闭 debugger Buffer 并返回触发异常的 Buffer，同时保留
  condition、continuation 和 frame inspector；
- `scheme.debug-discard` 释放 debugger Buffer、condition 与 continuation；对
  interaction failure 同时退出 `failed` 状态，对 suspended evaluation 同时释放
  保存的 engine。

debugger Buffer 的 `n`、`p`、`e`、`i`、`k`、`l`、`d`、`u`、`t`、`[`、`]`、
`P`、`W`、`/`、`N`、`!`、`a`、`v`、`c`、`s`、`o`、`f`、`r`、`=`、`x`、`q`
分别映射到 frame 导航、求值、检查 condition、检查 continuation、检查局部值、
进入子项、返回父节点、返回根节点、Inspector 分页、print、write、find、
find-next、设置变量、应用 procedure、源码访问、继续、step、next、finish、
action selector、replacement value、保留退出与丢弃操作。
源码访问复用普通 `file.read` effect，文件
读取期间 command loop 保持可用；打开完成后 debugger 状态仍可重新激活。重试和
丢弃会先把所有显示 debugger Buffer 的 View 切回来源 Buffer。Editor 关闭时释放
Editor 与 interaction 持有的所有 debugger continuation。frame inspection 和
frame-relative evaluation 都作为普通 command 执行，不接管 terminal stdin，也
不进入递归 command loop。

求值产生的顶层 binding 保存在 session 的 Chez environment 中。evaluator 按
generation 分别缓存完整 environment catalog 和相对初始 environment 的 runtime
catalog；一次求值或文件加载使旧 catalog 失效，下一次对应查询重新枚举
environment。catalog 保存 binding kind、有限深度的 value preview、generation
和 procedure signature formals，不持有 transcript range。procedure formals 从 Chez
arity mask 投影：有限 bit 产生固定 arity，负数高位产生 dotted rest arity，
`case-lambda` 的离散分支保持为多个 formals。

`scheme-repl` completion provider 将当前 InteractionSession 的完整 environment
投影为通用 `CompletionItem`；它不从 transcript 文本恢复 binding。普通 Scheme
Buffer 同时使用 `scheme-static` 与 `scheme-runtime`，后者只提供 Editor evaluator
中相对初始 environment 新增的 binding。symbol inspection 和 signature help 在
静态索引没有定义时查询同一 runtime catalog。runtime procedure completion 的
annotation 使用首个 signature；signature help 显示全部 arity 分支和当前参数位置。
静态 Scheme semantic provider 的职责与组合边界见
[11-scheme-semantics.md](11-scheme-semantics.md)。
