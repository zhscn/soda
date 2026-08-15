# Soda 自包含分布式编程环境

## 目的

Soda 是一个随应用一起分发的分布式编程环境。单个原生可执行文件包含 Chez
Scheme 运行时、基础 Scheme libraries、编辑器内核、静态分析、补全、REPL、检查器、
调试器和 TUI 呈现能力。相同的程序可以作为交互式工作台、无界面控制端或计算节点
启动。

系统把分布式节点视为可连接、可编程、可检查的 Scheme runtime，而不是只能接受固定
命令的黑盒执行器。开发者可以从工作台编辑代码，把定义加载到一个运行时或一组运行时，
执行分布式计算，并在远端计算发生 condition 时回到对应源码、栈帧和对象检查界面。

这一设计覆盖以下能力：

- 自包含、多平台的原生发行物；
- 本地与远端持久 Scheme session；
- 静态语义与运行时 binding 共同驱动的开发体验；
- 版本化代码分发和增量开发 overlay；
- worker pool、分布式 task 和结果流；
- 远端 condition、栈帧、对象检查和恢复动作；
- TUI、headless client 和自动化程序共享的开发协议。

系统不把任意 Scheme heap 复制、迁移或持久化。跨节点边界传递可移植值、代码标识、
task 和带生命周期的远端对象引用。

## 设计原则

### 发行物就是开发环境

目标平台只需要一个与其 ABI 匹配的 Soda 原生可执行文件。Linux 发行物把 boot 和资源嵌入 ELF；
其他平台使用对应的原生 executable container。基础 boot、默认 capsule、开发协议、
语言工具和 TUI 资源属于同一个版本化发行物。节点不依赖系统安装的 Scheme、用户级包目录
或外部编辑器配置。

### 运行时保持可进入

每个被授权的 runtime 都可以创建开发 session。session 支持求值、加载源码、枚举 binding、
补全、检查值、中断计算和调试 condition。远端计算使用与本地 REPL 相同的求值和诊断模型。

### 稳定代码与交互修改分层

不可变 capsule 承载可复现的程序代码。session overlay 承载增量定义和实验性修改。task 固定
到明确的 `CodeContext`，避免执行过程中因工作台继续加载代码而漂移。

### 状态通过值和消息跨边界

节点、session、task、condition、栈帧和远端对象都有显式 identity。消息携带 generation、
sequence 和 source identity。接收方校验 identity 后再应用结果，不从当前焦点或当前连接推断
原始目标。

### 外部工作位于 effect 边界

网络、进程、文件、timer 和持久存储通过 effect 执行。Scheme command 和 task scheduler 产生
值描述的操作；runtime adapter 执行外部工作，并把完成事件重新排入消息循环。

### TUI 是协议的一个前端

TUI 使用 Buffer、View、Window、command、effect 和不可变 Frame 呈现分布式系统。headless
client 和自动化程序使用相同协议和运行时操作。业务行为不依赖终端 escape sequence、当前
布局或活动 View。

## 系统形态

```text
                         development client
             ┌──────────────────────────────────┐
             │ Soda workbench                   │
             │ editor / analysis / REPL / TUI   │
             │ inspector / debugger / scheduler │
             └───────────────┬──────────────────┘
                             │ development protocol
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
       ┌────────────┐  ┌────────────┐  ┌────────────┐
       │ runtime A  │  │ runtime B  │  │ runtime C  │
       │ sessions   │  │ sessions   │  │ sessions   │
       │ task slots │  │ task slots │  │ task slots │
       │ object refs│  │ object refs│  │ object refs│
       └────────────┘  └────────────┘  └────────────┘
              │              │              │
              └──────────────┴──────────────┘
                         worker pools
```

工作台和计算节点运行相同的 Scheme 协议实现。启动 profile 决定进程安装的 capability、服务和
前端，不改变 capsule 格式、session 语义或 task 协议。

## 原生发行物

平台发行物是一个原生 executable，包含：

```text
Soda executable container
├── Chez petite boot
├── Chez scheme boot
├── Soda core boot
├── default capsule
├── static analysis and documentation index
├── TUI runtime resources
└── native ABI implementations
```

C launcher 注册嵌入 boot 和 native foreign symbols，构造 Chez heap，然后进入由启动 profile
选择的 Scheme startup procedure。Scheme 是应用的组合根；native 代码提供 terminal、socket、
process、timer、文件监听、文本存储和语言机制等有界能力。

每个平台拥有独立构建的 executable。Scheme 源 capsule 可以跨支持的平台分发；native object、
预编译 Scheme code 和包含 FFI 的 capsule variant 带有明确的平台、Chez 版本和 native ABI
约束。

## 启动 profile

同一发行物支持以下 profile：

| Profile | 责任 |
|---|---|
| `workbench` | 启动完整编辑器、分析器、REPL、检查器、调试器、scheduler 和 TUI |
| `controller` | 启动无界面 session manager、scheduler 和开发协议 client/server |
| `runtime` | 接受开发 session，维护 capsule cache，并执行受授权的求值与 task |
| `worker` | 只安装计算、代码同步和结果流 capability |
| `attach` | 启动临时工作台并连接本地或远端 runtime |

profile 是 capability 组合，不是不同的数据模型。一个进程可以同时拥有 controller 与 runtime
能力；生产 worker 可以只暴露 task 和 capsule 操作。

## 核心实体

### Node

`Node` 是可寻址的机器或隔离执行环境描述：

```text
Node {
  node_id,
  endpoint,
  labels,
  trust_domain,
  platform,
  advertised_profiles
}
```

`node_id` 是配置身份。一次进程启动另外产生不可复用的 `runtime_id`。连接断开后出现新的
`runtime_id` 表示 runtime 已重启，旧 session、栈帧和远端对象引用全部失效。

### RuntimeInstance

`RuntimeInstance` 是一个活动的 Chez 进程：

```text
RuntimeInstance {
  node_id,
  runtime_id,
  protocol_version,
  platform,
  boot_digest,
  native_abi,
  capabilities,
  loaded_capsules,
  available_slots
}
```

runtime 通过握手发布不可变快照。后续 capability 或 slot 变化作为带 generation 的事件发布。

### DevelopmentSession

`DevelopmentSession` 是一个持久求值上下文：

```text
DevelopmentSession {
  session_id,
  runtime_id,
  owner,
  base_capsule_digest,
  overlay_id,
  overlay_head_digest,
  environment,
  overlay_generation,
  binding_generation,
  object_table,
  active_evaluations,
  capabilities
}
```

session 串行处理会改变其 environment 的求值。多个 session 不共享可变 top-level environment。
library 实例、显式共享服务和外部资源可以按 capsule contract 共享。

### CodeContext

`CodeContext` 唯一标识一次求值或 task 使用的代码集合：

```text
CodeContext {
  capsule_digest,
  overlay_id?,
  overlay_generation,
  overlay_head_digest?
}
```

没有 overlay 时 generation 为零，overlay identity 与 head digest 均为空。`overlay_id + generation +
head digest` 标识一条确定的有序更新前缀；两个 session 即使具有相同 generation，也不能交换不同
overlay identity 或内容的代码。runtime 为每个活动 CodeContext 建立独立 execution namespace，
task 和调试信息都保存该值。

### WorkerPool

`WorkerPool` 是 scheduler 使用的逻辑 runtime 集合：

```text
WorkerPool {
  pool_id,
  selector,
  desired_code_context,
  scheduling_policy,
  retry_policy,
  resource_limits
}
```

selector 根据 Node label、platform 和 capability 解析成员。一次调度使用冻结的 membership
snapshot；成员变化影响后续分配，不改变已经提交的 task identity。

### Task

`Task` 是可调度的计算请求：

```text
Task {
  task_id,
  pool_id,
  code_context,
  entry,
  arguments,
  capability_set,
  replay_class,
  deadline,
  resource_limits
}
```

`entry` 引用 CodeContext 导出的 procedure，或引用被开发 capability 允许的 session form。正式
task 使用导出 procedure，使 scheduler 可以验证入口、参数 metadata 和代码版本。

### RemoteReference

不可按值传输的对象使用远端引用：

```text
RemoteReference {
  node_id,
  runtime_id,
  session_id,
  object_id,
  object_generation,
  preview,
  kind,
  lease
}
```

procedure、port、continuation、condition、栈帧、大型或循环对象可以返回远端引用。引用只支持
协议声明的 inspect 操作，不能被本地 Scheme 当作原对象调用。

## Capsule 与代码分发

### Capsule 内容

Capsule 是不可变、内容寻址的程序单元：

```text
CapsuleManifest {
  format_version,
  digest,
  name,
  version,
  required_boot_digest,
  required_native_abi,
  libraries,
  exported_entries,
  source_index,
  documentation_index,
  analysis_index,
  runtime_resources,
  native_variants,
  requested_capabilities
}
```

digest 覆盖移除 `digest` 字段后的规范 manifest 和全部逻辑内容。传输层可以压缩 capsule，但
解压后的规范内容必须得到相同 digest。runtime 先写入临时 cache entry，完整验证 digest、签名和
ABI 后再原子发布。

签名位于 capsule envelope 中，不参与 capsule digest。签名内容包含 capsule digest、签发者、
签名算法和 policy identity，避免签名字段与被签名内容形成循环依赖。

默认 capsule 随 executable 嵌入。额外 capsule 可以从本地文件、控制端或内容寻址存储获取。

### 源码与预编译代码

Capsule 保存足以支持源码定位、分析和目标节点编译的 Scheme source。平台 variant 可以附带
预编译代码以缩短加载时间。runtime 只在以下标识全部匹配时使用预编译 variant：

- target architecture 与 operating system；
- Chez machine type 与编译器版本；
- boot digest；
- native ABI digest；
- capsule digest。

不匹配时，runtime 从源码构建本地 cache。编译结果是 cache，不改变 capsule identity。

### Session overlay

overlay 是 session 上有序的源码更新序列：

```text
OverlayEntry {
  overlay_id,
  author_session_id,
  sequence,
  previous_generation,
  previous_digest,
  source_resource,
  source_revision,
  source_range,
  form,
  form_digest,
  entry_digest
}
```

runtime 只在 `previous_generation` 等于该 overlay 当前 generation 时应用 entry。读取、展开、编译
或求值失败时，generation 不前进，并返回结构化 condition。`entry_digest` 覆盖 overlay identity、
sequence、previous digest、source identity 和 form digest，形成可验证的 hash chain。成功后
generation 增一、head digest 更新为 entry digest、binding catalog 更新，并返回新的 CodeContext。

overlay 修改 session top-level binding，不原地改写不可变 capsule。library 更新加载到新的版本化
namespace，验证成功后 session 原子切换其显式 library set。已经运行的 evaluation 和 task 继续
使用提交时固定的 CodeContext。

### Pool 收敛

worker 在接受 task 前满足以下代码前置条件：

```text
loaded capsule digest = task code context capsule digest
loaded overlay identity = task code context overlay identity
applied overlay generation = task code context overlay generation
applied overlay head digest = task code context overlay head digest
native ABI satisfies capsule manifest
capabilities include task capability set
```

缺少 capsule 时，worker 先拉取并验证 capsule。需要开发 overlay 时，worker 按 sequence 获取缺失
entry。任一前置条件不能满足时，worker 拒绝 task，不执行降级版本。

## 求值模型

### Environment

session 从 capsule 声明的基础 environment 创建独立可变 top-level environment。基础 environment
只包含该 profile 和 session capability 允许的 libraries。library search handler 对可导入集合执行
allowlist 校验。

工作台源码求值携带 `EvaluationOrigin`：

```text
EvaluationOrigin {
  resource,
  document_id,
  revision,
  start,
  end,
  capsule_digest?,
  overlay_id?,
  overlay_generation,
  overlay_head_digest?
}
```

condition、栈帧和定义 metadata 保留 origin，使工作台能在 Buffer revision 仍匹配时定位原始范围；
revision 不匹配时使用 capsule source snapshot 打开只读源码。

### 执行和中断

每个 runtime 只有一个拥有 Scheme 应用状态的 command-loop thread。交互式 evaluation 使用 Chez
engine 分片执行，在多个 event-loop turn 之间让出控制。网络和进程完成事件只能通过消息队列
更新 session。

一次 evaluation 的生命周期为：

```text
queued -> compiling -> running -> suspended -> running
                              \-> completed
                              \-> failed
                              \-> interrupted
```

`interrupt` 设置 evaluation control 并在下一个安全分片边界终止计算。阻塞式 native 调用不得在
evaluation stack 上执行；它必须转换为 effect 或运行在隔离 worker process 中。

CPU 并行由多个 worker process 提供。一个节点可以由 supervisor 启动多个 slot，每个 slot 有独立
Chez heap、runtime identity 子标识和资源限制。该模型为全局可变状态、端口、condition 和崩溃提供
进程隔离。

### 输出

stdout、stderr、structured value、progress 和 diagnostic 都是 evaluation event。每个 evaluation
维护单调递增的 sequence。工作台按 sequence 提交 transcript；重连后从已确认 sequence 继续订阅。

输出受到单条消息大小、累计未确认字节数和事件速率限制。producer 在窗口耗尽时暂停，或按照 task
声明的策略把大结果写入 artifact store 并返回引用。

## 开发协议

### 线协议

开发协议采用 nREPL 的 request/response 模型和 bencode framing。每个请求至少包含：

```text
{
  "id": request identity,
  "op": operation name,
  "session": optional session identity
}
```

每个响应回显 `id` 和 `session`，并可以包含 `seq`、`value`、`out`、`err`、`condition`、`data`
与 `status`。一个请求可以产生多个响应；包含 `done` status 的响应结束该请求。

bencode byte string 保存 UTF-8 文本或显式标注的 binary payload。结构化 Scheme 值使用 portable
value encoding，不使用 Scheme reader 直接读取不受信任的网络文本。协议实现限制 nesting depth、
容器长度、整数范围和总消息大小。

### 连接与握手

连接先执行 `describe`。响应包含：

- 协议版本和支持的 operation；
- node、runtime 和 boot identity；
- platform、native ABI 和已加载 capsule；
- 可申请的 session capability；
- 消息、流和对象 lease 限制；
- runtime profile 和可用 worker slot。

client 根据响应构造 `RuntimeInstance` snapshot。协议 major version 不兼容时连接终止；minor
能力通过 operation discovery 协商。

### 基础 operation

协议提供与通用 nREPL client 兼容的基础 operation：

| Operation | 语义 |
|---|---|
| `clone` | 从授权的基础 environment 创建 session |
| `close` | 关闭 session 并释放 owner resources |
| `describe` | 查询协议、runtime 和 operation metadata |
| `eval` | 在 session 中求值源码并流式返回结果 |
| `interrupt` | 中断指定 evaluation |
| `load-file` | 以明确 source identity 加载一份源码 |

Scheme namespace、值打印和 condition 字段通过响应 metadata 描述，不借用其他语言的 namespace
语义。

### Soda operation

扩展 operation 使用 `soda/` 前缀：

| 类别 | Operation |
|---|---|
| 代码 | `soda/has-capsule`、`soda/put-capsule`、`soda/apply-overlay`、`soda/bindings` |
| 发现 | `soda/complete`、`soda/describe-binding`、`soda/source-location` |
| 检查 | `soda/inspect`、`soda/inspect-range`、`soda/release-reference` |
| 调试 | `soda/frames`、`soda/frame-locals`、`soda/eval-in-frame`、`soda/resume`、`soda/abort` |
| 计算 | `soda/spawn-task`、`soda/cancel-task`、`soda/task-status`、`soda/subscribe-task` |
| 集群 | `soda/list-nodes`、`soda/list-runtimes`、`soda/list-pools`、`soda/pool-events` |

每个 operation 的 `describe` metadata 包含参数 schema、响应 schema、所需 capability、是否会产生
外部 effect，以及可用的 documentation。工作台使用同一 metadata 生成补全、命令说明和交互式
参数读取器。

### Multiplexing

单个连接可以承载多个 session 和请求。`id + session` 唯一标识请求；`evaluation_id`、`task_id`
和 `subscription_id` 标识长生命周期活动。消息可以交错到达，client 按 identity 分派，不能依赖
网络到达顺序关联不同请求。

断线不会自动销毁可恢复 session。session policy 决定 detach lease；lease 内重连可以继续订阅
输出。显式 `close`、lease 到期、owner 关闭或 runtime 退出会释放 session。

## Portable value

协议按值支持以下数据：

- boolean、integer、有限精度与精确 number 的规范文本；
- character、symbol、string 和 bytevector；
- proper list、vector 和非循环的 string-keyed map；
- 带公开 tag 和字段的 portable record；
- source location、diagnostic、task result 等协议记录。

编码器检测共享和循环结构。小型共享不可变值可以展开；循环值、超过阈值的值和不支持的对象返回
`RemoteReference`。响应同时提供有界 `preview`，保证 TUI 不必先递归检查对象才能显示结果。

## 静态分析与可发现性

### 分析输入

工作台分析器读取：

- 当前 Buffer 的源码和 revision；
- capsule 中的 library source、export 和 analysis index；
- boot API index 与 documentation；
- session overlay source；
- runtime 发布的 binding catalog；
- protocol operation 与 capability metadata。

静态 snapshot 以 document identity 和 revision 为键。runtime catalog 以 runtime、session 和
binding generation 为键。异步结果只有在这些 identity 仍匹配时才能进入 completion 或
diagnostic state。

### Completion 合成

Scheme completion 按以下语义来源合成候选：

1. 当前 lexical scope；
2. 当前 library import；
3. capsule export 与 boot API；
4. session overlay binding；
5. runtime top-level binding；
6. 当前上下文允许的 node、pool、capability 和远端 entry metadata。

候选保留来源、kind、签名、documentation、source location、capsule digest 和 binding generation。
同名 lexical binding 屏蔽外层候选；静态与运行时 metadata 指向同一 binding 时合并展示。

### API 声明

公开分布式 API 使用普通 Scheme library、record 和声明宏。一次声明同时产生 runtime binding、
contract、documentation 和分析 metadata。例如：

```scheme
(define-distributed-procedure (square value)
  (documentation "Return VALUE squared.")
  (arguments [value number?])
  (result number?)
  (capabilities)
  (* value value))
```

`define-distributed-procedure` 导出稳定 entry name。task 发送 entry name 与 portable arguments，
worker 从固定 capsule namespace 解析 procedure。声明不捕获 session 中未进入 capsule 的隐式值。

### Tree-sitter provider

语言 package 可以使用 Tree-sitter 提供增量 CST、语法诊断、结构导航和局部 scope 线索。完整类型
推导不是加入工作台的前置条件。结构分析、library/export metadata、API schema 和 runtime binding
catalog 可以共同提供可用的补全与跳转。

## TUI 呈现

分布式界面使用普通 Soda UI 实体：

| 内容 | Buffer 语义 |
|---|---|
| Scheme source | 可编辑、带静态语义和 CodeContext 的文件 Buffer |
| REPL transcript | 具有 input field、输出流和 session identity 的 generated Buffer |
| Node/Runtime 列表 | 从 catalog snapshot 投影的列表 Buffer |
| Worker pool | 展示成员、CodeContext、slot 和 capability 的列表 Buffer |
| Task 列表 | 展示生命周期、目标、重试和进度的列表 Buffer |
| Inspector | 以远端引用和 object generation 为数据源的惰性展开 Buffer |
| Debugger | 展示 condition、frame、locals 和恢复动作的临时 Buffer |
| Event stream | 可过滤、可定位来源的 append-only generated Buffer |

一个 Buffer 可以在多个 View 中呈现；每个 View 独立保存选择、viewport、展开状态和输入状态。
Window 只负责 View 在 Surface 上的布局。远端 identity 属于 Buffer extension state 或对应 package
session，不属于 terminal frontend。

命令通过冻结的 `CommandContext` 取得 node、runtime、session、task 或远端引用 target。异步响应
使用保存的 target identity 恢复，不使用响应到达时的活动窗口。TUI frontend 只把不可变 Frame
提交给 presenter。

### 交互工作流

工作台支持以下连续工作流：

```text
open source
  -> static analysis and completion
  -> select runtime or pool
  -> evaluate form / apply overlay
  -> stream output into transcript
  -> inspect returned value
  -> open remote condition and frames
  -> resume, abort, or edit and evaluate again
```

源码、REPL、检查器和调试器共享 navigation identity。跳转到远端 frame 时优先打开同 digest 的
本地源码；本地 revision 不匹配时打开 capsule snapshot，避免把栈帧错误映射到已修改文本。

## 分布式计算

### Task 生命周期

```text
created -> queued -> assigned -> preparing-code -> running
                                             \-> completed
                                             \-> failed
                                             \-> cancelled
                                             \-> lost
```

scheduler 是 task identity 和生命周期的唯一写入者。worker 发布 attempt event；scheduler 把合法
attempt event 归并为 task state。迟到的旧 attempt 事件保留在诊断日志中，但不能覆盖新 attempt
状态。

### Attempt 与重放

每次分配产生独立 `attempt_id`。task 声明以下 replay class：

| Replay class | 语义 |
|---|---|
| `pure` | 结果只由固定代码和参数决定，可以自动换 worker 重试 |
| `idempotent` | 外部 effect 使用 task 提供的 idempotency key，可以按 policy 重试 |
| `at-most-once` | 连接丢失后结果为 unknown，除非 worker 以相同 runtime identity 恢复 |

系统不承诺跨任意外部系统的 exactly-once。具有外部 effect 的 procedure 必须选择 replay class，
并在 documentation 中公开幂等要求。

### 调度

scheduler 先按 platform、capsule、capability 和 resource limit 过滤 slot，再应用 pool scheduling
policy。默认 policy 在符合条件的空闲 slot 中轮转，并限制每个 node 的并发。代码准备属于 attempt
生命周期但不消耗 procedure 的 execution timeout。

取消首先向活动 worker 发送 cooperative interrupt。超过 grace period 后，supervisor 终止承载该
task 的隔离 worker process。process 终止使其中全部 session 和远端引用失效，并产生结构化退出
事件。

### 组合 API

map、reduce、broadcast、pipeline 和持续状态计算是普通 Scheme library，建立在 `Task` 与事件流
之上：

```scheme
(distributed-map pool 'analysis/scan inputs)

(distributed-reduce
  pool
  'analysis/scan
  inputs
  initial-state
  combine-result)
```

组合器保存输入位置与 task identity，使结果到达顺序不改变 ordered map 的返回顺序。streaming
组合器按窗口向 worker 发放任务并向 reducer 提供批量结果，避免未处理结果无限积累。

## Condition、调试与检查

### Debug stop

未处理 condition 可以结束 evaluation，也可以在 session policy 允许时创建 `DebugStop`：

```text
DebugStop {
  stop_id,
  session_id,
  evaluation_id,
  condition_reference,
  summary,
  frames,
  available_actions,
  code_context,
  lease
}
```

worker 暂停对应 engine 并返回 stop。其他 session 和 runtime event 继续运行。工作台打开 debugger
Buffer，并按需获取 frame locals 和对象内容。

### Frame

Frame metadata 包含稳定 frame id、procedure preview、source location、CodeContext 和有限数量的
local binding preview。完整 local 值通过 `soda/frame-locals` 惰性读取。`soda/eval-in-frame` 只在
stop 仍存活且 frame identity 匹配时执行。

### 恢复动作

runtime 只发布当前 stop 实际支持的动作，例如 continue、use-values、retry、step、next、finish 或
abort。client 不假定任意 condition 都可恢复。动作请求携带 stop generation；重复或过期请求被拒绝。

### 对象检查

检查器按页读取 record field、pair、vector、hashtable、procedure metadata 和自定义 inspector
projection。一次请求限定最大深度和元素范围。自定义 projection 由 capsule 注册，并在对象所属
runtime 执行；返回结果仍必须是 portable value 或新的远端引用。

## 持久化与恢复

### 持久状态

以下状态具有可持久表示：

- node catalog 与 worker pool 定义；
- capsule manifest、内容和签名；
- task spec、attempt、状态转换和结果 artifact；
- session descriptor 与经过确认的 overlay source journal；
- client 对输出 sequence 的确认位置；
- workspace 中打开的资源、布局和 navigation state。

task journal 采用 append-only 状态事件，并为查询维护可重建索引。状态转换包含预期 previous state，
重复事件按 identity 去重。

### 临时状态

Chez heap、continuation、开放 port、栈帧、任意 closure 和远端对象 table 是临时状态。runtime 重启
后不恢复这些对象。可恢复 session 通过重新加载 base capsule 和 overlay source journal 构造新的
environment，并获得新的 runtime 与 session generation。

### Controller 恢复

controller 启动后重放 task journal，连接已知 runtime，并以 `task_id + attempt_id` 查询仍活动的
attempt。worker 能证明 attempt 仍在运行时，controller 继续订阅；否则按 replay class 进入 retry、
unknown 或 failed 状态。

## 安全模型

远程求值是显式授予的高权限能力。协议端点只在以下 transport 上提供服务：

- 本地 Unix domain socket；
- SSH 转发连接；
- 具有双向身份认证的加密网络连接。

握手身份映射到 capability policy。主要 capability 包括：

```text
session:create
eval:interactive
code:upload
code:overlay
inspect:objects
debug:control
task:submit
task:cancel
process:spawn
filesystem:read
filesystem:write
network:connect
native:load
```

session environment 只暴露授予 capability 对应的 library 和 service。Scheme allowlist 用于减少误用
和定义 API 边界；它不是针对恶意代码的强隔离边界。执行不受信任或外部提供的代码时，worker
process 还必须使用操作系统级用户、namespace、文件系统、网络和资源限制进行隔离。

Capsule 可以要求签名和发行者 policy。worker 在加载前验证 digest、签名、requested capability
与 native variant。secret 通过运行时 capability handle 提供，不写入 capsule、task argument、
transcript、condition preview 或持久 journal。

所有远程 eval、overlay、capsule load、task submission、debug action 和 capability decision 产生
带 principal、target identity、source digest 和结果状态的审计事件。

## 生命周期与所有权

长生命周期资源都有 `Owner`：

- connection owner 持有 transport、subscription 和 reconnect state；
- session owner 持有 environment、evaluation、object table 和 debug stop；
- capsule owner 持有动态 library registration 和 runtime resource；
- task owner 持有 attempt、output stream 和 artifact lease；
- TUI Buffer owner 持有对应的 package listener 和 presentation session。

关闭 owner 按依赖逆序取消活动工作、停止事件发布、注销 callback、释放远端 lease，并关闭 native
handle。cleanup 中单个失败不能阻止后续资源获得清理机会；所有失败最终汇总为结构化 condition。

## 分层所有权

这一系统遵守 Soda 的层边界：

- `kernel` 保存不可变编辑状态、transaction 和纯坐标语义，不包含 socket、node catalog 或
  scheduler；
- `host` 管理 Buffer、View、Surface、command、effect、Owner 和 runtime service；
- 分布式 package 通过 `PackageHost` 注册命令、effect handler、task service 和 UI projection；
- `view` 只把状态投影成 Frame、decoration 和 display value；
- `tui` 只负责输入解码、Frame 呈现和 frontend orchestration；
- native runtime 提供 socket、process、timer、TLS adapter 和 descriptor readiness，不保存 Scheme
  对象，也不从 native callback 进入 Scheme。

分布式 package 不访问 `host/internal`，不直接改变 Surface，也不让协议 callback 修改 Buffer。
网络事件转换为 immutable message 后进入 command loop，由 package command 或 transaction 发布
编辑器变化。

## Package 接口

分布式能力以可替换 service 暴露给功能 package：

```text
RuntimeCatalog
  connect, disconnect, snapshot, subscribe

SessionService
  create, close, evaluate, interrupt, apply-overlay

CapsuleService
  resolve, verify, publish, ensure-loaded

TaskService
  submit, cancel, status, subscribe

InspectionService
  inspect, frames, frame-locals, resume, release
```

公开操作接收 immutable request 并返回 outcome、effect 或 subscription identity。service 不暴露内部
hashtable、connection 或 mutable scheduler。package-owned registration 绑定 Owner。

## 端到端契约

一个完整的 Soda 分布式编程环境提供如下闭环：

1. 对应平台的单个 executable 能以 workbench 或 runtime profile 启动。
2. workbench 通过认证连接 runtime，并取得 boot、capsule、capability 和 source metadata。
3. 编辑 Buffer 在本地完成静态分析、补全、跳转和 documentation 查询。
4. 用户把一个 form 应用为 session overlay，runtime 返回新的 CodeContext 与 binding generation。
5. 同一 entry 可以在单个 session 或 worker pool 上执行，输出以有序事件进入 transcript。
6. 新 worker 在执行前取得相同 CodeContext，包括 capsule、overlay identity、generation 与 head digest。
7. 远端 condition 在工作台中打开匹配源码、栈帧、locals、检查器和可用恢复动作。
8. task、输出订阅和可恢复 session 在连接中断后按 identity 与 sequence 继续。
9. runtime 重启会使临时引用明确失效；持久 capsule、overlay source 和 task journal 可以重建工作上下文。

这一闭环定义系统的最小完整能力。领域工具通过 Scheme libraries、分布式 procedure、command、
Buffer projection 和 capability service 在其上组合，不需要另建脚本宿主、外部 IDE 或专用终端界面。
