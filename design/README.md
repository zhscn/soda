# Soda 设计文档

本目录描述 Soda 的当前架构与扩展契约。文档同时覆盖已落地的 native
机制和编辑器上层的目标数据模型；实现细节以公开 ABI、Scheme library
和测试所表达的契约为准。

## 阅读顺序

| # | 文档 | 内容 |
|---|---|---|
| 01 | [01-kernel.md](01-kernel.md) | C++ lossless lexer、容错 CST、增量分析与缩进机制 |
| 02 | [02-buffer.md](02-buffer.md) | `Text`、`Document`、事务、anchor、snapshot 与 undo tree |
| 03 | [03-input.md](03-input.md) | 终端输入、Kitty 协议、keymap、command loop 与 selection |
| 04 | [04-workbench.md](04-workbench.md) | project、workbench、window、layout 与 display placement |
| 05 | [05-jump.md](05-jump.md) | 跳转图、位置列表、组合视图与跨 buffer 事务 |
| 06 | [06-completion.md](06-completion.md) | 异步补全管线、条目模型、取消、过滤与应用 |
| 07 | [07-decoration.md](07-decoration.md) | 文本区间元数据、诊断、虚拟文本与 fold |
| 08 | [08-scheme-first.md](08-scheme-first.md) | Chez Scheme、native core、libuv 与 TUI 的所有权边界 |
| 09 | [09-language-modes.md](09-language-modes.md) | major mode、language profile 与 syntax provider |
| 10 | [10-interaction.md](10-interaction.md) | 进程内 REPL、求值 request、来源与 debugger 状态 |
| 11 | [11-scheme-semantics.md](11-scheme-semantics.md) | Scheme scope graph、语义索引、补全与 xref |
| 12 | [12-minibuffer.md](12-minibuffer.md) | minibuffer session、读取协议、history 与补全目标 |
| 13 | [13-rendering-theme.md](13-rendering-theme.md) | 增量高亮、display mapping、theme 与终端渲染管线 |

依赖关系：

```text
                    08 Scheme-first composition root
                     │
          ┌──────────┼──────────┬───────────┐
          ▼          ▼          ▼           ▼
      03 input   04 workbench 09 modes  10 interaction
                     │          │           │
              ┌──────┴───┐      ├────┬──────┘
              ▼          ▼      ▼    ▼
           05 jump  06 completion  11 Scheme semantics
              │          │      │
              └──────┬───┴──────┘
                     ▼
                07 decoration
                     │
             ┌───────┴───────┐
             ▼               ▼
        02 Text / Document  13 rendering/theme
                              ▲
                              │
                          09 modes

      09 modes ───────────────> 01 C++ language core

      03 input ──> 12 minibuffer <── 06 completion
      03 input <──────────────── 13 rendering/theme
```

上层模块持有策略与可组合状态；native 模块提供具有明确生命周期、revision
和线程归属的机制。前端只消费编辑器状态并产生输入事件，不拥有文档语义。
