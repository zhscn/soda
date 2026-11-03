# 语法高亮与结构

C++ 和 Rust 有自己的词法与结构分析；其他语言参照 IntelliJ，用 TextMate 语法提供高亮和基本编辑规则，语法级导航交给 LSP。不用 tree-sitter：解析器是要按 ABI 分发的原生代码，查询文件还要跟着节点名维护。TextMate 语法是纯数据，可以连同语言配置嵌入可执行文件。

## 分层

| 层 | C++ | Rust | 其他语言 |
| --- | --- | --- | --- |
| 词法高亮 | 自有词法分析器加关键字表 | TextMate | TextMate |
| 语义高亮 | LSP semantic tokens | 同左 | 同左 |
| 结构（结构化命令、字面量判断） | `cpp/structure.rs`，来自语法树 | `rust/structure.rs`，来自自有词法分析 | `Scanner` 按行切分，字面量来自 TextMate |
| 缩进（见[缩进](indentation.md)） | clang-format 规则 | rustfmt 的块风格（`rust/indent.rs`） | 只按括号 |
| 注释、括号、配对引号 | 写在代码里 | `language-configuration.json` | `language-configuration.json` |
| 符号与跨文件导航 | LSP | LSP | LSP |

上层可用时覆盖下层，缺失时退回下一层，不报错。纯文本不高亮，结构只有括号和词。结果文档（`grep` 等）按自己的格式着色。

## 分类

高亮结果是字节范围加一个固定分类。主题只为分类配色（face `syntax.NAME`），不认识作用域名或 token 类型。

| 分类 | TextMate 作用域前缀 | C++ 来源 |
| --- | --- | --- |
| comment | `comment` | 注释 |
| string | `string`、`markup.raw`、`markup.inline.raw` | 字符串、字符字面量、`#include` 的头文件名 |
| escape | `constant.character.escape` | — |
| number | `constant.numeric` | 数字 |
| constant | `constant.language`、`constant.other`、`support.constant`、`variable.other.constant`、`variable.language` | `true`、`false`、`nullptr`、`this` |
| keyword | `keyword`、`storage` | 关键字 |
| operator | `keyword.operator` | 运算符 |
| type | `entity.name.type`、`.class`、`.struct`、`.enum`、`.interface`、`.trait`、`entity.other.inherited-class`、`support.type`、`support.class`、`storage.type.primitive`、`.numeric`、`.boolean`、`.string` | 内建类型关键字 |
| function | `entity.name.function`、`support.function` | — |
| parameter | `variable.parameter` | — |
| namespace | `entity.name.namespace`、`entity.name.module` | — |
| macro | `meta.preprocessor`、`meta.attribute`、`entity.name.function.preprocessor`、`entity.name.function.macro`、`support.function.macro` | 预处理指令 |
| tag | `entity.name.tag` | — |
| attribute | `entity.other.attribute-name` | — |
| heading | `markup.heading`、`entity.name.section` | — |
| emphasis / strong | `markup.italic` / `markup.bold` | — |
| link | `markup.underline.link`、`string.other.link` | — |
| inserted / deleted / changed | `markup.inserted` / `.deleted` / `.changed` | — |
| invalid | `invalid` | 无法识别的字符 |
| match | — | 搜索结果文档中的匹配 |

TextMate token 的作用域从内到外取第一个能映射的；每个作用域按最长点分前缀匹配（`keyword.operator.assignment` 先试 `keyword.operator`，再退回 `keyword`），与 IntelliJ `TextMateDefaultColorsProvider` 相同。C++ 只有词法层：`#` 和指令名标为 macro，`#include`/`import` 之后标为 string，其他指令的其余部分按普通代码；函数、类型等名字靠语义高亮。

## TextMate 引擎

自己实现（`src/syntax/textmate/`），正则用 `onig`（静态编译 Oniguruma）：VS Code 的语法用 Oniguruma 方言（后向断言、`\G`、所有格量词等），纯 Rust 正则库不能完整支持。

支持 `match` 与 `captures`；`begin`/`end`（`beginCaptures`、`endCaptures`、`contentName`、`applyEndPatternLast`、`end` 对 `begin` 捕获组的反向引用）；`begin`/`while`（每行开头自外向内检查，不满足的层弹出）；`include` 的 `$self`、`$base`、`#name`、`scopeName`、`scopeName#name`（不存在时忽略）；捕获组内的 `patterns`；`\G`；注入（下节）。

- **注入**：同 vscode-textmate，只有正在扫描的语法（`$base`）带来注入：它自己的 `injections`，以及清单里 `injectTo` 指向它的语法（用其 `injectionSelector` 和根规则）。嵌入的语言不带自己的注入，所以 Markdown 代码块里的 TypeScript 没有 JSDoc 注入。选择器按 `matcher.ts` 解析：逗号分隔多个选择器，各带优先级（`L:` 在规则自身的模式之前，无前缀与 `R:` 在之后）；空格是有序的后代路径，作用域按点分前缀匹配；`-` 取反，括号内 `|` 与 `,` 是或。选择器看规则栈的作用域名：根是语法的 `scopeName`，每层是 `name` 再加 `contentName`。每一步注入与当前层的模式和结束正则一起比较，起点更早者胜，起点相同时只有 `L:` 的注入胜过当前层。栈每变一层才重新挑选匹配的注入；捕获组的 `patterns` 在所处的栈上扫描，同样看得到注入。

- **扫描**：按行，行尾补 `\n` 后匹配（同 vscode-textmate）。候选正则与结束正则取起点最早者；起点相同时按声明顺序，结束正则优先，除非 `applyEndPatternLast`。`\G` 只在锚点成立：锚点是最近一次 `begin` 或 `while` 匹配的结尾，弹出一层时恢复进入它之前的锚点；`begin` 吃到行尾的规则把下一行行首当锚点；捕获组内没有锚点。其他位置的搜索用把 `\G` 换成非字符的同一正则。行尾之后仍继续匹配（空的 `begin` 可以在行尾进入规则，比如 Markdown 代码块在开头那一行就进入内容规则）。不前进的匹配：进入规则没问题，除非同一位置进入的层里已有同一规则；退出规则也没问题，除非这一层就是在这个位置进入的；这两种循环以及不改变栈的空匹配都撤销并跳过一个字符。超过 20,000 字节的行不高亮。
- **状态**：行首状态是规则栈，每层记录规则、作用域名、`contentName` 和替换反向引用后的结束正则。
- **增量**：缓存每行的行首状态和结果。新快照到来时按字节求公共前缀和后缀，换算成未改动的行；改动之后的缓存按行数差平移并标为待验证。只为要显示的行从第一个失效行起重算，进入改动区间后某行的新状态与平移后的旧状态相同就停止。对应 IntelliJ 的 `LexerEditorHighlighter.incrementalUpdate`，粒度是行。
- **预算**：每次绘制最多扫描 12 ms，每 64 行检查一次；没扫到的行先不着色，前端立即再画一帧继续扫。
- **正则缓存**：每条规则的正则只编译一次，带反向引用的结束正则按替换后的文本缓存。编译失败的视为永不匹配，记一次警告。
- **性能**（release）：全文扫描每秒约 4–5 万行（11.4 万行 2.4 s，`vscode.d.ts` 1.9 万行 0.42 s，其中约 0.04 s 是 JSDoc 注入在文档注释里多做的匹配）；在 11.4 万行文件中部改一个字符后更新可见行约 9 ms。基准：`SODA_BENCH_FILE=路径 cargo test --release --lib -- --ignored bench --nocapture`。

## 语法的分发

`scripts/import-grammars.sh` 从固定版本的 VS Code（`extensions/<name>/`）下载语法和语言配置到 `grammars/`，并生成 `src/syntax/bundled.rs`（`include_str!` 嵌入）。每种语言一个目录：

```
grammars/rust/
  package.json                 裁剪后的清单：语言 id、别名、扩展名、文件名、语法
  language-configuration.json  注释、括号、配对
  syntaxes/*.tmLanguage.json   TextMate 语法
  cgmanifest.json              上游来源与许可
```

VS Code 的许可在 `grammars/LICENSE.vscode.txt`，版本在 `grammars/VERSION`。升级就是改脚本里的版本号、重新导入、看差异、跑测试；没有运行时下载。语法在第一次用到时才编译，全局一份。

内置语言（VS Code 1.144.0，共 1.4 MB）：Rust、Python、Go、JavaScript、TypeScript 与 TSX、JSON（含 JSONC、JSON Lines）、YAML、Shell、Lua、Makefile、Markdown、Diff。注入语法：TypeScript 包里的 JSDoc（注入 JavaScript、TypeScript）和 markdown-math（Markdown 的 `$…$`、`$$…$$` 与 ```` ```math ```` 代码块）；清单保留 `injectTo`。只导入 JSON 格式的语法，引用 plist 语法的规则不生效；引用其他语言（如 Markdown 代码块）时，该语言已嵌入才生效。测试把所有内置正则交给 Oniguruma 编译一遍。

## 语言识别

`catalog().detect(path)` 先按完整文件名、再按最长扩展名查找，C/C++ 的扩展名也在其中；未识别的为纯文本。`language-map` 可以覆盖，见[扩展](extension.md#语言映射)。

## 语言档案与会话

| 概念 | 位置 | 内容 |
| --- | --- | --- |
| `Profile` | `language/profile.rs` | 语言的固定事实：id、显示名、行注释、括号、配对引号、分析器种类（`Plain`、`Cpp`、`TextMate`） |
| `Language` | `editor/language.rs` | 文档选用什么：`PlainText`、`TextMate(profile)`、`Cpp(rules)` |
| `LanguageSession` | `editor/language.rs` | 文档的分析状态：C++ 语法树；或 TextMate 结果，Rust 另带 `RustSession` |

高亮、Lua 和状态栏都读 `Profile`。键入和回车时语言会话被克隆做预演，提交成功才替换，所以克隆必须廉价：TextMate 结果在共享句柄 `Tokens` 里，Rust 的分析在 `Arc` 里，文本不变就复用。

**字面量判断**（`in_literal`，决定括号和引号是否配对）：C++ 和 Rust 查自己的 token。其他语言用行首状态扫描光标前的文本，再补一个探针字符（`'a|` 的探针在字符串内，`'a'|` 的在外面），同时检查该行自身的分类。这类查询同步进行，预算 16 ms，超时的位置先按代码处理。

## 结构

`LanguageSession` 回答两个问题：`enclosing(at)` 给出包围位置的平衡括号，`item(at, side)` 给出一侧的条目（词、字面量、注释、指令或整个括号组）。命令只看 `language/structure.rs` 的 `Group` 和 `Item`，结构化编辑写在 Lua 里（`lua/pairs.lua`），命令见[交互](interaction.md)。

- **C++**（`cpp/structure.rs`）：节点未闭合时不算分组；只含 `#if` 一部分分支的括号也不算。声明里的 `<` 按模板实参处理，`return` 或 `=` 之后沿用 clang-format 的启发式。
- **Rust**（`rust/structure.rs`）：配对括号、泛型列表和闭包参数 `|…|`。
- **其他语言**：`Scanner` 逐行切分，每次查询最多读 2 万行。

查询不做预演，直接用文档的会话，分析结果留在缓存里。
