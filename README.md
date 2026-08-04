# Soda

Soda 是一个 Scheme-first 的原生 TUI 编辑器。Chez Scheme 承载编辑器状态、命令和
扩展策略；C/C++ 组件提供文本存储、终端与进程运行时和可复用的语言机制。

## 当前边界

活动源码包含精简 core、native mechanism wrapper 和少量基础功能包：

```text
native Text / Document / terminal/process runtime / parser ABI
                              │
                              ▼
Soda core: value -> document -> buffer -> view/window
                         input/command -> display/frame
                              │
                              ▼
feature packages: editing, files, interaction, completion, modes, language, LSP, REPL
```

core 的公开 UI 容器是 Buffer。Buffer 发布不可变 BufferState；View 保存 selection、viewport
和输入状态；Window 只负责 View 的布局和焦点。区间数据通过 RangeSet、Decoration 和
DisplayMap 组合。功能包通过 owner-scoped registration、command、StateField、Facet 和
transaction 扩展这些稳定边界。

## 实现状态

| 能力 | 状态 |
|---|---|
| `Text`、`Document`、事务、anchor、undo tree | 已实现 |
| core Document wrapper、Buffer、Marker、Extent | 部分实现 |
| core View、Window、keymap、InputLayer、command | 部分实现 |
| core message、task、Frame、display stream | 部分实现 |
| owner-scoped package、service 与资源清理 | 部分实现 |
| core boot image 与 native launcher | 部分实现 |
| 基础编辑、文件、history、interaction、minibuffer 与 completion package | 部分实现 |
| major mode、语言服务、Project/LSP、REPL 与 debugger package | 未实现 |

细分契约和 package 边界见[设计文档索引](design/README.md)，core 模型见
[01-editor-core.md](design/01-editor-core.md)。

## 构建与验证

项目使用 `cmk`：

```sh
cmk build -p default -c Debug
cmk test -p default -c Debug
cmk run -p default -c Debug soda
```

C launcher 注册 native ABI，嵌入 Chez runtime boot 和 Soda kernel/host boot，然后进入
`soda/host/main.ss`。构建只扫描 `scheme/` 活动源码；归档树不会进入 boot 或测试目标。

## Native mechanism

- `soda_document`：`Text`、`Document`、事务、anchor、snapshot 和 undo tree；
- `soda_runtime`：libuv timer、进程、path watch 和 descriptor readiness；
- `soda_tree_sitter`：Tree-sitter core 与 grammar loading；
- `soda_cpp_analysis`、`soda_indentation`：C/C++ 分析和缩进机制。

Tree-sitter grammar 与 query 资源位于 `runtime/`，按发行包一并安装。

## Archive

非活动 editor、TUI、Scheme 功能包及其测试位于 [archive](archive/README.md)，不属于
活动构建输入。它们保留各自的 library name，便于单独查阅或在显式增加
`archive/scheme` library directory 后进行实验。
