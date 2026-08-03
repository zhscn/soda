# Scheme-first 架构

## 实现状态

| 能力 | 状态 |
|---|---|
| C launcher、嵌入式 Chez runtime 与 Soda core boot | 部分实现 |
| Scheme command loop 与单线程状态所有权 | 部分实现 |
| native ABI 注册与不回调 Scheme 的 libuv 边界 | 已实现 |
| native core 静态链接与运行时 grammar 动态加载 | 已实现 |

## 组合根

ELF executable 是部署容器，Chez Scheme 是编辑器的组合根。C 入口嵌入 Chez
runtime boot 和已编译的 Soda core boot，注册静态 native ABI，构建 Chez heap 后把
控制权交给 Scheme startup procedure。Core 持有可组合的状态、文档与视图原语；
语言、命令、工作区和呈现功能作为独立 package 接入。native library 提供有界机制，
不保存 Scheme 对象，也不反向调用 Scheme。

```text
terminal / files / timers
          │
          ▼
 static soda_runtime / libuv
 static soda_tree_sitter / tree-sitter
 dynamic language grammar modules
          │ plain event values
          ▼
 Chez command loop ───── editor state and policy
    │       │
    │       ├── Text / Document
    │       ├── language providers
    │       └── TUI frame
    ▼
terminal writes
```

## 构建与启动

native document、C++ analysis、indentation 和 runtime 组件构建为 static
libraries。libuv 由 CMake FetchContent 获取并链接其 static target。Chez 的
`petite.boot` 与 `scheme.boot` 合成为自包含 runtime boot；core libraries 和
`soda/core/main.ss` 经过 whole-program compilation 后生成以该 runtime 为基底的
Soda core boot。两个 boot image 由 `xxd` 转换为 C arrays 并链接进 `soda`。

进程启动顺序固定为：

```text
C main
  -> verify Chez kernel/header compatibility
  -> initialize Chez static runtime
  -> register embedded runtime and Soda core boot images
  -> register every soda_* foreign symbol
  -> build Chez heap
  -> invoke scheme-start
  -> enter the Scheme startup procedure
  -> deinitialize Chez
```

Scheme wrapper 在嵌入式进程中直接解析 C 入口注册的 foreign symbols。独立 Scheme
测试可以通过 `SODA_*_LIBRARY` 环境变量装载测试用的 monolithic native module；
该 module 不属于安装产物。foreign symbol table 从公开 C ABI headers 生成，因此
完整 ABI 在嵌入式 Chez 环境和 REPL 中均可解析。

## 所有权

| 层 | 所有者 | 责任 |
|---|---|---|
| 文本值与事务 | native `soda_document` | snapshot、revision、anchor、undo |
| C++ 分析 | native language libraries | token、CST、结构查询、缩进 |
| I/O 与终端 | native `soda_runtime` | libuv handle、raw mode、readiness、异步完成 |
| 编辑器实体 | Chez | Buffer、View、Window、Workbench、mode 与 command |
| 策略 | Chez | keymap、placement、provider 组合、触发与排序 |
| 呈现 | Chez + terminal ABI | TUI frame 组合与 ANSI/Kitty 交互 |

opaque native handle 只出现在对应 Scheme wrapper 中。上层实体持有 wrapper，不把
native 地址当作身份；跨层身份使用 Scheme id、document id 和 revision。

## 单线程执行模型

编辑器只有一个持有状态的线程。Chez 在该线程执行 command loop，所有 command
运行到完成，Document mutation、增量分析、状态切换和 frame 组合按顺序发生。

libuv 提供 fd readiness、timer、signal、process、socket 和异步 filesystem
操作。Scheme 调用 poll，native callback 只把完成结果写入 native 队列；poll
返回后，Scheme 拉取普通事件值并更新编辑器状态。该边界避免在 libuv callback
或任意 FFI 栈上进入 Scheme。

同步工作必须适合一次交互 turn。较大的工作拆成带 revision 的步骤，在多个
event-loop turn 之间推进；完成结果只在 document identity、revision 和请求世代
仍匹配时应用。

## Command loop

外部输入统一为 message。update 阶段处理 message、更新 Editor/View，并返回由外层
runtime 执行的 effect 值；effect 完成后产生新的 message。render 阶段只读取状态：

```text
native event -> message -> update(Editor)
                            │
                ┌───────────┴───────────┐
                ▼                       ▼
          updated Editor             effects
                │                       │
                ▼                       ▼
          render frame            runtime/libuv
                                        │
                                        └──> message
```

command 收到显式 context，不从 native 全局变量推断当前 buffer 或 window。
编辑命令以 transaction 为原子边界，更新 View 的 caret/selection，并返回 effect
列表。keymap 保存 command symbol；registry 中替换 procedure 后，已有绑定立即使用
新实现。command runtime 独立于具体 command collection，统一承担注册、key
binding、interactive/internal invocation、completion lifecycle 和 viewport
结算；basic、file、completion、REPL 等 command collection 只定义和安装命令。

message 是按用途区分的记录值，包括 input、resize、interactive command 和
internal command message。input message 携带归一化的 `KeyEvent` 或
`TextInputEvent`。交互命令抛出的 condition 转成 status message；effect completion
与 evaluator 排入的 internal command 保留 condition，使过期结果、identity
错配等程序错误不能被交互错误边界隐藏。effect executor 按 kind 查找显式注册的
handler；handler 返回是否继续以及后续 message。没有 handler 的 effect 是程序
错误，不会在 runtime adapter 中被忽略。

Editor 用 id registry 管理 Buffer 与 View，并为创建的 Buffer 单调分配且不复用
Document identity；active view 只保存 id。View 持有自己的 caret anchor、
viewport、持久 keymap layers、InputState 栈和 pending key sequence；
切换 active view 同时切换命令的 buffer 与输入上下文。Editor 关闭时释放仍在
registry 中的 Buffer。

进程内 REPL 使用同一个 command loop 和事件队列。持久求值 namespace 由
InteractionSession 持有，transcript 是普通 Buffer；求值产生的编辑器修改排成
后续 command message。request identity、来源 revision、I/O 重定向和失败状态见
[10-interaction.md](10-interaction.md)。

## Runtime ABI

runtime ABI 遵循 pull-based 约束：

- 固定版本函数在 Scheme wrapper 装载时验证 ABI 兼容性；
- 创建 handle 后由 Scheme 注册 interest；
- poll 只驱动 libuv 并返回可读取事件数量；
- Scheme drain timer、fd、file-read、file-write、directory-scan、path-change、
  process-output 和 process-exit 等结果；
- close 是显式、幂等的生命周期动作；
- callback data 不保存 Scheme pointer；
- status、libuv 稳定错误名与人类可读消息作为值跨 ABI 返回。

文件写入在 libuv worker pool 中执行完整的临时文件写入与原子替换。worker 不访问
Scheme 对象；完成 callback 只把状态加入 native event queue。

目录扫描使用 `uv_fs_scandir`，并把 entry type、UTF-8 name 编码为 caller-owned
event data。Scheme VFS 将其解码为不可变 entry；editor adapter 只保存 native
source 与上层 request 的关联，不允许 callback 进入 Scheme 或持有 Editor。
路径监听使用长生命周期 `uv_fs_event` source。event data 保存相对被监听目录的
entry name，flags 保存 rename/change 分类；取消 source 会停止 handle，并在 close
callback 后释放 native 所有权。

Scheme 的 `ManagedProcess` 在 native source 之上提供逻辑进程身份。它保存
argument vector、工作目录、transport、PTY 尺寸、owner、generation、stdin 状态、
退出状态以及 output/exit command。start、write、close-input、resize-terminal、
signal 和 restart 都是 effect；runtime adapter 将 native source 映射回逻辑进程，
并把每个 output/exit event 包装成带 generation 的 internal command message。
该层不依赖 Buffer、InteractionSession 或具体 wire protocol。

重启保留 `ManagedProcess` identity 并递增 generation。运行中的重启先发送
SIGTERM，收到旧 generation 的 exit 后再创建新 native source；exit event 标记
是否已经重启。consumer 使用 event generation 丢弃过期协议数据。comint、build
工具和 language server 可以拥有不同的 process owner 与 command handler；LSP
adapter 在 owner command 中维护 `Content-Length` framing 和 JSON-RPC 状态。
language server 使用默认的 `pipe` transport，保持 stdin、stdout 和 stderr 的原始
字节流及独立 stream identity。

子进程使用 `uv_spawn`，参数以长度前缀的 UTF-8 argument vector 跨 ABI 传递，不经
shell 重新解释。工作目录是每个 spawn request 的显式字段，环境继承 Editor 进程。
stdout 和 stderr 分别连接到 libuv pipe，并以带 stream flag 的增量
`process-output` event 返回；pipe 完成关闭后才发布 `process-exit`，因此 exit event
之前的输出不会丢失。stdin 使用独立的 libuv pipe；每次写入拥有自己的 native
byte storage，write callback 后释放。Scheme 可以关闭 stdin、发送指定 signal，
或取消 process source。最终生命周期由 stdin、stdout、stderr、process handle
的 close callback 与 exit event 共同收束。Editor 关闭时 native runtime 终止并
回收仍存活的子进程。

`pty` transport 使用一对 pseudo-terminal descriptor，将子进程的 stdin、stdout
和 stderr 连接到 slave，并把 master 作为一个可读写 libuv stream。输出以
`terminal` stream flag 返回；resize effect 通过 `TIOCSWINSZ` 更新行列数。
PTY 没有独立的 stdin half-close，close-input effect 写入 EOT byte。
该 transport 提供 `isatty`、line discipline 和窗口尺寸，不承担 ANSI 终端模拟或
完整 shell job-control session 的职责。

终端输出使用 partial-write ABI。`write-some` 返回已写 byte 数或 would-block；
Scheme 保留未写 suffix，并在 libuv 报告 output fd writable 后继续 flush。短写、
`EINTR` 和 `EAGAIN` 都不会丢弃 frame 数据，也不会被解释成终端故障。同步完整写入
只用于退出清理等必须排空输出的边界。

终端 raw mode 和 alternate screen 的获取与释放使用动态清理边界。初始化中途失败、
command 抛错和正常退出都执行相同的恢复路径。

## 扩展边界

扩展首先是 Scheme library：定义 command、keymap、mode、provider、placement
policy 或工具 buffer。需要稳定性能、C/C++ 库互操作或 OS handle 时，再增加
窄 native ABI。native API 面向可复用机制设计，不面向单个命令设计。

一个 native 组件必须说明：

- handle 的所有权和释放函数；
- thread 归属；
- byte buffer 的寿命；
- document/revision 约束；
- 错误与取消语义；
- Scheme wrapper 对应的值类型。
