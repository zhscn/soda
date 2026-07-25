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

InteractionSession ──> runtime symbol catalog ──┘
```

静态索引负责 lexical scope、library import/export、定义位置和源码引用。运行时
catalog 负责 REPL 中已经求值的定义、过程元数据和没有对应源码文件的值。两者通过
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
- InteractionSession 持有 runtime symbol catalog；
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

## Completion

Scheme completion provider 的请求包含 document、revision、position、query range
和 active InteractionSession。provider 在对应 semantic snapshot 中找到最内层
scope，收集可见 definition，按当前位置的拼写应用 lexical shadowing，然后转换为
通用 `CompletionItem`：

```text
provider_data: {
  definition_id,
  semantic_generation,
  source: static | runtime
}
```

静态候选提供 name、kind、library、signature 和 definition location。runtime
provider 从 session catalog 提供已经求值的顶层 binding。合并规则为：

- lexical definition 优先于同名 runtime binding；
- 当前 REPL session 的动态定义优先于其他 interaction session；
- 相同 canonical definition 只显示一次；
- runtime-only binding 保留 session identity，不伪造源码 location；
- 类型信息只参与排序和 detail，不改变 lexical 可见性。

completion item 的 text edit、generation、resolve 和 apply 继续遵循通用补全
管线；Scheme provider 不直接修改 Buffer。

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

catalog 是 InteractionSession 的派生状态，不从 transcript 文本反向解析。顶层
`define`、`define-syntax` 和 library load 可以携带 EvaluationOrigin；当 origin
对应的 static definition 仍匹配时，runtime binding 关联其 DefinitionId。重新
定义同名 binding 产生新的 generation，并替换该 session 中的可见版本。

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
