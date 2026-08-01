# 语言模式与语法服务

## 实现状态

| 能力 | 状态 |
|---|---|
| major mode、parent mode、profile 与 provider contract | 已实现 |
| 文件关联、Tree-sitter grammar/session/query 生命周期 | 已实现 |
| highlights、indents、textobjects、folds 与 injections 接口 | 已实现 |
| C/C++ 和 Scheme 专用 provider | 已实现 |
| 各分发语言的 query 覆盖 | 部分实现 |
| LanguageSession registry、per-View attachment 与 provenance 路由 | 已实现 |
| LanguageProfile bootstrap hook 与 home attachment 选择 | 已实现 |
| ProjectWorkspace bootstrap snapshot 与 file-backed Buffer 归属解析 | 已实现 |
| LSP process transport、ProjectWorkspace bootstrap 与 full-text document synchronization | 已实现 |
| LSP diagnostics、completion text edits/resolve、hover、document highlights、formatting、definition、references、rename、code actions 与 workspace/applyEdit | 已实现 |
| LSP semantic tokens full refresh 与 document lifecycle refresh | 已实现 |

## 分层

语言支持由三个独立概念组成：

```text
MajorMode        内容分类、继承与按键
LanguageProfile  语言能力组合与 session bootstrap policy
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
实现文件名、目录或用户 policy。未匹配资源使用
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

Project settings 可作为 bootstrap 输入覆盖 style 和 provider 配置。profile 是普通 Scheme 值，
major mode 只引用其名字；同一 provider 可以被多个 mode 复用。

Scheme profile 组合 revision-scoped syntax view、静态 binding analyzer 和
SchemeEnvironment catalog。scope graph、library index、completion 与 xref 的契约见
[11-scheme-semantics.md](11-scheme-semantics.md)。

Scheme 的 reader、highlight、indentation 与静态语义分析共享现有 Scheme syntax
provider。C++ 使用专用 lossless parser。Tree-sitter 用于没有专用语法内核的语言，
避免同一 Buffer 同时维护两棵功能重叠的语法树。

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

内建 Tree-sitter language spec catalog 声明 parser identity、major mode、文件名
关联、delimiter、identifier policy、settings、feature 和 query bundle。面向用户的
语言拥有 `<language>-ts-mode`；只作为 injection layer 使用的 grammar 以 hidden
spec 注册，不参与 auto-mode 选择。C、C++ 和 Scheme 分别使用专用 provider，不注册
Tree-sitter language spec。

内建 `json-mode` 覆盖 `.json` 资源并继承 `prog-mode`。JSON spec 使用动态加载的
Tree-sitter grammar 和 Soda 自有 query bundle，提供增量 parse、highlight、fold
capture 和 text-object capture。grammar 可用时 `.json` auto-mode rule 才选择
`json-mode`；显式启用 mode 时由 syntax provider 建立 parser。query capture 转换为
统一的 `SyntaxCapture`；highlight capture 转换为 base-syntax decoration，
renderer 不直接调用 Tree-sitter。

## Language context 与 session attachment

syntax runtime 属于 Buffer，因为它只由文本 revision 决定。外部 LSP、编译数据库、
运行时 environment 和其他依赖上下文的语义服务属于独立 LanguageSession。两者不使用
同一个生命周期：

```text
BufferLanguageRuntime {
  language,
  syntax_session,
  revision
}

LanguageSession {
  id,
  language,
  provider,
  workspace_folders,
  configuration,
  environment_fingerprint,
  generation
}

LanguageAttachment {
  buffer_id,
  session_id,
  provenance: home | inherited,
  origin_view_id?,
  opened_revision
}

ViewLanguageContext {
  attachment_id?
}
```

LanguageSession registry 按 provider、workspace folders、初始化配置、toolchain/environment
fingerprint 和 client capability 建键。Project 可以为 bootstrap 提供 workspace folder
和配置，但 session identity 不等于 Project identity。一个 Project 可以产生多个
session，一个 multi-root session 也可以服务多个 Project。

Buffer 可以同时具有多个 attachment。同一系统头文件或依赖源码可以由两个具有不同
compile command、include path 或宏环境的 session 打开。LSP document lifecycle 按
`(BufferId, LanguageSessionId)` 计数；一个 session 的 `didClose` 不影响其他 session。
依赖语义上下文的 diagnostics、semantic decoration、completion、hover 和 xref 都标记
attachment，并由发起 View 的 `ViewLanguageContext` 选择。

session bootstrap 只在初次关联时使用 resource 和 Project discovery：

1. resource 明确属于一个可启动的 home session 时建立 `home` attachment；
2. 导航落点没有 home session 时，继承 origin View 的 attachment；
3. 显式启动语言服务时，先解析资源的 home Project；没有 home Project 则使用资源路由
   选择的 Workbench Project。后者建立 `inherited` attachment，使外部头文件、生成源码
   和依赖缓存可以由用户选定的 workspace 服务；
4. 两者都不存在时保持无 attachment，由显式 language command 或用户选择建立；
5. 已存在其他 attachment 不阻止增加新的 attachment，也不覆盖其他 View 的 context。

Project-backed provider 通过 `editor-project-workspace-for-buffer` 读取一次
`ProjectWorkspace`。该值冻结 Project revision、具名 workspace folders 与声明式
configuration，并可转换为 `LanguageSessionKey`。Project 的 `language-servers` setting 是
`(language . server-name)` 的 association list，用于按语言选择已注册的 server profile；
未列出的语言使用 `language-server` 默认值，仍无选择时使用唯一的语言 profile。Project descriptor 更新由
`project-registry-changed` 通知 transport。identity 不变时 session 刷新 workspace
snapshot 与 generation；identity 改变时 transport 关闭旧 documents，建立 replacement
session，并恢复 Buffer attachment 和 View routing。普通语义请求只携带 attachment，
不重新运行 Project discovery。

`LanguageSessionKey` 对 workspace folders、configuration、environment fingerprint 和
client capabilities 使用按值快照。嵌套的 list、vector、string 与 bytevector 在建立 key
和读取 key 时独立复制，使异步 transport 的 identity 不受调用方后续原地修改影响。

definition、reference、diagnostic 和其他异步导航请求冻结 origin attachment。打开落点
Buffer 后，目标 View 选择该 attachment，后续查询继续沿相同 session 路由；请求不再
从落点路径反推 Project。这样跳入 Project 外的系统头文件、生成源码或依赖缓存后仍可
连续导航，同时允许另一个 View 用不同语义环境显示同一 Buffer。

Buffer 关闭时释放全部 attachment；View 关闭只释放其 context 引用。没有 Buffer、
View、pending request 或显式 owner 引用的 session 可以由 policy 停止。Workbench
切换不改变 attachment；持久化只保存可重新发现的 context hint，不序列化运行中的
LanguageSession。

支持 `semanticTokens/full` 的 LanguageSession 在 `didOpen` 和每次 `didChange` 后排入
revision-tagged refresh。请求只携带该 Buffer 的 session document；响应仅在 Buffer 仍为
同一 revision 时发布 semantic annotation，迟到结果不会覆盖当前 decoration。

`textDocument/documentHighlight` 由显式命令查询 point，并在同一 revision 上发布独立的
search-layer annotation set。空结果替换该 session 的已有高亮，其他语言服务和本地语义
provider 的 decoration 不受影响。

`lsp.format` 使用 command target：active region 请求 `rangeFormatting`，其他情况请求
`formatting`。服务器返回的 TextEdit 转换为当前资源的 workspace edit，并通过同一
revision 校验与单次 Buffer transaction 应用。

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

`fold` capture 由 View fold runtime 转换为 anchored collapsed range，并在绘制时
组合成 DisplayMap replacement。query 只定义可折叠语法范围；每个 View 独立保存
哪些范围处于 collapsed 状态。

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

`IndentationProvider` 是 major-mode profile 的缩进扩展点：

```text
open(setting_ref) -> context
line(context, syntax_session, snapshot, line) -> leading_bytes | preserve
close(context)
```

runtime 对一个 revision 打开 provider context，查询目标涉及的各行，再把 leading
whitespace replacement 从后向前放入一个 Buffer transaction。一次 region 或
structural target 缩进只产生一个 revision 和一个 undo entry。provider 只决定
目标 whitespace，不直接修改 Document；`preserve` 保留不适合自动缩进的行。

Scheme provider 为 snapshot 建立规范化逐行缩进表，按未闭合 delimiter、operator 和
第二个 datum 的位置计算列宽。批量查询共享同一张表，因此后一行不依赖原文中前一行的
错误 indentation。字符串、quoted symbol、字符字面量和注释中的 delimiter 不参与
结构缩进。

Tree-sitter provider 对一个 revision 缓存完整的 indent capture 集合，并以目标行
查询它们。`@indent.scope` 的语法范围为范围内各行增加一级缩进；默认不包含 capture
起始行，带 `#set! indent.include-start "true"` 时包含起始行。该属性适用于 Python
等以首个 body node 作为 block 起点的 grammar。`@indent.begin` 与 `@indent.end`
提供顺序事件兼容面，`@indent.end` 在 closing token 所在行抵消一级缩进，
`@indent.branch` 对分支行临时抵消一级，`@indent.zero` 强制零列，
`@indent.align` 将范围内行至少对齐到 capture 起始列，`@indent.ignore` 保留相交行。
输出遵循 profile 的 `indent-width`、`tab-width` 与 `use-tabs?`。

C++ provider 持有 native indent style，并通过 Buffer 的增量 analyzer 计算每行结果。

`edit.indent-region` 使用 `CommandTarget` 要求 active region，并由 profile provider
执行语义缩进；`C-M-\` 调用该命令。`edit.indent-sexp` 优先缩进 active region，
否则缩进下一结构表达式；带 raw prefix 时缩进包含 point 或紧随 point 的 defun。
`C-M-q` 调用该命令。TAB 在 region 激活且 mode 提供 provider 时执行语义缩进；
没有 provider 时按 `indent-width` 右移。`C-M-}` 始终执行右移，`C-M-{` 与
Shift-TAB 执行左移。

没有活动 region 时，TAB 根据 `use-tabs?` 插入 tab，或按 `tab-width` 前进到下一个
显示列 tab stop。Buffer 的 `auto-indent?` 设置使 `edit.newline` 复制当前行的
leading whitespace，`M-i` 切换该 buffer-local 设置。`cpp-mode` 和 `scheme-mode`
的语言专用 Enter 命令在一个 transaction 中插入换行及结构 indentation。

language profile 的 delimiter pairs 同时驱动通用 `move.matching-delimiter`
命令。`M-]` 接受 point 上或 point 前的 delimiter，以同类嵌套深度扫描并移动到
配对位置；没有声明 pairs 的 mode 使用圆括号、方括号和花括号。

## Text object 与结构导航

Tree-sitter `textobjects.scm` 使用
`@text-object.<kind>.around` 和 `@text-object.<kind>.inside`。同一 kind、同一
outer 范围的 capture 合并为一个 `StructuralThing`；outer 范围定义结构对象边界，
直接包含的 inside capture 之并集定义进入对象后的内容范围。没有 around capture 的
inside capture 仍形成独立结构对象。

kind 映射为跨语言结构 role：

- function、method、class、module 等提供 `defun`；
- parameter、argument、array、object、list、block 等提供 `list`；
- statement、conditional、loop、call、string 等提供 `sexp`；
- 原始 kind 作为附加 role 保留，供 major mode 的专用命令查询。

Buffer 为当前 revision 缓存 provider 产生的 `StructureIndex`。通用
`forward-sexp`、`backward-sexp`、`up-list`、`down-list`、
`beginning-of-defun`、`end-of-defun`、`mark-sexp`、`kill-sexp`、
`transpose-sexps` 和 `indent-sexp` 只查询 role 和 outer/inside range，不依赖
Tree-sitter node kind。没有 text-object query 的 major mode 使用 delimiter
structure fallback。

## Tree-sitter runtime

Tree-sitter core 静态链接到 native core，语言 grammar 作为共享模块加载，并通过窄
wrapper 接入：

```text
TSLanguageHandle
TSParserHandle
TSTreeHandle
TSQueryHandle
```

parser module 和 query bundle 使用独立文件格式，由同一个 Soda runtime package
维护、版本化和分发。parser module 只提供 `TSLanguage`；query bundle 属于 Soda 的
editor policy，不由共享库提供。

grammar registry 以 parser symbol 为键。parser module 使用
`grammars/<parser>.<platform-extension>`，默认导出
`tree_sitter_<parser>`；parser 名称中的连字符在导出符号中转为下划线。创建 parser
前会验证 grammar language ABI 是否落在静态 Tree-sitter core 支持的范围内。
major mode 显式拥有 parser session；language availability、grammar identity 与
parser identity 相互独立，为同语言多个 parser 和 injection layer 保留空间。

runtime package 使用固定布局：

```text
runtime/
  grammars/
    <parser>.<platform-extension>
  queries/
    <language>/
      <kind>.scm
```

parser 和 query 共享同一组 runtime roots，依次为 `SODA_RUNTIME`、可执行文件同目录
的 `runtime`、安装数据目录的 `soda/runtime`。`SODA_RUNTIME` 指定一个完整 package
root；loader 不提供单独的 grammar/query search path 或单语言动态库覆盖。构建目录
和安装目录都生成相同布局，因此 portable distribution 与系统安装使用同一 resolver。

内建 runtime package 分发 Bash、CSS、Go、HTML、JavaScript、JSON、Lua、Markdown、
Markdown inline、Python、Rust、TOML、TypeScript、TSX 和 YAML parser。每个 parser
source 由构建配置固定 revision 与 archive digest，生成的模块与 Soda 自有 query
一起安装。所有这些语言提供 highlight query；CSS、Go、HTML、JavaScript、JSON、
Lua、Python、Rust、TypeScript 与 TSX 提供 indent 和 text-object query，JSON
提供 fold query，HTML 提供 JavaScript 与 CSS injection query。TSX 的 query bundle
依次组合 TypeScript 与 TSX query，使通用语言规则与嵌入语法规则保持独立。

Tree-sitter file association 由 rule name、suffix 集合、parser language、major mode
和 priority 组成。注册关联时，已有的专用 major mode 保留自己的 language profile；
其 `tree-sitter-language` feature 声明 parser identity。没有专用 mode 时，系统创建
`<language>-ts-mode` 与只维护增量 parse session 的通用 profile。grammar 不可用时
对应 auto-mode rule 不接管文件。专用 profile 可以在相同 mode identity 下提供
highlight、indent、navigation 和结构 query。

major mode 保存 highlight、indent、navigation、outline 等 provider/query policy，
grammar 模块只提供 `TSLanguage`。mode setup 根据已声明能力装配这些功能，不从
grammar 文件推断 editor policy。

文本读取 callback 直接遍历 `Text` chunk，不要求 flatten 整个 buffer。一次
Document commit 的 normalized changes 转成 `TSInputEdit`，先 edit 旧 tree，再以
新 snapshot 增量 parse。tree 与 query cursor 的 native 生命周期不暴露给 Scheme；
Scheme 只获得 revision-scoped node/capture 值。

query bundle 使用以下 Soda 资源布局：

```text
queries/
  <language>/
    highlights.scm
    indents.scm
    injections.scm
    locals.scm
    textobjects.scm
    folds.scm
    outline.scm
    brackets.scm
    overrides.scm
```

language spec 显式声明启用的 query kind 和组成 bundle 的 language 顺序。继承查询
按声明顺序从 parent 到 child 拼接；provider 在 session 中按需编译每种 query 并
缓存 handle。同一个 compiled query 可以跨增量 parse 后产生的新 tree 重复执行。
关闭 session 时先释放 query handle，再释放 parser 和 grammar module。

query loader 对每个 runtime root 检查 `queries/<language>/<kind>.scm`。spec 声明
的 query 是该 profile 的必需资源；缺失、语法错误或与 grammar 不兼容会使对应
session 建立失败并产生 editor condition。query 文件不承载 major mode、文件关联、
缩进宽度或 completion policy。

`TreeSitterLanguageSpec` 是可声明的数据：

```text
TreeSitterLanguageSpec {
  name,
  parser,
  major_mode,
  parent_mode,
  suffixes,
  delimiter_pairs,
  identifier_policy,
  settings,
  features,
  query_bundle,
  hidden
}

TreeSitterQueryBundle {
  languages,
  kinds
}
```

spec catalog 可以批量注册。注册创建或替换 major mode、language profile 和
auto-mode rule，并只刷新使用相关 mode 的 Buffer。grammar availability 在文件规则
匹配或 mode 建立 session 时查询，因此 catalog 安装不会加载全部 parser module。

Buffer language runtime 将宿主 session 与 revision-scoped 派生索引组合：

```text
LanguageRuntime {
  profile,
  host_session,
  revision,
  structure_index,
  injection_index,
  injection_highlights
}
```

宿主 session 持有增量 Tree-sitter parser。Document commit 先通过 `TSInputEdit`
更新旧 tree，再对新 snapshot 增量 parse；同一 commit 随后重建 structure 与
injection 派生索引，最后发布 runtime revision。Buffer 查询只返回与自身 revision
相同的索引。

query capture 包含 match id、pattern index 和该 pattern 的 `#set!` properties。
injection builder 按 match id 分组，使用 `injection.language` property 或
`@injection.language` capture 确定目标语言，并将每个 `@injection.content` 变成宿主
byte range。语言名按小写、连字符形式规范化，`js` 与 `ts` 分别解析为
`javascript` 与 `typescript`。

每个 injection range 使用独立的子 Document 和目标 grammar 执行 highlight query，
结果映射回宿主 byte range 后写入 `DecorationIndex`。嵌套 injection 递归执行相同
流程，更深层 capture 使用更高的 base-syntax priority。派生完成后即释放子 parser、
query、snapshot 与 Document；renderer 只查询缓存，不运行语言分析。单次构建最多
处理 64 个顶层 range、每个 range 最多 1 MiB，嵌套深度最多为 4。缺少目标 grammar、
query 或子 parser 错误只使对应 range 不产生高亮。

highlight query capture 名直接作为稳定的语义 `FaceId`。theme resolver 对
`FaceId` 使用层级 fallback；theme generation 改变时只重建 face 解析缓存，不改变
capture mapping，也不重新 parse tree。宿主与 injection highlight 都按 revision
缓存为按 range 排序的 `DecorationIndex`，viewport 查询只提取相交 runs。

宿主 parse、query 与 injection 派生构建都在 editor thread 执行。资源上限约束
injection 工作量；runtime 只在整组派生状态属于同一宿主 revision 后发布它们。

## 生命周期不变量

- 一个 Buffer 同时只有一个 active language runtime；
- runtime revision 不得领先或落后于用于查询的 snapshot；
- syntax node/capture 不跨 revision 保存；
- 持久语义位置使用 Document anchor；
- syntax runtime 不引用 Project 或 LanguageSession；
- dependency-sensitive 查询必须携带 View 的 attachment identity；
- 同一 Buffer 的多个 attachment 不共享 session-specific derived state；
- provider 错误只使该语言能力降级，不破坏 Text 与 Document；
- provider 和 native handle 都由 editor thread 创建、查询和释放。

## 设计依据

major mode 是编辑器 policy，parser 是可替换机制。将二者拆开后，C++ 专用内核可以
保留其精度，而其他语言不需要复制 C++ 数据结构。Tree-sitter 适合作为通用语法
provider，但 language profile 仍负责缩进、completion 与 injection 的组合；这与
“用一棵通用 AST 定义整个编辑器语言层”相比，扩展边界更稳定。
