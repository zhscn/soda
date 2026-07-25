# Scheme-first 架构

## 组合根

Chez Scheme 是编辑器的组合根。它持有 command loop、buffer registry、mode、
language catalog、keymap catalog、window/workbench、导航、补全会话、用户配置和
REPL。native library
提供有界机制，不保存 Scheme 对象，也不反向调用 Scheme。

```text
terminal / files / timers
          │
          ▼
     soda_runtime
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
新实现。

message 是按用途区分的记录值，包括 input、resize 和 command message。input
message 携带归一化的 `KeyEvent` 或 `TextInputEvent`。effect executor 按 kind
查找显式注册的 handler；handler 返回是否继续以及后续 message。没有 handler 的
effect 是程序错误，不会在 runtime adapter 中被忽略。

Editor 用 id registry 管理 Buffer 与 View，active view 只保存 id。View 持有自己的
caret、viewport、持久 keymap layers、InputState 栈和 pending key sequence；
切换 active view 同时切换命令的 buffer 与输入上下文。Editor 关闭时释放仍在
registry 中的 Buffer。

进程内 REPL 使用同一个 command loop 和事件队列。持久求值 namespace 由
InteractionSession 持有，transcript 是普通 Buffer；求值产生的编辑器修改排成
后续 command message。request identity、来源 revision、I/O 重定向和失败状态见
[10-interaction.md](10-interaction.md)。

## Runtime ABI

runtime ABI 遵循 pull-based 约束：

- 创建 handle 后由 Scheme 注册 interest；
- poll 只驱动 libuv 并返回可读取事件数量；
- Scheme drain timer、fd、file-read、file-write 等结果；
- close 是显式、幂等的生命周期动作；
- callback data 不保存 Scheme pointer；
- error code 与消息作为值跨 ABI 返回。

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
