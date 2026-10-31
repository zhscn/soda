# Soda 架构概览

Soda 是以 TUI 交付、以 C++ 交互缩进为核心体验的 Rust 编辑器。首要目标是 CLion 式的即时缩进：namespace、类成员初始化列表、访问标签、参数与 lambda 续行，在一次回车中由增量维护的语法结构直接计算，不随文件变大而退化。其余编辑功能服务于这个目标，开箱即用但不追求大而全。

规模以 kakoune（约 20k 行）为参照。它不是硬限制，但新增服务、扩展点和后台任务都要有具体使用场景、明确的状态所有者和生命周期，模块难以独立测试时先调整边界再扩大功能。

## 1 优先级

| 优先级 | 目标 |
| --- | --- |
| P0 | C++ 即时缩进与 tab/space 混排可靠、自然；行为与 clang-format 布局一致 |
| P1 | 代码规模与复杂度可控，模块职责清晰、可独立验证 |
| P2 | 默认工作流开箱即用：Vim 编辑、readline 输入键、文件与缓冲区、搜索替换、命令面板 |
| P3 | 基础扩展能力：键位、命令组合与外部进程 |
| P4 | 保留语言服务、GUI 和远程会话的演进空间 |

## 2 模块

| 模块 | 职责 | 文档 |
| --- | --- | --- |
| `core` | rope 快照、事务、位置映射、历史、坐标与逻辑列 | [编辑内核](core.md)、[坐标](coordinates.md) |
| `editor` | 文档模型、编辑会话、命令控制器、输入与缩进建议的原子组合 | [编辑命令](commands.md) |
| `cpp` | 无损词法、容错结构分析、增量重分析、缩进与续行求解 | [交互缩进](indentation.md) |
| `config` | clang-format 配置解析、预设、目录继承，编译为缩进规则 | [clang-format 配置](clang-format.md) |
| `language` | 语言档案与目录（文件归属的唯一判断）、跨语言共享的空白策略与生成 | [语法高亮与导航](syntax.md)、[交互缩进](indentation.md) |
| `files` | 文件 I/O、工作区、打开与保存请求、后台 worker | [文件服务](files.md) |
| `application` | owner-thread 状态归约：视图、窗口树、文档、剪贴板与寄存器、文件完成 | [边界契约](contracts.md) |
| `interaction` | 键位、命令表、Vim 语法、输入框、picker、搜索替换等会话 | [交互层](interaction.md)、[扩展模型](extension.md) |
| `options` | 带类型的选项表，全局值与文档覆盖 | [扩展模型](extension.md) |
| `runtime` | 命令循环：执行响应、观察更新、调度后台任务与外部命令 | [交互层](interaction.md) |
| `syntax` | 分类、C++ 词法着色、TextMate 引擎与增量行缓存、内置语法；只依赖 `core` 和 `cpp` | [语法高亮与导航](syntax.md) |
| `tui` | crossterm 输入规范化、ratatui 绘制、布局与主题、配置文件加载 | [终端界面](ui.md) |

数据单向流动：前端把平台输入交给 Runtime；交互层把按键解析为命令并输出 Application 事件；Application 通过 editor 提交事务；语言服务只读快照并返回建议，修改始终由事务入口统一提交。后台任务读取快照，结果带版本与请求身份回到 owner thread，过期结果被拒绝。

## 3 关键决策

**文本与事务。** 文本存于 ropey，公开坐标是 UTF-8 字节偏移；逻辑列、终端单元和协议位置分别建模。换行、缩进修正和光标放置组成一个事务，一次撤销。

**C++ 分析。** 使用自有的无损词法和扁平节点树，不依赖 tree-sitter 或 clangd。编辑后重新词法分析受影响区域并修复容器节点，与完整分析做差分测试。续行与对齐移植 clang-format 的 ContinuationIndenter 规则（fake parentheses、嵌套块缩进、参数对齐），以 clang-format 格式化过的 LLVM 源码为准测量一致率。节点目前使用绝对位置，每次编辑有 O(n) 的偏移更新；改为相对位置是已知的后续工作。

**交互模型。** 保留 Vim 的 Normal/Insert/Visual 和 operator 语法，不采用 helix 的选择优先模型。Insert 和所有输入框共享 readline 风格的行编辑键。

**扩展模型。** 按 kakoune 的方式组织：所有操作是命名命令，键位、`:` 命令行、配置文件和帮助都引用命令名；扩展通过 `define-command` 组合命令和 `pipe` / `shell` 调用外部进程。选项、展开和钩子让命令语言能读写状态并响应事件，见[扩展模型](extension.md)。暂不嵌入脚本语言：Chez 拥有独立的执行环境，与编辑器的命令循环不相容；以后确有需要时在 Steel 与 mlua 中选择，并绑定到同一组命令、展开和通知上。

## 4 质量与性能

缩进质量以真实编辑轨迹验证，同时检查文本、空白字节、选区和撤销：

- `examples/indent_accuracy.rs` 对 clang-format 格式化过的语料逐行重算缩进，报告一致率。
- `tests/clang_format_options.rs` 用 clang-format 生成的布局做两种回放：重新缩进，以及从空文档逐字输入。
- `src/cpp/incremental.rs` 的语料测试逐字输入真实文件，对照增量与完整分析。

性能以输入到可见更新的延迟为准：缓存就绪的缩进查询 P95 不超过 5 ms，普通输入到可见更新 P95 不超过 16 ms；报告同时记录 P99、最大值和文件规模。`examples/cpp_input_trace.rs` 测量真实文件上的 Enter 与普通输入延迟。

## 5 当前范围与后续工作

已完成：编辑内核与历史、文件生命周期、C++ 增量分析与缩进、clang-format 配置、TUI、语法高亮、Vim 子集（含文本对象、dot repeat、宏、寄存器、标记）、搜索替换、文件与缓冲区 picker、命令表、键位配置、命令面板、外部命令、系统剪贴板、鼠标、分屏与显示规则、项目搜索。

待定事项，开始前需要确认方向：

- C++：三元表达式续行、宏内容、尾随注释对齐；CST 相对位置改写。
- 语言服务：clangd/LSP 接入（补全、诊断、跳转）与语法高亮的取舍。
- 交互：多选区、Visual block、窗口大小调整。
- 前端：GUI 与远程会话，在本地会话模型稳定后再设计。

## 6 设计参考

参考项目的本地目录如下，`~` 表示用户主目录。

| 项目 | 本地目录 | 主要参考 |
| --- | --- | --- |
| llvm-project | `~/project/llvm-project` | `clang/lib/Format/` 的结构识别、token 角色、ContinuationIndenter 与空白生成 |
| intellij-community | `~/project/intellij-community` | 缩进查询服务边界、Search Everywhere 的来源与结果管理 |
| kakoune | `~/project/kakoune` | 命令、键位与扩展模型；代码规模参照 |
| helix | `~/package/helix` | Rust 编辑内核与终端前端组织、keymap 与命令表 |
| codemirror | `~/package/codemirror` | 状态、事务、历史分组与搜索 cursor |
| neovim | `~/package/neovim` | 命令行补全状态、位置结果集 |
