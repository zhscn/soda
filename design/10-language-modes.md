# 语言模式与语法服务

## 定位

Chez Scheme 拥有 major mode、语言策略和命令组合。Native library 提供文本值、
revision-keyed 派生结构和需要低延迟执行的语言机制。编辑器不要求所有语言共享一种
语法树，也不把某个 parser 的节点类型作为通用编辑协议。

语言支持分为三个正交层次：

```text
major mode          keymap、命令、设置、文件匹配、交互策略
language profile    配对符、注释/字符串规则、provider 组合
syntax session      某个 buffer/revision 的增量派生状态
```

major mode 是 Scheme policy。syntax session 是 buffer-scoped mechanism。一个 major
mode 可以没有语言 profile；一个语言 profile 可以使用通用 delimiter scanner、
Tree-sitter、专用 native analyzer，或这些 provider 的组合。

## Major mode

major mode 定义以下策略：

- 名称、父 mode 和 keymap；
- `editing` 或 `interface` interaction class；
- buffer-local 设置默认值；
- 可选的 language profile；
- text object、completion provider 和格式化命令；
- 文件名与 shebang 匹配规则。

父 mode 只表达策略继承。`c-family-mode` 可以共享注释命令、括号配置、keymap 和缩进
设置，但不承诺 C、C++、Java 和 JavaScript 共用 parser。具体 mode 选择自己的语言
profile：

```scheme
(define-major-mode 'c-family-mode
  #:parent 'prog-mode
  #:keymap 'c-family-map)

(define-major-mode 'cpp-mode
  #:parent 'c-family-mode
  #:language 'cpp)

(define-major-mode 'c-mode
  #:parent 'c-family-mode
  #:language 'c)
```

minor mode 可以增加 keymap、命令和 presentation policy，但不替换 buffer 的语言
profile。区域内嵌语言由 syntax session 的 injection 机制表达，不通过切换 buffer
major mode 表达。

## Language profile

language profile 是 Scheme 中的不可变值，包含：

```scheme
(define-language-profile 'cpp
  #:syntax       (native-cpp-syntax-provider)
  #:indent       (native-cpp-indent-provider)
  #:pairs        '((#\( #\) balanced)
                   (#\[ #\] balanced)
                   (#\{ #\} block))
  #:lexical      c-family-lexical-rules
  #:highlights   'cpp-highlights
  #:text-objects cpp-text-objects
  #:electric     '(#\} #\: #\#))
```

profile 字段是能力，不是 parser 类型：

- `syntax` 创建 revision-keyed syntax session；
- `indent` 根据 snapshot、syntax view、行号和设置返回缩进决策；
- `pairs` 声明 delimiter 及其编辑行为；
- `lexical` 描述注释、字符串和 escape 的最低限度规则；
- `highlights`、`text-objects` 和 fold 通过具名 query 定义；
- `electric` 声明可能触发输入后重缩进的字符；
- 可选 `enter` procedure 覆写默认 Enter plan。

Scheme procedure 负责组合这些字段。Native code 不保存 major-mode registry，也不回调
Scheme；command loop 在 editor thread 上同步调用 mode procedure，然后调用 opaque
native handle。

## Syntax provider contract

每个 buffer 至多拥有一个 committed syntax session。session 与特定 provider 和
DocumentId 绑定，缓存一个 committed revision：

```scheme
(syntax-capabilities provider)                     -> list of symbols
(syntax-open provider snapshot)                    -> session
(syntax-sync! session change after-snapshot)       -> void
(syntax-view session snapshot [pending-edits])     -> view
(syntax-close! session)                            -> void
```

`syntax-view` 是不可变的 revision-scoped 查询对象。committed snapshot 可以直接借用
session cache；transaction 的 speculative snapshot 产生可丢弃 view。abort 只销毁
view，commit 后 session 用完整 `DocumentChange` 推进。provider 可以在 speculative
view 与最终 change 完全相同时采用它作为新 cache，但这是优化，不改变协议。

通用编辑机制只依赖以下语义查询：

```scheme
(syntax-context-at view offset)                    -> code|string|comment|unknown
(syntax-matching-pair view delimiter-offset)       -> range|#f
(syntax-enclosing-pair view offset)                -> range|#f
(syntax-forward-unit view offset)                  -> range|#f
(syntax-backward-unit view offset)                 -> range|#f
(syntax-expand-range view range)                   -> range|#f
(syntax-query view query-name range)               -> vector of captures
```

capture 是普通 Scheme 值：

```text
#(capture-name byte-start byte-end node-type properties)
```

通用协议不暴露统一的 `SyntaxKind`。provider-specific node handle 只用于其 adapter
内部，且在 revision 改变后失效。命令通过 `matching-pair`、`forward-unit` 和具名
capture 等语义操作工作，而不是比较 Tree-sitter、C++ CST 或其他 parser 的节点枚举。

## Provider 层级

| Provider | 能力 | 适用范围 |
|---|---|---|
| none | 纯文本编辑 | fundamental、日志、二进制视图 |
| delimiter | lexical context、配对、基于深度的缩进 | 新语言的最低可用支持 |
| Tree-sitter | 容错树、query、增量更新、injection | 大多数编程语言 |
| specialized native | 语言专用结构、精细缩进和编辑机制 | C++ 等高价值语言 |

delimiter provider 根据 profile 的字符串、注释和 escape 规则维护轻量状态，保证括号
扫描不会把字符串或注释中的 delimiter 当成代码。它提供跨语言的 T0/T1 能力：
balanced pair、结构移动、block depth、leading closer 和基础 continuation。语言即使
没有 Tree-sitter grammar，也能得到稳定的括号编辑和常见 block 缩进。

C++ profile 使用现有 `soda_cpp_analysis` 与 `soda_indentation`。它继续拥有 C++ CST、
preprocessor recovery、constructor initializer 和表达式 continuation 等专用语义。
这些细节不进入通用 provider contract。

## Indentation contract

通用缩进决策是 Scheme record：

```text
IndentDecision {
    target-column
    indentation-text
    role                 ; symbol
    anchor               ; byte offset or #f
    preserve?
    trace                ; list of strings
}
```

indent provider 接收 syntax view，而不拥有 Document：

```scheme
(indent-line profile syntax-view snapshot line settings)
    -> IndentDecision | #f
```

`#f` 表示 provider 没有决策，command 使用 profile fallback。fallback 的顺序是：

1. block pair 内部使用 opener 行缩进加 `indent-width`；
2. leading closer 与对应 opener 对齐；
3. 其他位置继承前一个非空行的缩进；
4. fundamental mode 使用当前行或前一行的原始缩进。

provider 返回目标 whitespace；Document mutation 始终由 command plan 执行。专用
native command 可以作为 profile override，但必须返回相同的 caret、change 和
decision 值，不改变 transaction 语义。

## Smart Enter

### Paired block

`{|}` 是通用 pair editing，不属于 C++ parser。默认 Enter handler 在下列条件同时
满足时展开 block：

- selection 为空；
- caret 左右是 profile 中标记为 `block` 的 opener/closer，中间没有换行；
- syntax provider 确认它们互相匹配，或 delimiter provider 在 `code` context 中
  确认匹配；
- editable boundary 允许完整 edit plan。

命令执行一个 transaction：

```text
base:       {|}
edit 1:     {\n\n}
speculate:  为中间行和 closing 行查询缩进
edit 2:     插入 closing indentation
edit 3:     插入 middle indentation
commit:     一个 DocumentChange、一个 undo node
```

中间行优先使用 language indent provider。provider 不可用时，中间行采用 opener
缩进加一步，closing 行与 opener 对齐。因此以下语言无需专用 Enter 实现即可获得
一致行为：

```text
if (...) {|}     object = {|}     fn x() {|}     class X {|}
```

profile 决定哪些 pair 是 `block`；例如 Scheme 的 `{}` 可以只是 balanced datum，
而 C-family 的 `{}` 是 block。

### 普通换行

普通 Enter 同样只提交一个 transaction：

1. 插入 newline；
2. 从 transaction 取得 speculative snapshot 与 normalized pending edits；
3. 创建 speculative syntax view；
4. 查询新行缩进；
5. 插入 indentation 并提交；
6. 用最终 `DocumentChange` 推进 committed syntax session。

Document ABI 为此暴露 transaction 的 base revision 和 pending edit list：

```text
transaction-base-revision
transaction-pending-edit-count
transaction-pending-edit-range
transaction-pending-edit-text
```

pending edit 使用 base-revision 坐标，与 committed `DocumentChange` 相同。provider
不接触可变 transaction，只消费 snapshot 与 edit list。

### Electric input

self-insert 先完成字符插入，再只对 profile `electric` 集合中的字符查询重缩进。
delimiter provider 可处理 leading closer；Tree-sitter query 可处理通用 branch/
closing capture；C++ provider 继续处理 `case:`、access specifier、constructor
initializer、`#` 与 `}`。字符插入和可能的 whitespace replacement 属于同一个
transaction。

## Tree-sitter native runtime

Tree-sitter runtime 是独立 native library，不进入 Document 或 command loop。核心
对象为：

```text
Language       已验证的 grammar handle
ParserSession  DocumentId + committed revision + TSTree
Query          grammar + query source 的编译缓存
SyntaxView     某个 revision 的 immutable TSTree
```

parser 通过 `TextCursor` 风格的 callback 直接读取 persistent Text chunk，不物化整份
字符串。每次 committed change：

1. 把 normalized edits 按 byte offset 从后向前转换为 Tree-sitter input edits；
2. 从旧 Text 取得 start/old-end point，并根据 replacement text 计算 new-end point；
3. edit 旧 tree；
4. 以新 Text 和 edited tree 增量 parse；
5. 原子替换 session 的 committed tree 与 revision。

Tree-sitter 要求先 edit 旧 tree，再把它传给下一次 parse；new tree 可以与旧 tree
共享结构。保存的 node 位置不会自动随 tree edit 更新，因此 Soda 不让 `TSNode`
穿过 public FFI，外部只持有 revision-scoped range/capture。

grammar 由 native loader 打开并校验 Tree-sitter language ABI。项目文件不能自动
加载未信任的 native grammar；parser 安装和信任决策属于 Scheme package policy。
Bundled grammar 可以静态链接，动态 grammar 使用同一 opaque Language contract。

## Tree-sitter queries

Tree-sitter query language 只负责匹配和 capture；capture 的编辑含义由 Soda 定义。
profile 可以提供：

- `highlights.scm`
- `injections.scm`
- `folds.scm`
- `textobjects.scm`
- `indents.scm`

indent query 采用以下 capture contract：

- `@indent` / `@outdent`：增加或减少一个 indent step；
- `@indent.always` / `@outdent.always`：同一行上的 capture 仍累加；
- `@align` + `@anchor`：对齐到 capture 的 byte column；
- `@extend`：为无显式 closing delimiter 的结构延伸作用域；
- `@extend.prevent-once`：阻止最近一层 extension；
- `scope=tail|all` property：控制 capture 是否作用于首行。

这组语义与 Helix 的 indent query 模型兼容，便于验证算法和编写 grammar fixture；
query 文件是否可直接复用由 grammar 节点名、query 内容和许可证共同决定。复杂语言
可以只使用 Tree-sitter 做 lexical context、highlight 和 text object，同时把缩进
交给 specialized provider。

query 在 `(grammar, query-name, source-digest)` 上编译缓存。编译失败是 profile
加载错误，不在每次编辑时重试。运行结果必须受 byte range 和 capture count 限制，
避免一个 query 在 command turn 中产生无界工作。

## Injection

primary syntax session 运行 `injections.scm`，得到 embedded language 与 included
ranges。每种 embedded language 拥有 child session；Tree-sitter 的 included-ranges
API 生成相应子树。syntax query 路由到包含 offset 的最深 child，未命中时回到 host。

Smart Enter 与 indentation 的所有权规则：

- caret 与目标行完全位于 injection range 内时使用 child profile；
- 位于 injection 边界时使用 host profile；
- edit 跨越多个 injection range 时先由 host 处理，commit 后重建受影响的 child
  range。

injection 是 syntax composition，不改变 buffer major mode、keymap 或文件级设置。

## 生命周期与执行模型

- 所有 session mutation 发生在 editor thread；
- native callback 不进入 Scheme；
- syntax result 必须携带 DocumentId 和 revision；
- stale result 不可用于 edit plan；
- speculative view 不进入 committed cache，除非 provider 显式验证最终 change；
- node handle、capture iterator 和 borrowed string 不跨 revision；
- cold parse 可以设置 command-turn budget，超出时取消并退回 delimiter provider；
- highlighting、fold 等 presentation query 可以在后续 event-loop turn 分批运行，
  Enter 和 self-insert 只运行 caret 附近的有界查询。

## 建设顺序

1. Scheme major-mode registry、file-mode rules、language profile record 和 buffer-local
   syntax session slot。
2. delimiter provider、generic newline/paired-block Enter 和 transaction pending-edit
   ABI。
3. 把 C++ adapter 接到通用 syntax/indent contract；C++ adapter 可以使用 native
   command 作为等价 fast path。
4. Tree-sitter Language/ParserSession/Query C ABI，以及一个 grammar 的 highlight、
   text object、indent fixture。
5. grammar registry、动态 loader、query override 与 injection session routing。

每个步骤都保持 fundamental mode 可用；新增 provider 只增加 capability，不改变
Document、command loop 或 TUI 的所有权。

## 参考

- [Tree-sitter incremental editing and included ranges](https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html)
- [Tree-sitter query language](https://tree-sitter.github.io/tree-sitter/using-parsers/queries/index.html)
- [Helix indent query contract](https://docs.helix-editor.com/guides/indent.html)
