# Emacs 交互基线

## 定位

Emacs 交互基线定义 Soda 的单终端、单用户文本编辑工作流。它约束 file
Buffer、View、command、interaction 与 terminal frontend 的组合方式；语言服务、
Project、REPL 和多窗口工作台在此基线之上作为独立 package 提供。

Soda 保持自己的 Buffer、View 与 command 抽象，并以 Emacs 的可组合 command、
prefix key、minibuffer、echo area、mode line、Buffer/View/Window 语义作为用户心智
模型。具体键位由 keymap 组合，不写入编辑机机制。

## 工作流

### 文件与会话

| 能力 | 交互合同 |
|---|---|
| 启动时打开多个文件与 `+LINE[,COLUMN]` 定位 | 每个文件使用可重用 Buffer，并在目标 View 中定位 |
| 访问、插入、保存、另存、重载与关闭 file Buffer | 文件生命周期通过 command 与 interaction 组合 |
| 文件名 completion、目录浏览与 Buffer 列表 | 使用普通 Buffer/View 和 minibuffer |
| 修改 Buffer 在关闭和退出时的保存决策 | 在实际关闭边界请求用户决策 |
| 覆盖已有目标文件的明确确认 | 写入前通过 minibuffer 确认 |
| 外部修改检测 | 保存时校验 resource version |
| regular file 的同目录原子写入与 mode 保留 | 写入 effect 保持文件元数据 |
| 同目录 `path~` 备份策略 | 文件 package 策略控制 |
| 相邻 `.soda-lock` 锁文件、冲突只读打开与 token 匹配释放 | 锁属于 file Buffer resource 生命周期 |

### 文本编辑

| 能力 | 编辑合同 |
|---|---|
| committed text、paste、tab、换行、删除与多 selection 替换 | 输入转换为 Document transaction |
| region、mark、copy、kill word/line 与 yank | mark 与 point 形成 region，kill ring 行为由 command 组合 |
| undo/redo 与 saved revision | History 记录编辑事务，保存点属于 Buffer |
| word、logical line、Buffer 边界与匹配分隔符移动 | motion command 仅更新 View-local selection |
| 行缩进/反缩进、自动缩进与 paragraph fill | 编辑策略由 Buffer configuration 和 mode 提供 |
| 可配置 tab-to-spaces 与 indent unit | 共享编辑策略使用 Buffer scope |
| 自动 hard wrap | 通过编辑 transaction 执行 |
| 只读编辑策略与受保护 Buffer 内容 | 在 command dispatch 边界拒绝修改 |

### 查找与工具

| 能力 | 交互合同 |
|---|---|
| literal search、重复查找与 query replace | 读取参数时使用 minibuffer，命中状态使用 View decoration |
| Unicode case-sensitive / case-insensitive literal search policy | search session 持有显式策略 |
| Unicode whole-word literal search policy | word boundary 由 search package 定义 |
| POSIX ERE search policy、repeat 与 replace | 编译器状态属于 search session |
| 拼写检查、替换建议与结果 Buffer | 结果和候选是可导航的普通 Buffer |
| 外部命令的 process Buffer | 外部 I/O 通过 effect 返回 command loop |
| 位置与词/行/字符统计 | 结果显示在 echo area 或结果 Buffer |

### 显示与终端

| 能力 | 显示合同 |
|---|---|
| UTF-8、宽字符、tab、selection、viewport 与 resize | DisplayMap 是文档位置与单元格位置的唯一映射 |
| Kitty keyboard、legacy key、paste、alternate screen 与 OSC 52 | terminal frontend 转换为语义输入与帧事务 |
| Buffer-local automatic indentation | 缩进策略跟随 Buffer mode |
| View-local soft wrap 与 tab width | 每个 View 保持独立布局配置 |
| line-number gutter 与 guide column | 作为 View decoration 参与布局 |
| constant position display | 导航状态在 echo area 中低优先级显示 |
| prefix guidance | 未完成的 prefix 在 echo area 中按需显示可用的下一键，不占用常驻快捷键栏 |
| command feedback | 单行命令结果显示到下一次有效用户输入；长期状态进入 mode line、普通 Buffer 或 interaction |
| 可组合 selection/search/diagnostic/semantic style overlay | decoration 在 cell renderer 之前构建并按范围查询 |
| soft-wrap visual-row motion | motion 使用 DisplayMap 的可视行语义 |
| viewport-relative paging | page command 以可视高度移动 viewport 并保持 point 可见 |

## 配置边界

编辑行为通过 Configuration 的 Facet 与 Compartment 表示：共享文本编辑策略使用 Buffer scope，
布局和光标显示使用 View scope。命令通过 transaction 或 ViewTransaction 重配置选项，使多个
View 可以共享文本但保留各自的显示选择。

文件安全策略由 file package 的 effect handler 实施。写入 effect 在目标 resource、外部版本和
Buffer identity 校验完成后更新 file binding 与 history save point。

## 交互不变量

Emacs 交互基线使用以下可观察条件：

- 日常文件编辑不绕过 CommandRuntime、Dispatcher 或 History；
- 取消 interaction 不改变 Document、resource binding 或 save point；
- Buffer 与 View 的选项作用域在多 View 场景保持独立；
- 输入、搜索、replace、spell 与 generated result Buffer 使用同一普通 Buffer 和 command
  生命周期；
- 普通编辑状态保留正文、mode line 与 echo area；键位提示由 prefix 或显式帮助命令触发；
- echo area 不保存会在临时交互结束后重新出现的后台消息；
- terminal frontend 在正常退出和 condition unwind 时恢复 terminal session；
- 文件写入失败、外部版本变化和关闭决策保持 Buffer 与磁盘状态一致。
