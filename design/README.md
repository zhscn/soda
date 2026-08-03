# Soda 设计文档

本目录描述 Soda 的当前架构、稳定扩展契约和尚未实现的目标模型。每份文档使用统一
状态词：

- **已实现**：对应机制和公开入口存在；
- **部分实现**：核心机制存在，但文档列出的部分能力仍缺失；
- **未实现**：文档是目标契约，尚无对应运行时机制。

状态只表示实现覆盖，不表示优先级、完成时间或兼容承诺。细分能力以各文档开头的
状态表为准。

## 文档索引

| 文档 | 主题 | 总体状态 |
|---|---|---|
| [01-kernel.md](01-kernel.md) | C++ lossless lexer、容错 CST、增量分析与缩进 | 已实现 |
| [02-buffer.md](02-buffer.md) | `Text`、`Document`、Buffer、文件事务与 undo | 部分实现 |
| [03-input.md](03-input.md) | 编辑器终端输入、keymap、input state 与基础编辑 | 已实现 |
| [04-workbench.md](04-workbench.md) | ResourceContext、Project、Workbench、Window 与 placement | 部分实现 |
| [05-jump.md](05-jump.md) | 位置列表、跳转历史、组合视图与跨 Buffer 事务 | 部分实现 |
| [06-completion.md](06-completion.md) | 补全 session、provider、过滤、取消与应用 | 已实现 |
| [07-decoration.md](07-decoration.md) | annotation、decoration、DisplayMap 与 fold | 部分实现 |
| [08-scheme-first.md](08-scheme-first.md) | Chez、native core、libuv 与线程所有权 | 已实现 |
| [09-language-modes.md](09-language-modes.md) | major mode、syntax provider 与 LanguageSession attachment | 部分实现 |
| [10-interaction.md](10-interaction.md) | REPL、comint、求值、continuation 与 debugger | 已实现 |
| [11-scheme-semantics.md](11-scheme-semantics.md) | SchemeEnvironment、索引、补全、xref 与 rename | 部分实现 |
| [12-minibuffer.md](12-minibuffer.md) | minibuffer session、读取协议与选择策略 | 已实现 |
| [13-rendering-theme.md](13-rendering-theme.md) | highlight、DisplayMap、theme 与增量 presenter | 部分实现 |
| [14-command-extensibility.md](14-command-extensibility.md) | interactive command、hook、advice 与 minor mode | 已实现 |
| [15-configuration.md](15-configuration.md) | setting、配置快照、用户 init 与热替换 | 已实现 |
| [16-tui-applications.md](16-tui-applications.md) | Buffer 承载的声明式 TUI application framework | 已实现 |
| [17-packaging.md](17-packaging.md) | 单文件编辑器发行与 Scheme application 打包 | 部分实现 |
| [18-editor-core.md](18-editor-core.md) | 精简 editor core、统一 Buffer UI 与功能包边界 | 部分实现 |

## 规范边界

后出现的专用文档拥有其领域的完整契约，其他文档只引用，不重复定义：

- `03` 定义当前编辑器输入；`16` 定义 TUI application 对输入系统的扩展；
- `06` 定义补全数据与生命周期；`12` 定义 minibuffer 对补全的呈现和选择策略；
- `07` 定义区间元数据与显示映射；`13` 定义这些数据进入 Frame 的方式；
- `04` 定义 ResourceContext、Project 和 Workbench；`09` 定义语言 provider、session
  attachment 与导航 provenance；
- `11` 定义 SchemeEnvironment 和 Scheme provider 的语义内容；
- `10` 定义交互与调试 session；`17` 只定义构建和发行边界。
- `18` 定义目标 editor core、统一 Buffer presentation 和功能包依赖边界；其他文档的
  领域机制作为独立 package 接入该边界。

当前实现文档描述的依赖方向：

```text
Text / Document
  -> Buffer / View / Window
  -> command + input + minibuffer
  -> language provider + completion + interaction
  -> decoration + DisplayMap
  -> renderer + theme + presenter

Chez command loop -> native ABI -> libuv / terminal / parsers
```
