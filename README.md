# Soda

Soda 是一个 Scheme-first 的原生 TUI 编辑器。Chez Scheme 承载编辑器状态、命令和
扩展策略；C/C++ 组件提供文本存储、异步 I/O、终端访问和可复用的语言机制。

## 当前边界

活动源码只包含精简 core 与 native mechanism wrapper：

```text
native Text / Document / libuv / terminal / parser ABI
                              │
                              ▼
Soda core: value -> document -> buffer -> view/window
                         input/command -> display/frame
                              │
                              ▼
future packages: files, modes, minibuffer, language, LSP, REPL, debugger
```

core 的公开 UI 容器是 Buffer。View 保存 point、selection 和 viewport；Extent 保存
face、display、action、location 等区间属性；Window 只负责 View 的布局和焦点。功能包
通过 owner-scoped package、service、command 和 Buffer transaction 组合。

## 实现状态

| 能力 | 状态 |
|---|---|
| `Text`、`Document`、事务、anchor、undo tree | 已实现 |
| core Document wrapper、Buffer、Marker、Extent | 部分实现 |
| core View、Window、keymap、InputLayer、command | 部分实现 |
| core message、task、Frame、display stream | 部分实现 |
| owner-scoped package、service 与资源清理 | 部分实现 |
| core boot image 与 native launcher | 部分实现 |
| 文件编辑、major mode、minibuffer、补全、语言服务、LSP、REPL、debugger | 未实现 |

细分契约和后续 package 边界见[设计文档索引](design/README.md)，core 的目标模型见
[18-editor-core.md](design/18-editor-core.md)。

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
- `soda_runtime`：libuv timer、文件、目录、进程和 descriptor readiness；
- `soda_tree_sitter`：Tree-sitter core 与 grammar loading；
- `soda_cpp_analysis`、`soda_indentation`：C/C++ 分析和缩进机制。

Tree-sitter grammar 与 query 资源位于 `runtime/`，按发行包一并安装。

## Archive

旧 editor、TUI、旧 Scheme 功能包及其测试位于 [archive](archive/README.md)，不属于
活动构建输入。它们保留原有 library name，便于单独查阅或在显式增加
`archive/scheme` library directory 后进行实验。
