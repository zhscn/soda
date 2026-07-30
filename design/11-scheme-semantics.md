# Scheme 语义索引

## 定位

Scheme 语言服务由静态语义索引和运行时 session 两个来源组成：

```text
Document snapshot
      │
      ▼
Scheme syntax view ──> binding analysis ──> semantic snapshot
                                                │
                                                ├── completion provider
                                                ├── definition provider
                                                ├── reference provider
                                                └── diagnostic publisher

InteractionSession ──> Chez environment symbol view ──┘
```

静态索引负责 lexical scope、library import/export、定义位置和源码引用。运行时
symbol view 负责 REPL 中已经求值的定义和没有对应源码文件的值。两者通过
[06-completion.md](06-completion.md) 的 provider 管线和
[05-jump.md](05-jump.md) 的位置模型汇合，不共享可变 namespace，也不互相替代。

语义分析属于 language capability。Scheme major mode 在
[09-language-modes.md](09-language-modes.md) 的 LanguageProfile 中注册 syntax、
completion 和 xref provider；Document 仍只拥有文本、revision、snapshot 和
transaction。

## 所有权

Scheme semantic provider 是进程内 Scheme library，不建立平行的 VFS、Document
或 LSP object graph：

- Buffer language runtime 持有当前 Document revision 的 syntax 与 semantic
  snapshot；
- Workbench 持有 library graph、跨文档 definition/use 索引和 dirty queue；
- InteractionSession 的 evaluator 持有 Chez environment；
- completion session、LocationList 和 jump graph 只借用 provider 产生的公共值；
- LSP 是可选的外部 provider/adapter，不是内部语义索引的表示格式。

binding rule、metadata 和查询 policy 都通过 Scheme registry 注册，可以在 editor
内求值、替换并用普通 Buffer 检查。native 层只在 syntax provider 需要增量 parser
或稳定性能机制时提供窄 ABI。

## Scheme syntax view

Scheme syntax provider 把一个 Document revision 投影成带源码区间的
S-expression 树：

```text
SchemeSyntaxNode {
  id,
  range,
  datum_class,
  symbol?,
  children,
  parent?
}

SchemeSyntaxView {
  document_id,
  revision,
  roots,
  diagnostics
}
```

所有 `range` 使用 Document 的 UTF-8 byte offset。Chez annotation、Tree-sitter
node 或其他 reader 的坐标进入 syntax view 时完成换算；LSP UTF-16 坐标只在外部
adapter 边界转换。syntax node 只在所属 revision 内有效，持久位置使用 anchor 或
`resource + range + excerpt`。

reader 允许在不完整的 list、string 和 datum 周围产生可查询节点与诊断。语法恢复
不能改变原文长度与位置映射。无法恢复的区域作为 opaque syntax node 存在，外围
scope 仍可用于补全。

atom token 通过 Scheme reader 分类。只有 reader datum 为 symbol 的 atom 才进入
binding 与 use 分析；number、boolean、character 和其他 self-evaluating datum
保持原始 range，但不生成 identifier。quote、quasiquote、syntax 和 quasisyntax
包围的 datum 在结构分析中折叠为一个保留 range 的 opaque datum，因此 literal
不会产生 use，同时仍占据 `do` binding、调用参数等 form 中的一个语法位置。

syntax provider contract 允许按整个文件重建 SchemeSyntaxView，也允许维护增量
reader。Document change 与 provider session 的生命周期遵循通用 syntax provider
contract，两种实现向语义索引暴露相同的 revision-scoped view。

## 语义数据模型

每个分析结果是 immutable、revision-scoped 的 `SchemeSemanticSnapshot`：

```text
SchemeSemanticSnapshot {
  document_id,
  revision,
  generation,
  scopes,
  definitions,
  uses,
  imports,
  exports,
  diagnostics
}

SchemeScope {
  id,
  parent?,
  range,
  bindings: Name -> DefinitionId[],
  imports: ImportBinding[],
  phase
}

SchemeDefinition {
  id,
  name,
  kind,
  location?,
  initializer_range?,
  library?,
  phase,
  canonical: DefinitionId[],
  metadata
}

SchemeUse {
  name,
  location,
  scope,
  phase,
  resolution: DefinitionId[]
}
```

`DefinitionId` 在 semantic generation 内稳定，是 completion item、definition、
references、hover 和 rename 共用的身份。跨 revision 保存的 UI 状态同时保留定义
位置与 excerpt，并在新 snapshot 中重新解析身份。

`kind` 至少区分 variable、procedure、parameter、syntax、record、accessor、
library 和 primitive。`canonical` 表达 rename、prefix、re-export 和其他别名关系；
跳转定义沿该关系到真实声明，补全仍使用当前位置可见的名字。

Workspace 维护跨文档索引：

```text
SchemeWorkspaceIndex {
  libraries: LibraryName -> ExportSurface
  import_edges: DocumentId -> DocumentId[]
  reverse_import_edges: DocumentId -> DocumentId[]
  definitions: DefinitionId -> SchemeDefinition
  uses: DefinitionId -> SchemeUse[]
}
```

references 查询直接读取 `uses` 倒排表，不在请求时扫描所有同名 syntax node。

## Binding rule

binding analyzer 通过可注册规则解释 Scheme form。规则只读取 syntax node 与分析
context，返回声明式 effect：

```text
BindingRuleResult {
  declarations,
  child_scopes,
  child_contexts,
  imports,
  exports,
  quoted_ranges,
  generated_bindings,
  diagnostics
}
```

核心规则覆盖：

- `define`、procedure definition 与顶层定义；
- `lambda`、`case-lambda` 与 rest parameter；
- `let`、`let*`、`letrec` 及 values 变体；
- `do` 与局部递归绑定；
- `define-record-type` 生成的 constructor、predicate、accessor 和 mutator；
- `library`、`import`、`export`；
- `only`、`except`、`prefix`、`rename`、`for`；
- `define-syntax`、`let-syntax`、`letrec-syntax`；
- quote、quasiquote、syntax 与 quasisyntax 的 phase 边界。

规则 registry 按 language profile 和 library 扩展。项目宏可以注册专用 binding
rule；规则失败只产生语义诊断并降级当前 form，不破坏 Document 或其他 language
capability。

分析分为三个确定性阶段：

1. 建立 lexical scope、声明和 library export surface；
2. 解析 import binding、别名和跨文档 canonical definition；
3. 解析每个 symbol use 并建立 definition-to-uses 倒排索引。

同一 scope 中后定义是否可见由具体 binding rule 决定。查找从当前 scope 向 parent
推进，局部 binding 按名字遮蔽外层 binding；import modifier 在进入 scope 前已经
归一化为 `ImportBinding`，查询层不重新解释 import form。

## Primitive 与 library metadata

Chez、R6RS 和 Soda 公共 library 使用静态 metadata 描述导出符号：

```text
PrimitiveDefinition {
  library,
  name,
  kind,
  signatures,
  documentation?,
  source?
}
```

metadata 作为没有源码 Document 的 SchemeDefinition 加入 library export
surface。它提供稳定的补全与 hover，不依赖当前进程是否已经 import 对应 library。
library identity 来自 catalog，procedure arity 和值类别可以由对应 Scheme
implementation 的构建期反射补充；源码定义仍拥有更具体的 resource 与 range。

Soda 的公共 library metadata 在应用构建时从 Scheme source tree 生成。索引器读取
R6RS `library` 与 `export` form，归一化直接导出和 rename，并把 re-export 关联到
可用的源码定义。生成结果同时包含独立的 library catalog 和 export symbol
catalog。library catalog 保存没有 export 的 library，因此 import 解析不需要从
补全符号反推 library 是否存在。两个 catalog 都是只含不可变 datum 的 Scheme
library，随 whole-program editor boot 一起编译和嵌入。

构建同时从当前 Chez runtime 的 `(rnrs)` 与 `(chezscheme)` library 生成独立的
top-environment catalog。`library-exports` 提供稳定的 library surface；每个 binding
在对应 library environment 中分类为 syntax、procedure 或 variable。procedure 的
固定和可变 arity 由 `procedure-arity-mask` 转换为通用 formals，未知参数名使用
`arg1`、`arg2` 和 `args`。生成结果只包含不可变 datum，运行中的 Editor 不执行
environment reflection。

top-environment definition 没有 source resource 和 declaration range，参与 import
变换、completion、hover、signature、use resolution 与 selector diagnostics，但不
进入 workspace-symbol 和源码跳转结果。显式 import 的同名 definition 优先于全局
primitive fallback，使 DefinitionId 保持唯一；fallback 只覆盖 source-tree 单库测试
和没有静态 library metadata 的最小编辑场景。

procedure metadata 从过程定义、以 `lambda` 初始化的定义和 `case-lambda` 分支提取
formals。索引保存不带过程名的原始 formals datum；呈现签名时使用当前可见 binding
名称，因此 `prefix` 和 `rename` 后的补全签名与实际插入文本一致。源码 Document
中的同类定义使用相同的签名表示，未闭合 form 的容错扫描仍可保留已经完整出现的
参数表。

`define-record-type` 生成 record type、constructor、predicate、accessor 和 mutator
definition。省略 binding 名称时按 R6RS 命名规则派生名称；显式名称直接成为
DefinitionId。默认 constructor 使用 fields 作为 formals，predicate 接受一个
value，accessor 接受对应 record，mutator 接受 record 与新值。带 `protocol` 的
constructor 不推断 formals。所有生成 binding 的 source location 指向 record
声明，使 completion、symbol inspection 和 xref 使用同一份 metadata。

实时 scanner 是 signature formals 的唯一生产者。构建索引器从
`SchemeDefinition` 读取 raw formals，不另行解析 procedure 或 record 语法。

运行时 catalog 保留每个 export 的 library identity。semantic snapshot 从容错
reader 提取当前文档的 import library；即使外围 library form 尚未闭合，已经出现的
import clause 仍然有效。静态 completion 只暴露当前文档 import 的 Soda library，
本地定义按名称遮蔽 catalog，primitive metadata 位于最后。索引内部保留跨 library
同名 export，呈现层对相同名称去重。

import set 在进入查询层前按 R6RS 组合顺序归一化。`only` 与 `except` 过滤当前
surface，`prefix` 重写全部可见名称，`rename` 重写指定名称，`for` 保留 library
identity。重写后的候选保存显示名称和原始 DefinitionId；补全插入显示名称，
definition 与 references 查询沿原始 identity 工作。

Soda application build 从全部内置 Scheme library 生成 API 与 library catalog，
随 editor boot image 静态嵌入。运行时把该 catalog 转换为共享的 library lookup
table；使用同一 project catalog 的 semantic snapshot 复用对应 lookup table。
单个文档分析只处理文档 token、scope、definition、use 和 diagnostics，不重复构造
内置 API 索引。Project 中与内置 library 同名的 source 以完整 export surface
覆盖嵌入版本，使 Soda 能分析正在编辑的自身源码。Project source 的变更产生新的
catalog identity，并使下一次分析建立一份新的共享 lookup table。

## Diagnostics

`SchemeSemanticSnapshot` 保存结构化的 `SchemeDiagnostic`：

```text
SchemeDiagnostic {
  code,
  range,
  severity,
  message,
  payload
}
```

诊断 range 使用 Document UTF-8 byte offset。语义分析器负责产生诊断值，不依赖
Buffer、face 或 TUI。editor diagnostic publisher 把它们转换为 annotation set，
namespace 为 `scheme-semantic-diagnostics`，source revision 与 semantic snapshot
一致。annotation payload 保留原始 `SchemeDiagnostic`，describe-char、LocationList
和后续 quick-fix 可以共享同一个诊断身份。

显式的 workspace diagnostics 查询同步 editor Buffer 与后台 project source
snapshot，并产生按 resource、range 排序的 `SchemeWorkspaceDiagnostic`：

```text
SchemeWorkspaceDiagnostic {
  buffer_id?,
  resource?,
  revision,
  excerpt,
  diagnostic
}
```

同一 resource 已经打开时，Buffer snapshot 取代后台 project source snapshot。
`diagnostics.list-workspace` 将查询结果发布为普通 LocationList，使
`xref.next-location` 和 `xref.previous-location` 可以复用统一的导航协议。
Buffer-backed item 直接切换 view；后台 resource item 通过异步 `file.read`
打开，并在文件到达后跳转到诊断 range。Buffer 的诊断 annotation 更新会使包含
该 Buffer 的 diagnostics LocationList 失效，避免导航到过期 revision。

自举诊断覆盖：

- 不匹配、意外出现和未闭合的 list delimiter；
- 未闭合的 string、escaped symbol 和嵌套 block comment；
- 同一 lexical scope 中重复的 parameter、let binding 或 definition；
- 未被 resolved use 引用的 parameter；
- 重复的 import library；
- 没有任何可见 binding 被引用的 Soda library import；
- 具有静态 export surface 的 Soda 或 Project library，其 `only`、`except`、
  `rename` selector 引用了 import set 未导出的 identifier；
- 嵌入 Soda library catalog 中不存在的 `(soda ...)` import；
- 静态 import environment 完整时，expression position 中没有 lexical、library
  或 primitive definition 的 identifier。

重复 binding 按 scope graph 判断。`let*` 和 `let*-values` 的逐级 scope 允许后续
binding 遮蔽前一层，`lambda`、并行 let 和同一 `case-lambda` clause 中的重复名字
属于同一 binding group。import modifier 的外层 form 作为 library-not-found 的
source range，payload 保存归一化后的 library name。

import specification 是 declaration range，不进入普通 `SchemeUse` 集合。unused
import 按该 specification 经 `only`、`except`、`prefix` 和 `rename` 变换后的可见
definitions 判断；use 的显示名称与 canonical DefinitionId 必须同时匹配。这样
import form 中出现的 identifier 不会把自身计为使用，不同 modifier 也能分别判断。
没有静态 export surface 的 library 保留其初始化语义，不产生 unused-import。
selector 校验按相同的嵌套 import-set 顺序执行，因此经过 `prefix` 产生的名称和经过
内层 `only`、`except` 过滤后的 surface 都在外层 modifier 处准确生效。诊断 range
只覆盖无效的 source identifier，而不是整个 import specification。

undefined identifier 诊断以 binding resolution 为空为基础，并由 syntax context
限制发布范围。`case` datum、import/export declaration、quoted datum 和已知宏的
声明式参数不作为 expression；未知 operator 只诊断 operator 本身，其参数保持
opaque，避免从未知宏 grammar 产生级联误报。`define-command` 的 procedure
signature 建立普通 parameter scope，`interactive` clause 作为命令声明数据处理，
command body 继续按 expression 分析。只要文档存在未知 library import，当前
snapshot 的 import surface 就被视为不完整，不发布推测性的 undefined identifier
诊断。

publisher 在 buffer 创建、major mode 变化和 revert 后同步诊断，并在顶层交互命令
结束后检查所有 Scheme buffer。诊断、completion 和 xref 从 editor 的同一个
`SchemeWorkspaceIndex` 取得 snapshot。freshness 同时比较 Document revision 与
workspace library catalog generation；项目 export surface 变化时，即使 consumer
Buffer 没有修改，也会重新分析其 import 和诊断。新结果用更高 annotation
generation 原子替换同 namespace 的 annotation set。空诊断集仍记录已分析
revision 和 catalog generation，使普通光标移动只执行 freshness 检查。post-command
刷新只同步发生变化的 Buffer，并复用最近一次已提交的 library catalog；显式
workspace 查询负责合并待处理的 Project catalog，避免输入路径触发全项目重建。

## Completion

Scheme completion provider 的请求包含 document、revision、position 和 query
range。静态 provider 在对应 semantic snapshot 中找到最内层 scope，收集可见
definition，按当前位置的拼写应用 lexical shadowing，然后转换为通用
`CompletionItem`。REPL provider 通过 target Document 在 Editor registry 中找到
所属 InteractionSession，并查询其 evaluator environment：

```text
provider_data: {
  definition_id,
  semantic_generation,
  source: static | runtime
}
```

静态候选提供 name、kind、library、signature 和 definition location。候选
annotation 显示首个 signature，多分支 signature 保留在 definition metadata 中供
详情视图和参数提示使用。运行时 provider 从 session environment 提供已经求值的
顶层 binding。language mode 或
buffer-local policy 选择 provider 组合；组合时遵循：

- lexical definition 优先于同名 runtime binding；
- 当前 REPL session 的动态定义优先于其他 interaction session；
- 相同 canonical definition 只显示一次；
- runtime-only binding 保留 session identity，不伪造源码 location；
- 类型信息只参与排序和 detail，不改变 lexical 可见性。

completion item 的 text edit、generation、resolve 和 apply 继续遵循通用补全
管线；Scheme provider 不直接修改 Buffer。

## Symbol inspection 与调用签名

symbol inspection 与调用签名通过 editor 的 `SchemeWorkspaceIndex` 读取和
completion、xref 相同 revision 与 library catalog generation 的 semantic
snapshot。光标落在 definition 或 resolved use 上时，查询返回 canonical
`SchemeDefinition`，呈现层可读取 kind、signature、library detail、documentation
和 source location。`help.describe-symbol` 通过 `C-h o` 把这些字段组合成简短描述；
project library 的 definition 与嵌入 API 使用相同呈现路径。

调用现场使用独立的数据模型：

```text
SchemeCallContext {
  name,
  range,
  callee_range,
  argument_index,
  definitions: SchemeDefinition[]
}
```

`argument_index` 从零开始，按当前 list 中 callee 后的直接 datum 计算；嵌套 list、
string 和 character 各计为一个参数。quoted datum、datum comment 和显式 quote
form 不产生调用现场。callee resolution 复用 `SchemeUse.resolution`，因此本地定义、
import modifier 和嵌入 Soda API 具有相同的查询行为。

`scheme.signature-help` 通过 `C-c C-s` 显示当前参数位置以及所有已解析签名。
`SchemeCallContext` 不包含 TUI 状态，后续 inline overlay、详情窗口和自动触发策略
直接消费同一查询结果。

document symbol 查询投影当前 Buffer snapshot 的 root definitions，不包含 import
surface、primitive、其他 Buffer 或局部 lexical binding。每个结果复用
`SchemeWorkspaceSymbol` 的 DefinitionId、kind、buffer、revision 与 declaration
range，并按源码位置排序。`xref.find-document-symbol`（`M-g i`）使用通用
completing-read 与 fzf matching 打开当前文档候选，接受后通过普通 jump graph
移动到声明。`xref.find-symbol`（`M-g I`）仍独立合并整个 Project、打开的 Buffer
和带源码的嵌入 API。

document highlight 查询解析光标下的 declaration 或 use，并在当前 semantic
snapshot 中返回同一 DefinitionId 的 declaration 与 reference range。lexical
shadowing 因此产生互不干扰的高亮集合。外部 library 和 primitive binding 只返回
当前文档中的 reference，不构造本地 declaration；syntax binding 不参与该查询。

editor 在每个顶层命令结束后按 Buffer revision、caret 和 workspace catalog
generation 刷新当前 Scheme Buffer 的结果。结果发布到独立的
`scheme-document-highlight` annotation namespace，使用 `symbol-highlight` face 和
search decoration layer。selection layer 保持更高优先级，diagnostic 与 semantic
annotation 的生命周期不受光标高亮替换影响。光标刷新只同步当前 Buffer，并使用
最近一次已提交的 Project catalog。

## 自举静态 Provider

`scheme-mode` 通过 `completion-providers` setting 启用 `scheme-static`。provider
从请求绑定的 Document revision 建立轻量 semantic snapshot，并把本文件定义、
已 import 的 Soda API 与 R6RS/Chez primitive metadata 转换为通用 CompletionItem。

自举 scanner 直接读取 UTF-8 snapshot，识别 Scheme identifier 中的标点，并容错
跳过字符串、行注释、嵌套 block comment、datum comment 以及 quoted datum。它提取
`define`、procedure definition、`define-syntax` 和 `define-record-type`；record
名称、constructor、predicate、accessor 与 mutator 分别形成稳定定义。未闭合的
外围 form 不妨碍已经出现的定义进入 snapshot。

scanner 同时从容错 syntax form 建立 lexical scope tree。procedure definition、
`lambda` 和每个 `case-lambda` clause 为 parameters 建立独立 scope；rest parameter
使用同一 binding 模型。`let` 的 binding 只在 body scope 可见，`let*` 为每个
binding 建立依次嵌套的 scope，`letrec` 与 `letrec*` 在 initializer 和 body 中都
暴露全部 binding。`let-values` 与 `let*-values` 对每组 formals 应用对应的并行或
顺序可见性。`do` initializer 在外层 scope 求值，step、termination 和 body 共享
loop binding；`guard` condition binding 只在 handler clauses 中可见。named let
的过程名和参数位于 body scope。未闭合 form 的 scope range 延伸到 Document
末尾，使编辑中的参数和局部 binding 仍可参与补全。

同一次扫描也产生 `SchemeUse { name, start, end, resolution }`。声明 token 不重复
记录为 use，quote、quasiquote、syntax 及 datum comment 内的 symbol 不进入 use
集合。resolution 从光标所在的最内层 scope 向 parent scope 查找，同一名称在首次
命中的 scope 截止；root definition 随后遮蔽 library metadata 与 primitive。
其余可识别的 primitive use 解析到静态 primitive DefinitionId，未解析 identifier
保留空 resolution。
cursor query 在 declaration range 上直接返回自身 DefinitionId，在 use range 上
读取 resolution。references 只比较结构化 DefinitionId，不以文本同名作为引用。
Scheme highlighting 同样按每个 use 的 resolved DefinitionId 选择 kind face，不用
整文件的名字表推断语义颜色；局部 binding 因而不会污染其他 scope 的高亮。

文档定义的 DefinitionId 由 document id、revision、声明 byte offset 和 name
组成；Soda API DefinitionId 使用 library、resource、声明 byte offset 和 name；
primitive DefinitionId 使用静态 metadata identity。静态 completion 在请求位置
查询 point-visible definitions，本地同名 binding 按 scope 遮蔽外层 binding。
构建索引器只消费 root scope definitions，局部参数和 let binding 不进入 library
export surface。provider catalog、completion session 和 TUI 不依赖 scanner 的
内部 token 表示。

自举 xref provider 把 definition 和 resolved uses 转成通用 LocationList。当前
Document 的 declaration 与 references 可立即导航。editor 持有一个
`SchemeWorkspaceIndex`，保存 editor 已知 Scheme Buffer 和 Project resource 的
semantic snapshot。查询前同步 Buffer 集合；document id、resource 或 revision
改变时替换对应 snapshot，已关闭或离开 Scheme mode 的 Buffer 从实时集合移除。
Project snapshot 独立于 Buffer 生命周期。未变化的 snapshot 直接复用。source set
改变后，index 从新 snapshot 的 resolved uses 重建
`DefinitionId -> WorkspaceReference[]` 倒排表；普通 references 查询只读取目标
identity 的 buckets。

Workspace 从 Project source 和带 resource 的 Scheme Buffer 提取 R6RS library
name、export surface 与源码 definition，生成与嵌入 API catalog 相同的 library
entry。Project catalog 分别保存 library name 集合和 export symbol 集合，没有
export 的 library 仍具有独立 identity。source set 或 revision 改变时先重建两个
catalog，并按 library 比较存在性与新旧 export surface。发生变化的 source snapshot
与直接 import 对应 library 的 consumer snapshot 使用合并后的 embedded/project
catalog 重新分析；不受影响的 snapshot 保持对象 identity。暂不参与查询的 Project
snapshot 标记为待分析，在重新进入实时集合时按需刷新。snapshot 更新后重建
references 倒排表。连续异步文件读取只标记 catalog dirty，首次 completion 或 xref
查询负责合并这一批更新。

project library entry 保留声明 resource、byte range、kind 与 procedure formals。
consumer 的 `only`、`except`、`prefix`、`rename` 和 `for` import modifier 由通用
import-binding pipeline 解释，因此 project export 与嵌入 Soda API 具有相同的
可见性、补全和 DefinitionId 语义。动态 entry 与嵌入 entry 按 DefinitionId 去重，
允许 Soda 源码项目使用构建期 catalog 自举而不产生重复候选。
library metadata reader 使用 lexical token 的 delimiter depth 恢复未闭合的外围
form；编辑 library body 时，已经完整出现的 name、export 和 definition 继续留在
project catalog。

源码 Buffer 中的 root definition 使用 document DefinitionId，嵌入 API import
解析到 index DefinitionId。workspace index 通过 `resource + declaration start +
name` 建立这两种身份的等价集合。references 查询在每个已索引 snapshot 中匹配
等价 DefinitionId，因此从 API 消费文件或已打开的 Soda 源码 declaration 发起查询，
都会得到跨 Buffer LocationList。局部 definition 继续使用 document identity，
不会因同名 root definition 被合并。

带 source resource 的嵌入 API definition 通过带目标 byte offset 的异步文件读取
请求打开；资源已经访问时直接在现有 Buffer 中跳转。异步请求发出前在 origin View
的 navigation walk 中保留当前位置，读取完成后的 definition location 因而参与
`jump-back`。primitive 只有 metadata、没有 source location 时返回明确的无源码
结果。Project runtime 从工作目录开始，以 libuv directory scan 异步发现
`.scm`、`.ss`、`.sls` 和 `.sps`，再以异步 file read 把源码交给 workspace。
成功扫描的每个目录注册独立 path watch。文件系统事件按目录合并为重新扫描请求；
扫描结果添加、更新或删除 Project source，并为新目录递归建立 watch。每次成功读取
递增对应 resource revision，使异步外部修改与 Buffer revision 使用同一 freshness
规则。file-read completion 只更新按 resource 合并的待分析队列；一次性 runtime
timer 每个 command-loop turn 最多提交一个 source snapshot。输入、resize 和输出
事件因而可以在大型 Project 的初始索引期间继续推进。
后台 source snapshot 不创建 Buffer；引用位置以 `resource + revision + byte
range` 保存，首次跳转时通过普通异步文件打开流程解析成 Buffer location。

workspace symbol 查询合并已索引 Buffer、Project source 和构建时嵌入的 Soda API
definitions。局部 lexical binding 不进入该查询。相同源码声明在实时 snapshot 中
使用 document DefinitionId，在构建索引中使用 index DefinitionId。一个 source
resource 存在已打开 Buffer 时，Project snapshot 与静态 catalog 条目整体由当前
Buffer revision 替代；其余 catalog 条目以
`resource + declaration start + name` 去重。候选 key 使用
`buffer id + revision + declaration` 或 `resource + declaration`，不会依赖过滤
后的列表位置。

`xref.find-symbol`（`M-g i`）通过通用 completing-read 打开模糊匹配的 symbol
候选。候选保存定义 kind 与 source resource，显示层只负责匹配和选择。接受已打开
源码的候选时直接记录 jump edge 并移动到对应 Buffer；接受未打开的嵌入源码候选时
产生异步文件读取请求，再按声明 byte offset 完成跳转。

Scheme static completion provider 与 xref provider 共享 editor 的
`SchemeWorkspaceIndex`。completion request 按目标 Document revision 读取 workspace
snapshot；项目 export、lexical binding、嵌入 API 和 primitive 在同一个
visible-definition 查询中完成遮蔽与去重，不由 completion UI 再拼接平行目录。

## Definition、references 与 rename

光标下的 symbol 先通过 semantic snapshot 解析为 DefinitionId：

- declaration name 直接返回自身 definition；
- 普通 use 返回其 `resolution`；
- import library name 返回 library source resource；
- alias 沿 `canonical` 返回一个或多个真实 definition；
- runtime-only definition 返回其 EvaluationOrigin 或 REPL history location。

definition 结果转换为 LocationList，并由 Workbench display policy 记录 jump edge。
多定义结果保持独立 location，不在 provider 内选择一个落点。

references 按 DefinitionId 读取 workspace 倒排表。查询 policy 决定是否包含声明和
别名声明；返回值仍是普通 LocationList。rename 复用同一 use 集合生成带源
revision 的 workspace edit。`scheme.rename`（`C-c C-r`）读取一个完整 Scheme
identifier；未访问的 Project source 通过没有 View target 的 `file.read` 打开为
后台 Buffer。所有目标 Buffer 就绪后重新解析 workspace edit，先统一验证 revision、
read-only 状态、range overlap 与名称冲突，再按 Buffer transaction 提交。提交中途
失败时，已经修改的 Buffer 回到各自提交前的 undo position。rename 只修改 Buffer，
保存仍由普通文件工作流负责。

library binding rename 同时处理 declaration、普通 use 和 R6RS surface：

- definition 所在 library 的直接 export 与 export rename source 随声明更新；
- `only`、`except` 和 import rename 的 source identifier 随 canonical name 更新；
- `prefix` consumer 的 use 由旧 prefixed name 更新为新 prefixed name；
- import/export alias 保持其 local 或 external name，alias use 不做文本替换。

发生以下情况时 rename 拒绝生成 edit：

- 任一目标 Document 没有与索引匹配的 revision；
- definition 来自 immutable primitive metadata；
- definition 没有可编辑的源码拼写，例如由 `define-record-type` 隐式生成的默认 binding；
- use 的 resolution 是歧义集合；
- 目标 Buffer 是 read-only；
- 生成的 edit range 重叠或同一 range 产生不同 replacement；
- rename 会在目标 scope 产生可检测的同名冲突。

## Runtime catalog

[10-interaction.md](10-interaction.md) 的 evaluator 在成功求值后更新 session 的
runtime symbol catalog：

```text
RuntimeBinding {
  session_id,
  generation,
  name,
  kind,
  value_metadata,
  origin?,
  static_definition_id?
}
```

runtime symbol view 从 InteractionSession 的 Chez environment 投影，不从
transcript 文本反向解析。顶层 `define`、`define-syntax` 和 library load 可以携带
EvaluationOrigin；当 origin 对应的 static definition 仍匹配时，runtime binding
关联其 DefinitionId。重新定义同名 binding 后，environment 中的可见版本用于后续
查询。

任意 Scheme 值保留在 Chez environment 内。completion、hover 和 debugger 读取
经过限制的 metadata，不把值序列化进 semantic workspace，也不让静态 analyzer
依赖 evaluator 的执行顺序。

## Macro 与 phase

语义索引显式记录 phase。`syntax-rules` 和可静态识别的 `syntax-case` transformer
可以产生 expansion view，用于把生成 binding 和 use 映射回 macro call 与 template
位置。expansion 是派生数据，不能替换用户源码 syntax tree。

任意 transformer 不在 command loop 的分析过程中直接执行。需要执行的 expansion
通过受控 evaluator effect 产生，并携带 document revision、semantic generation
和资源限制；迟到或失败的 expansion 只使相关 form 降级为不透明调用。

自定义宏无需完整 expansion 也可以注册 binding rule。例如一个定义 record 或
模式变量的宏可以直接声明 generated bindings 及其 scope，从而提供 completion
和 xref，而不要求存在 expansion view。

## 更新与一致性

Document commit 后，Scheme language runtime 按以下顺序推进：

1. syntax provider 同步到新 revision；
2. 产生该 Document 的 semantic snapshot；
3. 比较 library export surface 与 import edges；
4. 更新 workspace definition/use 索引；
5. 标记受 export 或 import 变化影响的反向依赖 Document；
6. 在后续有界 turn 中按依赖顺序重新分析 dirty Document。

只修改 procedure body 且不改变 export surface 时，其他 Document 的 name
resolution 保持有效。library identity、export、import modifier 或 macro
binding 变化时，反向依赖进入 dirty 状态。

发布 semantic snapshot 前验证 document id、revision 和 analysis generation。
查询只消费完整 snapshot；新 revision 尚未分析时，provider 可以返回上一 snapshot
的明确 stale 结果并触发更新，也可以返回 pending，不把新旧图的部分状态混合。

所有分析状态由 editor thread 应用。较大的 workspace 更新拆成按 Document 或 scope
分片的 effect/message，每个分片在落地前重新检查 generation。

## 能力层级

Scheme semantic provider 按依赖关系形成三个能力层：

1. **自举层**：容错 syntax view、Chez/R6RS metadata、核心 lexical binding、
   library import/export、completion 和 definition；
2. **workspace 层**：definition-to-uses 索引、references、rename、hover、反向依赖
   与按 revision 更新；
3. **macro 层**：syntax-rules、受控 syntax-case expansion、自定义 binding rule
   和可选类型排序。

上层 API 始终使用相同的 DefinitionId、CompletionItem 与 LocationList。能力增加
只提高解析覆盖率，不改变 command、TUI 或 Workbench 的数据模型。
