# Soda 架构概览

Soda 是用 Rust 写的编辑器，有终端和图形两个前端，核心体验是 CLion 式的 C++ 即时缩进：namespace、构造函数初始化列表、访问标签、参数与 lambda 续行，回车时由增量维护的语法结构直接算出，不随文件变大而退化。Rust 按 rustfmt 的块风格缩进。其余功能服务于这个目标，开箱即用，不求大而全。

新增服务、扩展点和后台任务要有具体场景、明确的状态所有者和生命周期；模块难以独立测试时，先调整边界再扩功能。

## 1 优先级

| 优先级 | 目标 |
| --- | --- |
| P0 | C++ 即时缩进与 tab/space 混排可靠、自然，布局与 clang-format 一致 |
| P1 | 复杂度可控，模块职责清晰、可独立验证 |
| P2 | 默认工作流开箱即用：不加配置时如裸 Emacs，文件与缓冲区、项目、搜索替换、命令面板；常用插件自带 |
| P3 | 扩展能力：键位、命令组合、外部进程、Lua |
| P4 | 语言服务与图形前端；远程会话暂缓 |

## 2 模块

| 模块 | 职责 | 文档 |
| --- | --- | --- |
| `core` | rope 快照、事务、位置映射、历史、坐标与逻辑列 | [编辑内核](core.md)、[坐标](coordinates.md) |
| `editor` | 文档模型、编辑会话、命令控制器、输入与缩进建议的原子组合 | [编辑命令](commands.md) |
| `cpp` | 无损词法、容错结构分析、增量重分析、缩进与续行求解 | [交互缩进](indentation.md) |
| `rust` | Rust 词法、括号/泛型/闭包参数配对、块风格缩进 | [交互缩进](indentation.md) |
| `config` | clang-format 配置解析、预设、目录继承，编译为缩进规则 | [clang-format 配置](clang-format.md) |
| `language` | 语言档案与目录（文件归属的唯一判断）、缩进建议类型、空白策略、注释续写 | [语法高亮与导航](syntax.md) |
| `files` | 文件 I/O、工作区、打开与保存、后台 worker | [文件服务](files.md) |
| `application` | owner-thread 状态归约：视图、窗口树、文档、剪贴板与寄存器 | [边界契约](contracts.md) |
| `interaction` | 键位、命令表、模态编辑、输入框、picker、搜索替换、补全与 snippet | [交互层](interaction.md)、[模态编辑的设计](modal.md)、[补全](completion.md) |
| `options` | 带类型的选项表，全局值与文档覆盖 | [扩展模型](extension.md) |
| `runtime` | 命令循环：执行响应、观察更新、调度后台任务与外部命令、Lua、语言服务器进程 | [扩展模型](extension.md)、[语言服务器](lsp.md) |
| `syntax` | 分类、C++ 词法着色、TextMate 引擎与增量行缓存、内置语法 | [语法高亮与导航](syntax.md) |
| `screen` | 与绘制方式无关的显示：文本区布局（折行、tab、inlay、水平滚动、点击换算）对前端的 `Measure` 泛型，高亮缓存、主题，标签、标题、状态栏与消息行 | [终端界面](ui.md) |
| `host` | 前端共用的会话首尾：启动 Runtime、加载 `init.lua` 与状态、捕获 panic、恢复未保存文档 | [交互层](interaction.md) |
| `tui` | 终端资源、crossterm 输入规范化、按单元格绘制、鼠标、颜色降级 | [终端界面](ui.md) |
| `gui` | 图形前端（`gui` 特性，程序 `soda-gui`）：winit 窗口与输入法、wgpu 渲染、cosmic-text 字体 | [图形界面](gui.md) |

数据单向流动：前端把平台输入交给 Runtime；交互层把按键解析为命令并产生 Application 事件；Application 通过 editor 提交事务。语言分析只读快照、返回建议，修改都经事务入口提交。后台任务读快照，结果带版本与请求身份回到 owner thread，过期的丢弃。

## 3 关键决策

**文本与事务。** 文本存于 ropey，公开坐标是 UTF-8 字节偏移；逻辑列、终端单元和协议位置分别建模。换行、缩进修正和光标放置是一个事务，一次撤销。

**C++ 分析。** 自有的无损词法和扁平节点树，不依赖 tree-sitter 或 clangd。编辑后重新分词受影响区域并修复容器节点，与完整分析做差分测试。续行与对齐移植 clang-format 的 ContinuationIndenter（fake parentheses、嵌套块缩进、参数对齐）。节点用绝对位置，每次编辑有 O(n) 的偏移更新，约 3 ms/MB，不改为相对位置。

**Rust 分析。** 规则比 C++ 简单得多：rustfmt 默认不做视觉对齐，缩进只由分组所在行和语句、参数、分支的起点决定。每次修改整文件重新分词和配对，约 15 ms/MB，不做增量。高亮仍用 TextMate。

**其他语言。** TextMate 语法提供高亮、字面量范围和语言配置；缩进只看括号；结构操作按 `(`、`[`、`{` 配对。语义层交给 LSP。

**交互模型。** 不加配置时如裸 Emacs：只有 Insert，Emacs 的键和记法，`C-SPC` 设标记，`C-c` 加字母留给用户。每个键是一条命令，分发是 Emacs 式的键位表栈。模态编辑是可关的插件（`meow`，选项 `modal`）：选择优先，语义和键位取自 meow，Normal、Insert、Beacon 三个模式，`x s` 和 `C-x C-s` 走同一棵绑定树，多选区只在 Beacon。理由见[模态编辑的设计](modal.md)，插件契约见[扩展模型](extension.md#插件)。

**扩展模型。** 按 kakoune 的方式组织：所有操作是命名命令，键位、命令行（`M-x`）、配置和帮助都引用命令名；`define-command` 组合命令，`pipe` / `shell` 调用外部进程。命令语言没有条件和循环，配置（`init.lua`）和逻辑写在 Lua 5.4（mlua）里，绑定到同一组命令、展开和钩子。LSP 客户端也在 Lua 侧。

## 4 质量与性能

缩进质量以真实语料和编辑轨迹验证，同时检查文本、空白字节、选区和撤销：

| 验证 | 内容 |
| --- | --- |
| `examples/indent_accuracy.rs` | clang-format 格式化过的 C++ 语料逐行重算缩进，报告一致率 |
| `tests/clang_format_options.rs` | 用 clang-format 生成的布局回放：重新缩进，以及从空文档逐字输入 |
| `src/cpp/incremental.rs` 的 `typing_corpus` | 逐字输入真实文件，对照增量与完整分析 |
| `src/rust/indent.rs` 的 `corpus` | rustfmt 格式化过的 Rust 语料逐行重算，以及模拟回车 |
| `examples/cpp_input_trace.rs` | 真实文件上 Enter 与普通输入的延迟 |

延迟目标：缓存就绪的缩进查询 P95 不超过 5 ms，普通输入到可见更新 P95 不超过 16 ms。

## 5 进展

已完成：

- **编辑基础**：编辑内核与历史、文件生命周期、分屏与窗口调整、鼠标、系统剪贴板。
- **C++ 缩进**：增量分析、交互缩进与 clang-format 配置。缩进选项除 `Macros` 中展开不是循环或条件头的定义外全部接入；clang-format 语料逐行一致率在 99.8% 以上，各预设语料的不一致行在 0.15% 以下。剩下的是个例：被 `#if/#else` 拆开的初始化列表、宏实参内带花括号的语句、按原始列判定的行尾注释续行。
- **Rust 缩进与结构**：rustfmt 块风格；soda 与 rustfmt 源码上重算一致率 99.8% 以上，模拟回车几乎全部一致。泛型 `<>` 和闭包参数 `|…|` 是结构分组。
- **交互**：默认的 Emacs 式编辑；可选的 meow 式模态编辑（选区、keypad、宏、Beacon 多选区）；搜索替换、项目搜索、记住的项目与项目切换、各类 picker、命令表与命令面板、键位配置、外部命令。
- **扩展**：选项、展开、钩子与 Lua；插件 `require` 只定义命令，`setup` 才打开键位和钩子，自带 meow、puni、surround、symbol-overlay、comment、git-flags 等。
- **语言服务**：TextMate 高亮（13 个内置语法包，支持注入）、补全与 snippet；经 Lua 接入的 LSP：诊断、跳转、引用、重命名与文件操作、代码动作、签名、语义高亮、inlay hint、请求取消。
- **前端**：终端界面完整；图形界面含输入法、平滑光标与滚动、macOS 的 Command 键，可装成 Linux 桌面应用和 macOS 的 `Soda.app`。

已决定不做：CST 改为相对位置；远程会话（Lua 同步操作 Runtime，拆分代价大；传画面则每个按键等一次往返，不满足回车缩进的延迟要求）；扩展文档的能力（文本范围上的按键、只读、扩展数据，即 Emacs 式的“一切皆 buffer”）。Lua 只往固定的界面里填数据（结果文档、树、`*messages*`、picker、命令行、`paint`/`note`/`flag`），不创造新种类的界面；需要新界面时在 Rust 里做专用的，magit 这类应用交给外部工具。要走 Emacs 那条路得按“在编辑器上构建应用”重做架构，分析见 [Emacs 为什么特殊](notes/why-emacs-is-special.md)。

待做，开始前确认方向：

- **复杂度**：源码约 5.3 万行，`interaction` 约 1.4 万行，占四分之一以上，需要审查重复的状态和逻辑。
- **前端**：macOS 上更完整的验证；缩进线、git 状态这类显示功能先在 `screen` 表达成语义，再由各前端绘制。
