# 语法高亮与导航

C++ 由自有的词法分析和结构分析支撑；其他语言参照 IntelliJ 的做法，用 TextMate 语法提供高亮与基本编辑规则，语法级导航交给 LSP。不使用 tree-sitter：它的解析器是需要编译和按 ABI 分发的原生代码，查询文件又要跟着语法节点名同步维护，分发和升级都不省心。TextMate 语法是纯数据，格式十多年未变，可以连同语言配置一起嵌入可执行文件。

## 分层

| 层 | C++ | 其他语言 |
| --- | --- | --- |
| 词法高亮 | 自有词法分析器的 token 分类，加关键字表 | TextMate 语法 |
| 结构高亮 | 结构分析中确定的名字（函数定义、类型、命名空间、标签、宏） | TextMate 作用域本身已包含一部分 |
| 语义高亮 | LSP semantic tokens（以后） | LSP semantic tokens（以后） |
| 文件内符号 | 结构分析 | 由 `entity.name.*` 作用域生成的大纲 |
| 跨文件导航 | LSP | LSP；没有服务器时退回单词级查找 |
| 缩进、注释、括号 | 自有规则（clang-format） | `language-configuration.json` |

上层在可用时覆盖下层；任何一层缺失都退回下一层，不报错。纯文本不高亮。

## 分类

高亮结果是字节范围加一个固定分类。主题只为分类配色，不认识任何语法的作用域名或 token 类型。

| 分类 | TextMate 作用域前缀 | C++ 来源 |
| --- | --- | --- |
| Comment | `comment` | 行注释、块注释 |
| String | `string`、`markup.raw`、`markup.inline.raw` | 字符串、原始字符串、字符字面量、`#include` 的头文件名 |
| Escape | `constant.character.escape` | — |
| Number | `constant.numeric` | 数字 |
| Constant | `constant.language`、`constant.other`、`support.constant`、`variable.other.constant` | `true`、`false`、`nullptr`、`this` |
| Keyword | `keyword`、`storage` | 关键字 |
| Operator | `keyword.operator` | — |
| Type | `entity.name.type`、`entity.name.class`、`support.type`、`storage.type.primitive`、`entity.other.inherited-class` | 内建类型关键字；类、结构体、枚举定义的名字 |
| Function | `entity.name.function`、`support.function`、`meta.function-call` 内的名字 | 函数定义的名字 |
| Parameter | `variable.parameter` | — |
| Namespace | `entity.name.namespace`、`entity.name.module` | 命名空间定义的名字 |
| Macro | `meta.preprocessor`、`entity.name.function.preprocessor`、`meta.attribute`、`support.function.macro` | 预处理指令行 |
| Tag | `entity.name.tag` | — |
| Attribute | `entity.other.attribute-name` | — |
| Heading | `markup.heading` | — |
| Emphasis | `markup.italic` | — |
| Strong | `markup.bold` | — |
| Link | `markup.underline.link`、`string.other.link` | — |
| Invalid | `invalid` | 词法分析器无法识别的字符 |

TextMate token 带一串作用域（从外到内）。从最内层开始，取第一个能映射到分类的作用域；每个作用域按最长前缀匹配上表（`keyword.operator.assignment` 先匹配 `keyword.operator`，再退回 `keyword`）。这与 IntelliJ `TextMateDefaultColorsProvider` 的前缀回退相同。

## TextMate 引擎

自己实现，正则使用 `onig`（Oniguruma 的绑定，构建时静态编译其 C 源码）。VS Code 的语法使用 Oniguruma 方言（后向断言、`\G`、所有格量词、`\h` 等），纯 Rust 的正则库无法完整支持。现有的 Rust TextMate crate 要么只支持 Sublime 格式（syntect），要么成熟度未知，因此与 IntelliJ 一样自带引擎。

支持的语法要素：

- `match` 规则及其 `captures`。
- `begin`/`end` 规则，含 `beginCaptures`、`endCaptures`、`captures`、`contentName`、`applyEndPatternLast`，以及 `end` 中对 `begin` 捕获组的反向引用。
- `begin`/`while` 规则：每行开头自外向内检查 `while`，不满足的层弹出。
- `include`：`$self`、`$base`、`#name`、其他语法的 `scopeName` 与 `scopeName#name`。引用的语法不存在时忽略该规则。
- 捕获组内的 `patterns`：对捕获文本再次分词。
- `\G` 指当前扫描起点。

暂不支持 `injections`。

**扫描。** 按行处理，行尾补 `\n` 后匹配（与 vscode-textmate 一致），结果裁回行内容。在当前位置，对栈顶规则展开后的候选正则与结束正则分别搜索，取起点最早者；起点相同时按声明顺序，结束正则优先，除非设置了 `applyEndPatternLast`。空匹配且不改变栈时前进一个字符，防止死循环。超过 20,000 字节的行不高亮（IntelliJ 的同名限制）。

**状态。** 行首状态是规则栈：每层记录规则、作用域名、`contentName`，以及替换反向引用后的结束正则文本。两个状态相等当且仅当各层都相等。

**增量更新。** 每个文档缓存每行的行首状态和该行的高亮结果，同时保留缓存对应的快照。新快照到来时：

1. 按字节求新旧文本的公共前缀和公共后缀（与 C++ 的 `relex` 相同），换算成未改动的前导行和尾随行。逐行比较会让文件开头的每次按键都走完整个文件，因此不用。
2. 改动区间之前的缓存保留，之后的缓存按行数差平移，标记为“待验证”。
3. 只为需要显示的行计算结果：从第一个失效行开始逐行分词；进入改动区间之后，某一行的新行首状态与平移后的旧状态相同时，后续缓存全部重新生效，停止重算。

这对应 IntelliJ `LexerEditorHighlighter.incrementalUpdate` 的做法，粒度从 token 改为行。在文件开头打字时，状态通常在改动行之后立即收敛；打开未闭合的块注释或字符串时，失效会延伸到状态重新相同为止，只算到屏幕可见的最后一行。改动之后的旧结果被移走而不是复制。

**扫描预算。** 每次绘制最多扫描 12 ms，每 64 行检查一次。打开大文件后直接跳到末尾时，尚未扫描到的行先不着色，前端立即再次绘制并继续扫描，期间照常响应输入。

**性能。** release 构建下全文件扫描约每秒 4 万到 5 万行：11.4 万行的 Rust 数据文件 2.4 s，1.9 万行的 `vscode.d.ts` 0.38 s，4 千行的 syn `expr.rs` 0.1 s。在 11.4 万行文件中部编辑一个字符后更新可见行约 9 ms，主要是物化连续文本和比较前后缀。基准测试：`SODA_BENCH_FILE=路径 cargo test --release --lib -- --ignored bench --nocapture`。

**正则缓存。** 每条规则的正则只编译一次；带反向引用的结束正则按替换后的文本缓存。编译失败的正则（语法使用了 Oniguruma 也不支持的写法）视为永不匹配，记一次警告。

## C++

不使用 TextMate。高亮在自有词法分析器的结果上进行：`lexer::relex` 增量重新分词，token 种类映射为分类；词法分析器归为 Identifier 的关键字（`int`、`const`、`auto`、`static`、`using` 等）由关键字表补充；预处理行整体标为 Macro，`#include` 的头文件名标为 String。结构层从语法树中取函数定义、类与命名空间的名字，只标记分析器确定的位置。

## 语法的获取与分发

语法与语言配置放在仓库的 `grammars/` 下，每种语言一个目录：

```
grammars/rust/
  grammar.json                 TextMate 语法
  language-configuration.json  注释、括号、缩进与回车规则
  language.json                语言名、作用域名、扩展名、文件名
```

`scripts/import-grammars.sh` 从固定版本的 VS Code 仓库（`extensions/<name>/`）下载这些文件，导入后提交。升级语法就是修改脚本中的版本号、重新导入、看差异、跑测试；没有运行时下载，用户也无法、无需单独更新语法。VS Code 的扩展以 MIT 许可发布，各语法的上游来源与许可记录在 `grammars/NOTICE`。

构建时用 `include_str!` 把语法嵌入可执行文件，首次打开对应语言的文件时才解析。

首批语言（VS Code 1.144.0，共 1.4 MB）：Rust、Python、Go、JavaScript、TypeScript 与 TSX、JSON（含 JSONC、JSON Lines）、YAML、Shell、Lua、Makefile、Markdown、Diff。只导入 JSON 格式的语法；VS Code 中少数 plist 格式的语法（如 JavaScript 的正则表达式语法）不导入，引用它们的规则不生效。语法文件中引用的其他语言（例如 Markdown 代码块中的语言）在已嵌入时生效，否则按纯文本显示。测试会把所有内置语法的每条正则交给 Oniguruma 编译一遍。

## 语言识别

按文件名、再按扩展名在 `language.json` 中查找；C/C++ 扩展名仍由文件服务识别为 C++。未识别的文件为纯文本。

## 渲染

高亮只为可见行计算。TextMate 结果由文档的语言会话持有（见下节），前端按时间预算读取；C++ 的词法缓存和结果文档的着色在前端。`layout` 在裁剪文本时把每个片段标上分类，主题把分类转换为颜色。选区和搜索匹配叠加在分类颜色之上。

## 导航（后续）

- **文件内符号**：TextMate 语言从 `entity.name.function`、`entity.name.type`、`entity.name.class`、`entity.name.namespace` 等作用域收集名字和位置，作为大纲和“跳到本文件符号”的数据源（Sublime Text 的符号列表也是这样得到的）；C++ 从结构分析得到。
- **LSP**：跳转到定义、查找引用、工作区符号和 semantic tokens。没有服务器时，跨文件导航退回单词级查找。
- **缩进与编辑规则**：`language-configuration.json` 的 `indentationRules`、`onEnterRules`、注释与括号对，给 C++ 以外的语言提供通用的回车缩进与注释切换。

## 实施顺序

1. 分类、主题与渲染接入；C++ 词法层。（已完成）
2. TextMate 引擎、增量缓存、语法导入脚本与首批语法。（已完成）
3. C++ 结构层。
4. 语言配置驱动的缩进与注释。
5. 文件内符号与跳转。
6. LSP。

## 语言档案与会话

三个概念各管一件事：

| 概念 | 位置 | 内容 |
|---|---|---|
| `Profile` | `language/profile.rs` | 语言的固定事实：id、显示名、行注释、括号表、配对引号、分析器种类。来自内置清单和语言配置，C++ 的写在代码里 |
| `Language` | `editor/language.rs` | 一个文档选用什么：`PlainText`、`TextMate(profile)`、`Cpp(rules)`。只有 C++ 带配置 |
| `LanguageSession` | `editor/language.rs` | 一个文档的分析状态：C++ 语法树，或 TextMate 结果 |

文件属于哪种语言只由 `catalog().detect(path)` 回答。`FileService` 据此决定是否解析 clang-format 配置并选出 `Language`。高亮、Lua 和状态栏都读 `Profile`，不再各自判断。

键入和回车时语言会话会被克隆做预演，提交成功才替换，所以它必须廉价。TextMate 结果放在共享句柄 `Tokens` 里：克隆只增加引用计数，缓存按每次请求的快照自行同步，预演不会留下痕迹。grammar 在第一次请求时才编译，全局只有一份。

**字面量判断。** 光标位于两个字符之间，本身没有分类，而行尾是否结束字面量因语法而异（Python 的字符串在行尾结束，Rust 的不会）。因此用行首状态扫描光标前的文本，再补一个探针字符：`'a|` 的探针落在字符串内，`'a'|` 的落在外面，行注释末尾也不需要特判。语法用一条 `match` 匹配整段的字面量需要看到结尾，所以同时检查该行自身的分类。

这类查询在编辑时同步进行，所以有 16ms 的预算：大文件冷启动时 TextMate 大约每秒扫 4 万行，刚打开就跳到深处打括号不能等几秒。超时的位置先按代码处理，已扫描的结果保留，绘制时继续补完。

## 结构

`LanguageSession` 回答两个问题：`enclosing(at)` 给出包围位置的平衡括号，`item(at, side)` 给出位置一侧的条目。命令只看 `language/structure.rs` 里的 `Group` 和 `Item`，不接触语法树或 grammar，结构化编辑写在 Lua 里（`lua/pairs.lua`）。

C++ 的答案来自语法树（`cpp/structure.rs`）：节点标记未闭合时不算分组；只含 `#if` 一部分分支的括号也不算，因为两端未必在同一配置下配对。声明里的 `<` 按模板实参处理，`return` 或 `=` 之后沿用 clang-format 的启发式，`x < y && y > z` 是比较。其他语言用 `Scanner` 逐行切分文本，字面量和注释来自 TextMate，每次查询最多读 2 万行；纯文本只有括号和词。

查询不做预演，直接使用文档的语言会话，所以分析结果留在缓存里。
