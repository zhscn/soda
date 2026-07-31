# Soda

Soda 是一个 Scheme-first 的原生 TUI 编辑器。Chez Scheme 持有命令循环、编辑器状态
和扩展策略；静态链接的 C/C++ 组件提供文本存储、增量语法分析、异步 I/O、终端访问
和 Tree-sitter runtime。

## 实现状态

| 能力 | 状态 |
|---|---|
| `Text`、`Document`、事务、anchor、undo tree | 已实现 |
| Buffer、View、Window、文件读写与基础编辑命令 | 已实现 |
| 终端输入、Kitty keyboard、增量渲染与主题 | 已实现 |
| command、interactive reader、keymap、hook、advice、minor mode、setting | 已实现 |
| minibuffer、补全、REPL、comint 与 continuation debugger | 已实现 |
| C/C++ 专用分析、Scheme 语义服务、Tree-sitter major mode | 已实现 |
| 通用 Project/Workbench 与跨语言语义会话 | 部分实现 |
| 通用跨 Buffer 修改与组合结果视图 | 部分实现 |
| Scheme 宏展开与完整 phase 语义 | 部分实现 |
| soft wrap 与 visual-line 编辑 | 未实现 |
| LSP client | 未实现 |
| Buffer 承载的声明式 TUI application framework | 未实现 |
| Scheme application 独立打包器 | 未实现 |

各子系统的能力边界和细分状态见 [设计文档](design/README.md)。

## 架构

```text
terminal
  -> libuv / terminal ABI
  -> Chez command loop
  -> Editor / Buffer / View / Window
  -> native Text / Document / syntax services
  -> Frame / ANSI presenter
```

编辑器只有一个状态所有者线程。native callback 不进入 Scheme；libuv 完成事件先
转换为普通值，再由 command loop 串行应用。命令通过 Buffer transaction 修改文本，
语言服务消费 revision-scoped snapshot 和 change set，renderer 只读取已经发布的
高亮、decoration 和 display mapping 结果。

主要边界如下：

- `soda_document`：持有 `Text`、`Document`、事务、anchor、snapshot 和 undo tree；
- `soda_cpp_lexer`、`soda_cpp_analysis`、`soda_indentation`：提供 C/C++ lossless
  token、增量语法树和缩进机制；
- `soda_tree_sitter`：静态链接 Tree-sitter core，运行时加载语言 grammar；
- `soda_runtime`：封装 libuv timer、文件、目录、进程和 descriptor readiness；
- `(soda editor ...)`：持有 Buffer/View/Window、command、输入状态、语言模式、
  minibuffer、交互会话和渲染策略。

## 构建与运行

项目使用 `cmk`：

```sh
cmk build -c Debug
cmk run -c Debug soda
cmk run -c Debug soda -- path/to/file
```

安装可执行文件和语言运行时资源：

```sh
cmk install -c Release --prefix ./dist
```

启动器静态链接 native core 和 Chez kernel，并嵌入 Chez runtime boot 与编译后的
editor boot。启动时由 C 入口注册 foreign ABI、建立 Scheme heap，然后进入编辑器
command loop。

## Tree-sitter 资源

grammar 与 query 作为同一 runtime 包分发：

```text
runtime/
  grammars/<language>.<shared-library-extension>
  queries/<language>/highlights.scm
  queries/<language>/indents.scm
  queries/<language>/textobjects.scm
  queries/<language>/folds.scm
  queries/<language>/injections.scm
```

查找顺序为：

1. `SODA_RUNTIME` 指定的 runtime root；
2. 可执行文件旁的 `runtime`；
3. 安装前缀下的 `share/soda/runtime`。

发行资源包含 Bash、CSS、Go、HTML、JavaScript、JSON、Lua、Markdown、
Markdown inline、Python、Rust、TOML、TypeScript、TSX 和 YAML。C、C++ 使用
专用 native analyzer，Scheme 使用内建的 Scheme syntax 与语义服务。

## 基本操作

默认按键以 Emacs 编辑词汇为基础：

- `C-x C-f` 打开文件，`C-x C-s` 保存，`C-x C-c` 退出；
- `C-x b` 切换 Buffer，`C-x 2` / `C-x 3` 切分 Window，`C-x o` 切换 Window；
- `M-x` 调用命令，`C-g` 取消当前交互；
- `C-s` / `C-r` 搜索，`M-%` 查询替换；
- `C-SPC` 设置 mark，`C-w` / `M-w` / `C-y` 操作 region 与 kill ring；
- `C-c C-z` 打开 Chez REPL；
- `C-h c`、`C-h k`、`C-h x` 查看按键和命令，`C-x =` 查看 point 下的字符与 face。

## 文档

- [设计文档索引](design/README.md)
- [构建配置](cmk.yaml)
