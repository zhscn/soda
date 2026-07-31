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
  #:interaction-class 'editing
  #:features '((display-map-provider . cpp-display)))
```

mode parent 只表达 policy 继承，不表达 parser 继承。有效 keymap、settings、
interaction class、feature 和 language profile 沿 parent chain 合并。feature
是具名的 mode 扩展点，可引用 display-map、outline、navigation 等 provider；
命令通过 feature 名和 syntax capability 查询能力，不比较 major mode 名称。
minor mode 叠加局部行为，但不替换 Buffer 的 language identity。

language profile 与 major mode 注册到 Editor 所属 catalog。替换同名描述值后，
Editor 刷新已注册 Buffer 的 runtime；Buffer 在查询 setting、profile 和 mode
keymap 时按名称解析 catalog，因此不会持有过期 mode 描述值。默认 catalog 只作为
独立使用 Buffer API 时的便利入口。

Editor 的 auto-mode catalog 保存具名规则：

```text
AutoModeRule {
  name,
  priority,
  matcher(path),
  major_mode
}
```

规则按 priority 从高到低匹配；同名注册替换旧规则。内建规则覆盖 Scheme 与 C/C++
扩展名，比较时不区分大小写。扩展可以使用 suffix helper，或提供任意 Scheme matcher
实现文件名、目录或 project policy。未匹配资源使用
`fundamental-mode`。

新文件 Buffer 通过 Editor auto-mode catalog 选择 mode。启动 init 加载后会重新选择
首个文件的 mode，使用户规则可以覆盖内建规则。extension rebuild 也会重新选择所有
具有 file path 的 Buffer；移除规则或 major mode 后相应文件回到下一条匹配规则。

切换 mode 是 Buffer transaction 之外的编辑器状态变化：关闭旧 language runtime，
建立新 runtime，再通知所有 View 重建派生状态。

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

syntax view 为指定 byte range 建立有序 highlight cursor。cursor 只属于 syntax
view 的 revision，产生语义 face、layer、priority 与 provenance，不选择终端颜色。
Tree-sitter provider 从 highlight query capture 生成 cursor；specialized provider
从自身 token/CST 查询面生成 cursor；delimiter provider 可以提供基础 lexical
cursor。renderer 不调用 parser 或 lexer，只消费
[13-rendering-theme.md](13-rendering-theme.md) 定义的 `StyledChunk`。

内建 `scheme-mode` 覆盖 `.scm`、`.ss`、`.sls` 与 `.sps` 资源，并通过 mode
setting 组合 `scheme-static` 与 `scheme-runtime` completion provider。静态
provider 提供当前源码的 lexical binding、library export 和 primitive metadata；
运行时 provider 提供 Editor evaluator 中由初始化文件、求值和 load 引入的动态
binding，并排除已有静态 primitive metadata 的名字。Scheme identifier policy
把 reader delimiter 之外的字符视为 symbol 组成部分，因此 `-`、`?`、`!` 等标点
参与补全 query 和 replacement range。completion boundary policy 识别竖线引用的
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
highlights(syntax-view, start, end) -> highlight-cursor
close-view(syntax-view)
close(session)
```

syntax view 是 immutable、revision-scoped 的查询面：

- token/semantic class at offset；
- 指定 range 的有序 highlight cursor；
- matching delimiter；
- enclosing node/range；
- capture query；
- fold、indent 与 injection range；
- 可选 debug projection。

query set 统一返回 `SyntaxCapture`：

```text
SyntaxCapture {
  name,
  source_range,
  node_kind?,
  properties,
  injection_depth
}
```

highlight、fold、indent、text object、locals 与 injection 使用具名 query
选择各自 capture 集合。provider 没有 query 能力时返回 unavailable；调用方按
major mode 的 syntax capability 和 feature 选择回退实现。

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

`scheme-mode` 的 Tab 绑定到 `scheme.indent-line`，按未闭合 delimiter、operator 和
第二个 datum 的位置重新计算当前行缩进。Enter 绑定到
`scheme.newline-and-indent`，用 caret 前的 Scheme lexical context 生成换行和
leading spaces；active region 被同一次 replacement 取代。字符串、quoted symbol、
字符字面量和注释中的 delimiter 不参与结构缩进。每次命令只产生一个 Document
transaction。

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

一个 Tree-sitter session 持有 layered syntax map：

```text
TreeSitterSession {
  document_id,
  parsed_revision,
  interpolated_revision,
  root_layer,
  injection_layers,
  query_set,
  damage_ranges
}

SyntaxLayer {
  language,
  depth,
  host_ranges,
  tree
}
```

root 和 injection layer 都使用宿主 Document 的 byte 坐标。一次 edit 先用
`TSInputEdit` 调整所有相交 tree 的结构位置并推进 `interpolated_revision`，然后以旧
tree 增量 parse。成功发布的全部 layer 属于同一个 `parsed_revision`；changed ranges
合并为 syntax damage，供高亮缓存和 View invalidation 使用。

injection query 返回宿主 ranges、目标 language 和 query configuration。provider
创建、复用或释放对应 layer，并在宿主 edit 后只重新查询受影响的父 layer。嵌套深度、
总 layer 数、单次 query 字节数和 capture 数由 profile 限制。

highlight query 的 capture index 在 grammar/query set 加载时映射到稳定的语义
`FaceId`。theme resolver 对 `FaceId` 使用层级 fallback；theme generation 改变时
只重建 face 解析缓存，不改变 capture mapping，也不重新 parse tree。viewport 查询
只执行与请求范围相交的 query，并返回按 host byte range 排序的 capture cursor。

初次 parse 与增量 parse 都在 editor thread 执行。provider 为 parse、injection 和
query 工作设置交互预算；超出一次 command-loop turn 的工作保留 revision-tagged
pending state，并在后续 turn 继续。新 edit 使旧 revision 的 pending 结果失效。

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
