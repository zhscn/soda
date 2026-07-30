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
                                                └── reference provider

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
Chez runtime reflection 可以补充 procedure arity、值类别和文档，但不能覆盖静态
library identity 或源码定义。

Soda 的公共 library metadata 在应用构建时从 Scheme source tree 生成。索引器读取
R6RS `library` 与 `export` form，归一化直接导出和 rename，并把 re-export 关联到
可用的源码定义。生成结果是只含不可变 datum 的 Scheme library，随 whole-program
editor boot 一起编译和嵌入。

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

symbol inspection 与调用签名读取和 completion、xref 相同 revision 的 semantic
snapshot。光标落在 definition 或 resolved use 上时，查询返回 canonical
`SchemeDefinition`，呈现层可读取 kind、signature、library detail、documentation
和 source location。`help.describe-symbol` 通过 `C-h o` 把这些字段组合成简短描述。

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

## 自举静态 Provider

`scheme-mode` 通过 `completion-providers` setting 启用 `scheme-static`。provider
从请求绑定的 Document revision 建立轻量 semantic snapshot，并把本文件定义、
已 import 的 Soda API 与 R6RS/Chez primitive metadata 转换为通用 CompletionItem。

自举 scanner 直接读取 UTF-8 snapshot，识别 Scheme identifier 中的标点，并容错
跳过字符串、行注释、嵌套 block comment、datum comment 以及 quoted datum。它提取
`define`、procedure definition、`define-syntax` 和 `define-record-type`；record
名称、constructor、predicate、accessor 与 mutator 分别形成稳定定义。未闭合的
外围 form 不妨碍已经出现的定义进入 snapshot。

同一次扫描也产生 `SchemeUse { name, start, end, resolution }`。声明 token 不重复
记录为 use，quote、quasiquote、syntax 及 datum comment 内的 symbol 不进入 use
集合。本文件 definition 按名字遮蔽 primitive metadata；其余可识别的 primitive
use 解析到静态 primitive DefinitionId，未解析 identifier 保留空 resolution。
cursor query 在 declaration range 上直接返回自身 DefinitionId，在 use range 上
读取 resolution。references 只比较结构化 DefinitionId，不以文本同名作为引用。

文档定义的 DefinitionId 由 document id、revision、声明 byte offset 和 name
组成；Soda API DefinitionId 使用 library、resource、声明 byte offset 和 name；
primitive DefinitionId 使用静态 metadata identity。文档定义按名字遮蔽 library
catalog 与 primitive。scope graph 可在同一 snapshot 和 DefinitionId 接口之后
增加，provider catalog、completion session 和 TUI 不依赖 scanner 的内部 token
表示。

自举 xref provider 把 definition 和 resolved uses 转成通用 LocationList。当前
Document 的 declaration 与 references 可立即导航。带 source resource 的嵌入 API
definition 通过带目标 byte offset 的异步文件读取请求打开；资源已经访问时直接在
现有 Buffer 中跳转。异步请求发出前在 origin View 的 navigation walk 中保留当前位置，
读取完成后的 definition location 因而参与 `jump-back`。primitive 只有 metadata、
没有 source location 时返回明确的无源码结果。跨 library references 在 workspace
层解析 import/export edges 后进入同一 LocationList 接口。

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
revision 的 workspace edit，并通过跨 Buffer transaction 验证后提交。

发生以下情况时 rename 拒绝生成 edit：

- 任一目标 Document 没有与索引匹配的 revision；
- definition 来自 immutable primitive metadata；
- use 的 resolution 是歧义集合；
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
