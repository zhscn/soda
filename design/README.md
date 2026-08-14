# Soda 设计文档

本目录描述 Soda core 的稳定合同和功能 package 边界。`archive/` 不属于活动实现，因而不计入
这里的实现状态。

状态词只表示源码覆盖：

- **已实现**：公开机制和对应 contract test 存在；
- **部分实现**：底层合同存在，文档中的上层组合仍有缺口；
- **未实现**：目标边界已确定，尚无对应 package。

## 阅读顺序

1. [01-editor-core.md](01-editor-core.md)：整体分层、依赖方向和 kernel/host/frontend/package
   边界；
2. [02-document.md](02-document.md)：Text、Document、snapshot、change 与 anchor；
3. [03-buffer-ui.md](03-buffer-ui.md)：Buffer 局部扩展、mode、attachment 和文本 UI；
4. [04-input.md](04-input.md) 与 [05-command-runtime.md](05-command-runtime.md)：
   输入解析和 command loop；
5. [06-minibuffer.md](06-minibuffer.md)：非递归交互读取；
6. [11-emacs-interaction.md](11-emacs-interaction.md)：以 Emacs 为主体的单终端编辑与交互合同；
7. [07-scheme-runtime.md](07-scheme-runtime.md) 与 [09-packaging.md](09-packaging.md)：runtime、
   embedding 和发行。

## Core contract

| 文档 | 边界 | 状态 |
|---|---|---|
| [01-editor-core.md](01-editor-core.md) | immutable editor state、host、View、TUI 与 package 依赖 | 部分实现 |
| [02-document.md](02-document.md) | Text、Document、snapshot、transaction、anchor 与 undo | 已实现 |
| [03-buffer-ui.md](03-buffer-ui.md) | Buffer identity、局部扩展、generated projection 与文本 UI | 部分实现 |
| [04-input.md](04-input.md) | terminal event、keymap、InputState 与 layer composition | 部分实现 |
| [05-command-runtime.md](05-command-runtime.md) | command、interactive invocation、hook、advice 与 effect | 部分实现 |
| [06-minibuffer.md](06-minibuffer.md) | interaction session、prompt Buffer 与 completion controller | 部分实现 |

## Native 与发行

| 文档 | 边界 | 状态 |
|---|---|---|
| [07-scheme-runtime.md](07-scheme-runtime.md) | Chez 组合根、单线程 command loop 与 native ABI | 部分实现 |
| [08-cpp-analysis.md](08-cpp-analysis.md) | C++ lossless parser、结构查询与缩进机制 | 已实现 |
| [09-packaging.md](09-packaging.md) | launcher、boot section、runtime assets 与 application 容器 | 部分实现 |

## Future package

| 文档 | 边界 | 状态 |
|---|---|---|
| [10-project-lsp.md](10-project-lsp.md) | Resource、Project resolution 与 LSP workspace routing | 未实现 |
| [11-emacs-interaction.md](11-emacs-interaction.md) | Emacs 心智模型下的单终端编辑与交互合同 | 部分实现 |

语言模式、document completion、xref/result、directory UI、REPL/debugger 和 dashboard 在对应
package 开始实现时，以 `01` 和 `03` 的 extension/attachment/projection contract 编写独立
文档。它们不预先进入 Buffer、View、renderer 或 command runtime 的固定记录。

## 依赖方向

```text
native Text / Document / runtime mechanisms
                  │
                  ▼
kernel immutable state
  ChangeSet / Selection / StateField / Facet / RangeSet
                  │
                  ▼
host identities and lifecycle
  Buffer / View / Window / Surface / command / input / condition
                  │
                  ▼
TUI frontend
  terminal decoder / frame / compositor / presenter
                  │
                  ▼
feature packages
  editing / files / minibuffer / generated UI / language / project / REPL
```

依赖只能向下。kernel 不导入 host、TUI 或 package；host 不导入具体功能 package；renderer 和
input resolver 不包含按功能名称分支。

## 规范所有权

- `02` 定义 Document 机制；`03` 定义 host Buffer 和 Buffer-local extension；
- `04` 定义物理输入到 disposition；`05` 定义 disposition 之后的 command execution；
- `06` 定义 interactive request 的 TUI adapter，不定义递归 command loop；
- `01` 定义通用 StateField、Facet、View projection、Frame 和 package 边界；
- `10` 只定义 Project/LSP package，不改变 Buffer identity 或 Scheme 开发模型；
- `09` 只定义构建和发行，不向 editor state 暴露容器细节。
