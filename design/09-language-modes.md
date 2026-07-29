# 语言模式与语法服务

## 分层

语言支持由三个独立概念组成：

```text
MajorMode        内容分类、继承与按键
LanguageProfile  语言能力组合与 project policy
SyntaxProvider   revision-scoped 语法机制
```

Editor 持有 language catalog，Buffer 引用该 catalog 并保存 major mode 名称与
language runtime；View 只借用某 revision 的 syntax view。Document 不知道语言类型。

## Major mode

major mode 是 Scheme registry 中的描述值：

```scheme
(define-major-mode!
  'cpp-mode
  #:parent 'prog-mode
  #:keymap 'cpp-mode-map
  #:language 'cpp
  #:interaction-class 'editing)
```

mode parent 只表达 policy 继承，不表达 parser 继承。有效 keymap、settings、
interaction class 和 language profile 沿 parent chain 合并。minor mode 叠加局部
行为，但不替换 Buffer 的 language identity。

language profile 与 major mode 注册到 Editor 所属 catalog。替换同名描述值后，
Editor 刷新已注册 Buffer 的 runtime；Buffer 在查询 setting、profile 和 mode
keymap 时按名称解析 catalog，因此不会持有过期 mode 描述值。默认 catalog 只作为
独立使用 Buffer API 时的便利入口。

文件名、shebang、modeline 或用户命令选择 major mode。切换 mode 是 Buffer
transaction 之外的编辑器状态变化：关闭旧 language runtime，建立新 runtime，
再通知所有 View 重建派生状态。

## Language profile

profile 组合能力：

```text
LanguageProfile {
  syntax_provider,
  indentation_provider,
  comment_syntax,
  delimiter_pairs,
  identifier_policy,
  word_motion,
  completion_providers,
  trigger_policy,
  query_sets,
  injection_rules
}
```

project settings 可覆盖 style、provider 配置和 query 搜索路径。profile 是普通
Scheme 值，major mode 只引用其名字；同一 provider 可以被多个 mode 复用。

Scheme profile 组合 revision-scoped syntax view、静态 binding analyzer 和运行时
session catalog。scope graph、library index、completion 与 xref 的契约见
[11-scheme-semantics.md](11-scheme-semantics.md)。

profile 的 highlight provider 接收
`(document-id, revision, snapshot-bytes, visible-start, visible-end)`，返回只属于该
revision 的 DecorationRun 列表。provider 只产生语义 face、layer、priority 与
provenance，不选择终端颜色。renderer 在每个可见 View 上查询 provider，并按
[07-decoration.md](07-decoration.md) 的合并顺序生成 frame cell。

内建 `scheme-mode` 覆盖 `.scm`、`.ss`、`.sls` 与 `.sps` 资源，并通过 mode
setting 选择 `scheme-static` completion provider。Scheme identifier policy 把
reader delimiter 之外的字符视为 symbol 组成部分，因此 `-`、`?`、`!` 等标点参与
补全 query 和 replacement range。completion boundary policy 识别竖线引用的
identifier，使空白和转义字符保留在同一个 query range 中。

Scheme REPL Buffer 复用 `scheme-mode` 的 reader boundary policy，但以 buffer-local
setting 选择 `scheme-repl` provider。该 provider 查询 InteractionSession 持有的
Chez environment；静态 provider 只分析源码 Document，不解析 transcript。

内建 `cpp-mode` 覆盖 `.c`、`.cc`、`.cpp`、`.cxx`、`.h`、`.hh`、`.hpp` 与
`.hxx` 资源，并继承 `prog-mode`。每个 C++ Buffer 打开一个 native analyzer
session；普通 commit、undo 和 redo 使用 change 增量同步。native 编辑命令已经把
同一 analyzer 推进到目标 revision 时，Buffer sync 识别目标 revision 并跳过重复
apply。临时 transaction 的 syntax view 使用独立 analyzer 分析 speculative
snapshot，关闭 view 时立即释放。

## Syntax provider

provider contract：

```text
capabilities(provider) -> set
open(snapshot, config) -> session
sync(session, snapshot, normalized changes) -> session
view(session, revision) -> syntax-view
close-view(syntax-view)
close(session)
```

syntax view 是 immutable、revision-scoped 的查询面：

- token/semantic class at offset；
- matching delimiter；
- enclosing node/range；
- capture query；
- fold、indent 与 injection range；
- 可选 debug projection。

Buffer 在 commit、undo、redo 和显式接受 native change 后同步 session。若 provider
不能接受 change chain，则从目标 snapshot 重建。View 借用 syntax view 时必须显式
close；provider session 关闭前释放全部 view。

## Provider 层级

语言可以选择不同成本与精度：

1. **Delimiter provider**：括号、字符串、注释与基础 indentation，适用于纯文本和
   简单语言。
2. **Tree-sitter provider**：通用增量 parse、highlight、fold、text object 和
   injection。
3. **Specialized provider**：例如 [01-kernel.md](01-kernel.md) 的 C++ lossless
   CST 与专用 indentation。

这些 provider 实现同一 session/view 生命周期，但不要求共享 AST 或节点 kind。
上层 command 按 capability 查询，不能假定所有语言都有 C++ CST。

## Indentation

indentation provider 使用 snapshot、syntax view、position 和 style，返回：

```text
IndentDecision {
  column,
  rule,
  trace?
}
```

通用 delimiter provider 可覆盖 block 与 continuation；Tree-sitter provider
可以由 query capture 提供语言规则；specialized provider 可使用更深语法结构。
把空白写回 Document 是 command 的责任，因此缩进查询保持纯函数，多个前端和
批量命令可以复用。

基础编辑命令提供不依赖 parser 的缩进层。Buffer 的 `auto-indent?` 设置使
`edit.newline` 复制当前行的 leading whitespace，`M-i` 切换该 buffer-local
设置。没有活动 region 时，TAB 根据 `use-tabs?` 插入 tab，或按 `tab-width`
前进到下一个显示列 tab stop；有活动 region 时，TAB 按 `indent-width` 增加其涉及
的每一行。Shift-TAB 按 `indent-width` 反缩进活动 region 或当前行。`M-}` 与 `M-{`
也提供 region 缩进命令。整组多行变换在一次 Buffer transaction 中提交。
major-mode keymap 可以用语言专用命令覆盖这些基础行为。

`cpp.indent-line` 通过 profile 的 indentation provider 查询 native
IndentDecision，再用普通 Buffer transaction 写回 leading whitespace。`cpp-mode`
的 TAB 绑定到该命令。Enter 绑定到 `cpp.newline-and-indent`；native engine 对
between-braces 等结构执行单次原子编辑并返回 Document change，Buffer 接受 change
后统一更新 revision、undo history、View caret 与 language runtime。

language profile 的 delimiter pairs 同时驱动通用 `move.matching-delimiter`
命令。`M-]` 接受 point 上或 point 前的 delimiter，以同类嵌套深度扫描并移动到
配对位置；没有声明 pairs 的 mode 使用圆括号、方括号和花括号。

## Tree-sitter runtime

Tree-sitter 通过窄 native wrapper 接入：

```text
TSLanguageHandle
TSParserHandle
TSTreeHandle
TSQueryHandle
```

文本读取 callback 直接遍历 `Text` chunk，不要求 flatten 整个 buffer。一次
Document commit 的 normalized changes 转成 `TSInputEdit`，先 edit 旧 tree，再以
新 snapshot 增量 parse。tree 与 query cursor 的 native 生命周期不暴露给 Scheme；
Scheme 只获得 revision-scoped node/capture 值。

query set 按用途分开：highlight、indent、fold、text object、locals、injection。
query 文件合并和覆盖由 language profile 决定，provider 负责校验 node type 与
capture name。

injection query 返回宿主 range、目标 language 和 content ranges。每个 injection
建立子 session，并把宿主 byte range 映射到子文档坐标。宿主 edit 后先更新 range，
再同步或重建受影响子 session；嵌套深度和总 session 数由 profile 限制。

## 生命周期不变量

- 一个 Buffer 同时只有一个 active language runtime；
- runtime revision 不得领先或落后于用于查询的 snapshot；
- syntax node/capture 不跨 revision 保存；
- 持久语义位置使用 Document anchor；
- provider 错误只使该语言能力降级，不破坏 Text 与 Document；
- provider 和 native handle 都由 editor thread 创建、查询和释放。

## 设计依据

major mode 是编辑器 policy，parser 是可替换机制。将二者拆开后，C++ 专用内核可以
保留其精度，而其他语言不需要复制 C++ 数据结构。Tree-sitter 适合作为通用语法
provider，但 language profile 仍负责缩进、completion 与 injection 的组合；这与
“用一棵通用 AST 定义整个编辑器语言层”相比，扩展边界更稳定。
