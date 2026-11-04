# clang-format 配置

配置层（`src/config/`）读取完整 YAML 配置树，解析预设、语言分段和目录继承，编译成编辑和分析使用的 `CppRules`。调用方可以查看完整有效选项、诊断、已应用的文件和已搜索的路径。配置加载与缩进查询分开执行，查询契约见[交互缩进设计与契约](indentation.md)。

## 内部行为策略

`config/cpp.rs` 把有效选项直接编译成不可变的 `CppRules`；语法分析和缩进查询不访问 YAML 或选项名。

| 策略 | 内容 |
| --- | --- |
| `ParserOptions` | 循环、条件、语句、namespace、attribute、受保护宏和 TemplateNames 的分类，宏块边界 |
| `StructurePolicy` | namespace、extern、export、成员与访问标签、case、goto 标签、requires、lambda、花括号缩进、宏定义体和函数名续行 |
| `ExpressionPolicy` | 续行宽度、括号和操作数对齐、三元表达式、基类列表和二元运算符换行 |
| `InitializerPolicy` | 初始化列表的块式或续行布局、宽度、首个注释 |
| `ConstructorPolicy` | 构造函数初始化项布局与宽度 |
| `DirectivePolicy` | 预处理指令空白位置与宽度 |
| `WhitespacePolicy` | 结构宽度、tab stop 与 tab 使用策略 |

策略只保存用户选择的行为；具体位置的结构基准、锚点和退化路径由 C++ 求解器在查询时计算。`IndentSlot` 和规则表限定在 `src/cpp/`，配置对象不持有槽位。

| 外部配置示例 | 策略含义 |
| --- | --- |
| `NamespaceIndentation: Inner` | 保存 Inner，查询时判断实际嵌套层级 |
| `AccessModifierOffset: -2` | 保存相对普通成员的 -2 列，查询时结合结构宽度和基准计算 |
| `IndentAccessModifiers: Always` | 成员与访问标签分层缩进，enum 不受影响 |
| `AlignAfterOpenBracket: true` | 允许参数对齐，查询时寻找实际元素锚点 |
| `BreakConstructorInitializers: BeforeComma` | 初始化项与冒号对齐 |
| `PPIndentWidth: -1` | 加载时解析为 IndentWidth |
| `BracedInitializerIndentWidth: -1` | 续行式列表用续行宽度，块式列表用结构宽度 |

Rust 代码也可以用 builder `CppStyle::compile` 得到 `Result<CppRules, StyleError>`。builder 与 YAML 适配器共用宽度和偏移校验，非法值在编辑前报错。builder 的 `access_specifier_offset` 相对声明基准，编译时转换为相对普通成员的偏移；YAML 适配器直接保留 `AccessModifierOffset` 的成员相对语义。

## 文件查找与继承

`resolve_config` 接受待编辑文件的路径（可以尚未创建），从所在目录向上查找；同一目录 `.clang-format` 优先于 `_clang-format`。找到的配置以 LLVM 为基础。找不到配置时使用选项 `cpp-fallback-style` 指定的预设（默认 LLVM）；配置有错时文件照常打开，同样使用该预设，并记录原因。

`BasedOnStyle: InheritParentConfig` 从上一级目录继续查找，在找到的父配置（找不到时为 fallback 预设）上应用子配置。`InheritParentConfig=<目录>` 把查找重定向到指定目录，相对路径以当前配置所在目录为基准，支持 `~/`。继承循环、重定向目录不存在和读取失败都返回错误。普通子配置不叠加父配置。

结果的 `sources` 按父到子顺序保存路径和内容，`searched` 包括不存在的候选文件，供来源展示和失效检测使用。重新加载由调用方显式触发。

## YAML 与语言文档

YAML 由纯 Rust 的 serde-saphyr 解析，支持 flow mapping、嵌套对象、序列、引用、merge key、注释和引号。重复键和损坏的 YAML 返回带位置的错误。

只有第一个文档可以省略 `Language`，它是后续语言文档的基础；同一语言不能重复。语言文档里的 `BasedOnStyle` 先重置到对应预设，再应用该文档的覆盖。`.c` 文件选择 C 文档，其余选择 Cpp 文档；找不到时依次用无语言的文档、兼容回退（`.h` 可用 C 文档，`.c` 可用 Cpp 文档）。没有适用文档的配置被跳过，继续向上查找；最终只找到不适用的配置时返回错误。

预设取自 clang-format 23.1.3 的完整 C++ 配置：LLVM、Google、Chromium、Mozilla、WebKit、GNU、Microsoft、clang-format 和 none，保存在 `src/config/presets.json`。构建和运行不依赖 LLVM 库或 clang-format 可执行文件。

## 缩进选项

| 选项 | 交互缩进中的含义 |
| --- | --- |
| `IndentWidth`、`ContinuationIndentWidth`、`TabWidth` | 结构宽度、续行宽度、tab stop，三者独立 |
| `UseTab` | 五种策略分别处理；兼容 false=Never、true=Always |
| `NamespaceIndentation` | None、Inner、All |
| `AccessModifierOffset` | 相对普通成员的偏移，具体列在查询时计算 |
| `IndentAccessModifiers` | 兼容 bool，以及 Never、Always、AfterFirstAccessModifier |
| `IndentCaseLabels` | case/default 相对 switch 的缩进 |
| `LambdaBodyIndentation` | Signature：lambda 体以签名所在的嵌套块基准缩进一级；OuterScope：以包含 lambda 的语句所在行为基准，与签名所在列无关 |
| `IndentGotoLabels` | goto 标签相对块内语句：NoIndent 在第 0 列，OuterIndent 少一级，InnerIndent 同列，HalfIndent 少半级；兼容 true（OuterIndent）和 false（NoIndent） |
| `IndentRequiresClause` | 独占一行的 requires 子句（在 `template<…>` 或函数声明符之后）相对声明缩进一级或对齐；旧名 IndentRequires 先转换。子句按 `RequiresClausePosition: OwnLine` 识别，约束是用 `&&`/`||` 连接的名字（可带模板实参）或括号表达式 |
| `RequiresExpressionIndentation` | OuterScope：requires 表达式的体像 lambda 体一样以所在语句（或括号内的嵌套块基准）缩进一级；Keyword：以 `requires` 所在列缩进一级，`}` 回到该列 |
| `IndentExportBlock` | `export { … }` 内的声明是否缩进；`export namespace` 按 NamespaceIndentation，export 块内的 namespace 算内层 |
| `IndentCaseBlocks` | 关闭时 case 标签直接打开的块与标签同级（`BraceWrapping.AfterCaseLabel` 时 `{` 独占一行；标签与 `{` 之间有独占一行的注释时按普通块处理）；开启时它是 case 的普通语句 |
| `IndentWrappedFunctionNames` | 返回类型之后换行的函数名（含 `A::B<…>::` 限定和 `operator`）；兼容旧名 IndentFunctionDeclarationAfterType。有函数体，或括号内是声明（空、类型名、`const`、带名字的参数、`...`）的是函数；括号内是实参（字面量、`{`）的是变量，按续行缩进。独占一行的 `[[…]]` 属性之后是声明开头 |
| `BreakInheritanceList` | 逗号之后的基类与第一个基类对齐，冒号在行尾时下一行按续行缩进；BeforeComma 时以逗号开头的行在续行缩进处。基类的模板实参从该基类起始列续行 |
| `AlignAfterOpenBracket` | 兼容 bool 和旧枚举（含 AlwaysBreak、BlockIndent），控制用户已选定换行位置的参数对齐 |
| `BreakBeforeBinaryOperators` | 不为 None 时，运算符之后的操作数不另起续行基准，其中换行的括号从运算符所在行的基准续行（clang-format 只在 None 时把基准移到右操作数）；兼容 true（All）和 false（None） |
| `AlignOperands`、`BreakBeforeTernaryOperators` | 操作数和三元表达式续行；AlignAfterOperator 时，`=` 或 `return` 之后以运算符开头的续行左移运算符宽度，使操作数对齐 |
| `Cpp11BracedListStyle`、`BracedInitializerIndentWidth` | 区分块式与函数参数式初始化列表及其宽度；Block 与 AlignFirstComment（含旧 true）把紧跟 `{` 的行注释当作第一个元素，后续元素与它对齐；FunctionCall 在 `{` 之后换行 |
| `ConstructorInitializerIndentWidth`、`BreakConstructorInitializers` | 初始化列表宽度、首项与逗号对齐，接受 AfterComma；旧 BeforeComma 开关按 LLVM 的有效布局转换 |
| `IndentPPDirectives`、`PPIndentWidth` | BeforeHash 调整前导空白；AfterHash 按 UseTab 在 `#` 后生成缩进；ForIndentation 的 tab 范围由层级乘 IndentWidth 决定，PPIndentWidth 决定目标列；Leave 保留两侧空白；处理 include guard |
| `BreakBeforeBraces`、`BraceWrapping.IndentBraces` | 独占一行的花括号缩进一级：GNU 与 IndentBraces 缩进控制语句、case 块和 lambda 的花括号，块体再缩进一级；Whitesmiths 缩进除 lambda 外所有块的花括号，块体与花括号同列。行尾花括号不受影响。BeforeLambdaBody 时，语句层级的 lambda 以语句起始行为基准，参数中的 lambda 若 `[` 在行首则以该行为基准、否则与参数对齐，体与 `}` 以这个 `{` 所在行为基准 |
| `IndentExternBlock` | 与有效的 BraceWrapping.AfterExternBlock 共同决定 extern 体缩进；兼容 true=Indent、false=NoIndent |
| `DisableFormat` | 不触发输入调整，重新缩进保留原字节；Enter 沿用上一行前导空白 |
| `ForEachMacros`、`IfMacros`、`NamespaceMacros` | 识别循环、条件和 namespace 结构 |
| `StatementMacros`、`AttributeMacros` | 区分独立宏语句和声明修饰宏 |
| `WhitespaceSensitiveMacros` | 保留宏内部已有缩进 |
| `SkipMacroDefinitionBody` | `#define` 的续行保留原有缩进，Enter 沿用上一行前导空白 |
| `TemplateNames` | 这些名字后的 `<` 总是打开模板实参；`>` 尚未输入时按未闭合的实参列表处理 |
| `Macros` | 展开以 `for`、`while` 或 `if` 开头的函数式宏按 ForEachMacros 或 IfMacros 处理；其他定义只保存，并产生能力诊断 |
| `MacroBlockBegin`、`MacroBlockEnd` | 匹配的宏标识符作为块的开闭边界，可以带参数调用 |

## 已解析选项与实现范围

选项名、类型、枚举和嵌套字段由 `src/config/schema.json` 校验，它生成自 LLVM 的 YAML mapping/enum traits，与预设是否输出某字段无关。序列元素按声明类型校验；带 enumInput 的 mapping 同时接受对应的枚举写法（`AllowShortFunctionsOnASingleLine: Empty`、`BreakBinaryOperations: Never`）。未知顶层选项默认报错，调用方可以改为警告并保留（`UnknownOptions::Warn`）；未知嵌套字段返回带完整路径的错误。

布尔值接受 LLVM 的 true/false、yes/no、on/off、y/n 及大小写变体；带引号的整数支持 LLVM 的进制前缀。宽度限制在 0 到 4096，TabWidth 必须大于零；BracedInitializerIndentWidth 和 PPIndentWidth 的负值按 LLVM 规则取默认宽度。

完整选项树保留列宽、排序、换行等全部排版配置，缩进只使用相关字段。配置层不执行 formatter 的跨字段约束和全部旧字段归一化；与缩进相关的旧字段（IndentRequires、IndentFunctionDeclarationAfterType、AlignAfterOpenBracket 旧枚举等）在编译策略前转换。查询以用户选定的换行位置为输入，不按排版配置另选换行位置。

[选项对照表](clang-format-options.csv) 列出每个顶层选项的类型和应用范围：`interactive` 表示接入策略（`partial strategies` 表示只支持部分写法），`configuration` 表示配置选择本身，`retained` 表示只保存、不执行。StatementAttributeLikeMacros、TypenameMacros、TypeNames 和 VariableTemplates 只影响 clang-format 对 `*`、`&`、类型转换的标注和空格，用 clang-format 23 对照不改变行首缩进，因此只保存。枚举写法通过校验不代表相应语法行为已经实现。

宏块正则使用 Rust `regex` 语法，在完整标识符上搜索；需要精确匹配时加 `^`、`$`。配置加载和 `CppStyle::compile` 校验表达式。常用的分组、分支和字符类可以直接用，LLVM 正则的其他扩展不保证兼容。

能力诊断按最终有效配置（语言分段、目录继承、预设选择之后）重新生成，并记录选项所在的 YAML 文档编号，预设自带的为 0。目前唯一的能力诊断是 `Macros` 中有不展开为循环或 `if` 头部的定义。

## 验证与参考

| 命令 | 覆盖 |
| --- | --- |
| `cargo test --test it config::` | YAML、预设、覆盖、目录继承、语言选择、错误和配置到编辑操作的链路；装有 `clang-format-23` 时预设与其 `--dump-config` 对照 |
| `cargo test --test it clang_format_options::` | 枚举兼容、可选字段、序列类型、策略映射和编辑结果 |

配置语义以 [LLVM 配置文档](https://clang.llvm.org/docs/ClangFormatStyleOptions.html) 和 clang-format 源码为准。

## 更新校验表与参考用例

`python3 scripts/generate_clang_format_schema.py LLVM_SOURCE_DIR` 重新生成 `src/config/schema.json`、`tests/fixtures/clang_format_options.json` 和 `docs/clang-format-options.csv`。生成器解析 Format.cpp/Format.h、IncludeStyle.cpp/IncludeStyle.h 的声明和 TokenKinds.def 的 token 拼写，遇到未识别的类型即中止，结果记录 LLVM revision。升级时仍需阅读条件兼容转换和选项使用点，分别检查 `config/cpp.rs` 的策略映射和求解器行为。

`python3 scripts/generate_clang_format_indent_cases.py [clang-format-23]` 用 clang-format 捕获参考布局，写入 `tests/fixtures/clang_format_indent_options.json`。测试固定参考布局，只扰动并恢复非空行的前导空白，不改变换行位置。编辑中的空行保留供下次输入使用的缩进，不套用 formatter 的空行清理。独占一行的结构左括号以所属声明或控制语句的行首为基准（GNU、Whitesmiths 再缩进一级），输入 `{` 时的空白调整与字符插入同属一个撤销单元。

类型定义取自本地 LLVM 的记录 revision，布局用例和预设记录 clang-format 可执行文件的版本；两者可能不同，新增取值需分别核对对应来源。
