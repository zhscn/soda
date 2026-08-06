# Nano 编辑基线

## 定位

Nano 基线定义 Soda 的单终端、单用户文本编辑工作流。它验证 file Buffer、View、command、
interaction 与 terminal frontend 的组合能力；语言服务、Project、REPL 和多窗口工作台在此基线
之上作为独立 package 提供。

Soda 保持自己的 Buffer、View 与 command 抽象。Nano 的命令名称和终端习惯用于功能验收，
不要求复制 Nano 的内部状态模型或全部快捷键。

## 工作流

### 文件与会话

| 能力 | 状态 |
|---|---|
| 启动时打开多个文件与 `+LINE[,COLUMN]` 定位 | 已实现 |
| 访问、插入、保存、另存、重载与关闭 file Buffer | 已实现 |
| 文件名 completion、目录浏览与 Buffer 列表 | 已实现 |
| 修改 Buffer 在关闭和退出时的保存决策 | 已实现 |
| 覆盖已有目标文件的明确确认 | 已实现 |
| 外部修改检测 | 已实现 |
| 原子写入、备份与锁文件策略 | 未实现 |

### 文本编辑

| 能力 | 状态 |
|---|---|
| committed text、paste、tab、换行、删除与多 selection 替换 | 已实现 |
| region、mark、copy、cut、uncut、kill word/line | 已实现 |
| undo/redo 与 saved revision | 已实现 |
| word、logical line、Buffer 边界与匹配分隔符移动 | 已实现 |
| 行缩进/反缩进、自动缩进与 paragraph fill | 已实现 |
| 自动 hard wrap、tab-to-spaces 与可配置 indent unit | 未实现 |
| 只读编辑策略与受保护 Buffer 内容 | 部分实现 |

### 查找与工具

| 能力 | 状态 |
|---|---|
| literal search、重复查找与 query replace | 已实现 |
| case、whole-word 与 regular-expression search policy | 未实现 |
| 拼写检查、替换建议与结果 Buffer | 已实现 |
| 外部命令的 process Buffer | 已实现 |
| 位置与词/行/字符统计 | 已实现 |

### 显示与终端

| 能力 | 状态 |
|---|---|
| UTF-8、宽字符、tab、selection、viewport 与 resize | 已实现 |
| Kitty keyboard、legacy key、paste、alternate screen 与 OSC 52 | 已实现 |
| Buffer-local automatic indentation | 已实现 |
| View-local soft wrap 与 tab width | 已实现 |
| line-number gutter、constant position display 与 guide column | 未实现 |
| 可组合 selection/search/diagnostic/semantic style overlay | 部分实现 |
| soft-wrap visual-row motion 与 viewport-relative paging | 未实现 |

## 配置边界

编辑行为通过 Configuration 的 Facet 与 Compartment 表示：共享文本编辑策略使用 Buffer scope，
布局和光标显示使用 View scope。命令通过 transaction 或 ViewTransaction 重配置选项，使多个
View 可以共享文本但保留各自的显示选择。

文件安全策略由 file package 的 effect handler 实施。写入 effect 在目标 resource、外部版本和
Buffer identity 校验完成后更新 file binding 与 history save point。

## 验收条件

Nano 基线通过以下可观察条件验收：

- 日常文件编辑不绕过 CommandRuntime、Dispatcher 或 History；
- 取消 interaction 不改变 Document、resource binding 或 save point；
- Buffer 与 View 的选项作用域在多 View 场景保持独立；
- 输入、搜索、replace、spell 与 generated result Buffer 使用同一普通 Buffer 和 command
  生命周期；
- terminal frontend 在正常退出和 condition unwind 时恢复 terminal session；
- 文件写入失败、外部版本变化和关闭决策保持 Buffer 与磁盘状态一致。
