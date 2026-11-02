# clang-format 配置

配置加载与同步缩进查询分别执行。配置层读取完整 YAML 配置树，解析预设、语言分段和目录继承，编译成 editor 和 parser 使用的 `CppRules`。调用方可以查看完整有效选项、诊断、已应用文件和已搜索路径。

## 内部行为策略

clang-format 配置是项目兼容层，完整选项树用于展示来源、继承和诊断。配置适配器直接生成不可变的 `CppRules`，语法分析和缩进查询不访问 YAML 或配置键名。

| 策略 | 内容 |
| --- | --- |
| `ParserOptions` | 循环、条件、语句、namespace、attribute 和受保护宏的分类 |
| `StructurePolicy` | namespace、extern、成员与访问标签、case 和声明续行行为 |
| `ExpressionPolicy` | 固定续行宽度、括号和操作数对齐、三元表达式策略 |
| `InitializerPolicy` | 初始化列表的块式或续行行为及有效宽度 |
| `ConstructorPolicy` | 构造函数初始化项布局及有效宽度 |
| `DirectivePolicy` | 预处理指令空白位置及有效宽度 |
| `WhitespacePolicy` | 结构宽度、tab stop 宽度及 tab 使用策略 |

策略保存用户选择的行为，具体编辑位置的结构基准、锚点和退化路径由 C++ 求解器计算。求解器内部的 `IndentSlot`、偏移规则和锚点枚举限定在语言模块中；配置对象不持有槽位表。结构查询与表达式续行重放消费同一组行为策略。

| 外部配置示例 | 策略含义 |
| --- | --- |
| `NamespaceIndentation: Inner` | 保留 Inner 策略，查询时判断实际嵌套层级 |
| `AccessModifierOffset: -2` | 保留相对普通成员的 -2 列偏移；查询时结合结构宽度与基准计算 |
| `IndentAccessModifiers: Always` | 成员与访问标签采用分层缩进，enum 保持独立规则 |
| `AlignAfterOpenBracket: true` | 允许参数对齐，查询时寻找实际元素锚点 |
| `BreakConstructorInitializers: BeforeComma` | 初始化项采用与冒号对齐的布局 |
| `PPIndentWidth: -1` | 加载时解析为最终 IndentWidth |
| `BracedInitializerIndentWidth: -1` | 续行式列表采用最终续行宽度；块式列表采用结构宽度 |

Rust 内置模块通过 `CppStyle::compile` 生成同一策略表示，返回 `Result<CppRules, StyleError>`。builder 与 YAML 适配器共用宽度和成员相对偏移校验，非法值在编辑前返回错误。builder 的 `access_specifier_offset` 相对声明基准，编译时转换为策略中相对普通成员的偏移；clang-format 适配器直接保留 `AccessModifierOffset` 的成员相对语义。配置查找与 YAML 兼容由配置模块负责，求解过程与加载过程独立。目标查询契约见[交互缩进设计与契约](indentation.md)。

## 文件查找与继承

`resolve_config` 接受待编辑文件路径，包括尚未创建的文件，从文件所在目录向上查找。同一目录优先选择 `.clang-format`，其次选择 `_clang-format`。匹配配置默认基于 LLVM，找不到配置时使用调用者提供的 fallback 预设，即选项 `cpp-fallback-style`。配置写错时打开文件不受影响，同样使用这个预设。

`BasedOnStyle: InheritParentConfig` 从上一级目录继续查找，并在父配置上应用子配置覆盖。`InheritParentConfig=<directory>` 将查找重定向到指定目录；相对路径以当前配置目录为基准，也支持 `~/`。继承循环、缺失重定向目录和文件读取失败返回错误。普通子配置不自动叠加父配置。

结果的 `sources` 按父到子顺序保存路径和内容，`searched` 包括不存在的候选文件。这些信息供配置来源展示、失效检测及后续文件监听使用。重新加载通过显式调用执行。

## YAML 与语言文档

使用纯 Rust 的 serde-saphyr 解析 YAML，支持 flow mapping、嵌套对象、序列、引用、merge key、注释和引号。重复键和损坏的 YAML 返回错误；语法错误保留解析器的位置诊断。

只有第一个文档可以省略 `Language`，该文档作为后续语言文档的基础。同一语言不能重复。语言文档里的 `BasedOnStyle` 会先重置到对应预设，再应用该文档的覆盖。C++ 文件选择 Cpp 文档；默认文档和 C/C++ 兼容回退遵循 LLVM 的选择顺序，`.h` 可以回退到 C 文档，`.c` 可以回退到 Cpp 文档。没有适用文档的配置会继续向上查找。

预设数据来自 clang-format 23.1.3 的完整 C++ 配置：LLVM、Google、Chromium、Mozilla、WebKit、GNU、Microsoft、clang-format 和 none。数据以 LLVM 基础及其余预设差异保存，构建和运行不依赖 LLVM 库或 clang-format 可执行文件。

## 缩进选项

| 选项 | 交互缩进中的含义 |
| --- | --- |
| `IndentWidth`、`ContinuationIndentWidth`、`TabWidth` | 独立的结构宽度、续行宽度和 tab stop |
| `UseTab` | 五种策略分别处理；兼容 false=Never、true=Always |
| `NamespaceIndentation` | None、Inner、All |
| `AccessModifierOffset` | 保存相对普通成员的偏移，具体列在查询时计算 |
| `IndentAccessModifiers` | 兼容 bool，以及 Never、Always、AfterFirstAccessModifier |
| `IndentCaseLabels` | case/default 相对 switch 的缩进 |
| `IndentWrappedFunctionNames` | 换行后的函数声明名称缩进；兼容旧字段 IndentFunctionDeclarationAfterType |
| `AlignAfterOpenBracket` | 兼容 bool 和旧版枚举，控制用户已经选定换行位置的参数对齐 |
| `AlignOperands`、`BreakBeforeTernaryOperators` | 操作数和三元表达式续行 |
| `Cpp11BracedListStyle`、`BracedInitializerIndentWidth` | 区分块式与函数参数式初始化列表及独立宽度 |
| `ConstructorInitializerIndentWidth`、`BreakConstructorInitializers` | 初始化列表独立宽度、首项与逗号对齐，接受 AfterComma；旧 BeforeComma 开关按 LLVM 的有效布局转换 |
| `IndentPPDirectives`、`PPIndentWidth` | BeforeHash 调整前导空白；AfterHash 按 UseTab 在 # 后生成缩进；ForIndentation 的 Tab 范围仍由层级乘 IndentWidth 决定，PPIndentWidth 决定目标列；Leave 保留两侧空白；包含 include guard 处理 |
| `IndentExternBlock` | 与有效 BraceWrapping.AfterExternBlock 组合决定 extern body 缩进，兼容 true=Indent、false=NoIndent |
| `DisableFormat` | 保留既有缩进；Enter 沿用已有行首空白 |
| `ForEachMacros`、`IfMacros`、`NamespaceMacros` | 识别循环、条件和 namespace 结构 |
| `StatementMacros`、`AttributeMacros` | 区分独立宏语句和声明修饰宏 |
| `WhitespaceSensitiveMacros` | 保留宏内部已有缩进 |
| `MacroBlockBegin`、`MacroBlockEnd` | 将匹配的宏标识符作为块开闭边界，支持带参数调用 |

选项名、类型、枚举和嵌套字段由独立的 `schema.json` 校验，来源是 LLVM 的 YAML mapping/enum traits，不依赖预设是否输出某个字段。序列元素也按声明类型校验。带 enumInput 的 mapping 同时接受其指定的枚举写法，如 `AllowShortFunctionsOnASingleLine: Empty`、`BreakBinaryOperations: Never`。未知顶层选项默认报错，调用者可以选择警告并保留；未知嵌套字段返回带完整字段路径的错误。

布尔字段接受 LLVM 的 true/false、yes/no、on/off、y/n 写法及大小写变体。带引号的整数支持 LLVM 的进制前缀。核心缩进宽度限制在 0 到 4096，TabWidth 必须大于零。BracedInitializerIndentWidth 和 PPIndentWidth 的任意负值按 LLVM 规则选择默认宽度。所有顶层选项的类型及应用范围见[选项对照表](clang-format-options.csv)。表中的 interactive 表示接入策略，具体语法场景仍由语言服务支持；retained 表示保存配置，未执行该 formatter 行为。

## 已解析选项与实现范围

完整选项树保留列宽、排序、换行及其他排版配置，缩进器只使用与当前交互能力相关的字段。配置层不执行完整 formatter 的跨字段约束和全部旧字段归一化。标量和 mapping 的合法兼容形式保留在选项树中；与即时缩进相关的旧字段在策略编译前转换。

显式配置 `IndentCaseBlocks`、`IndentGotoLabels`、`IndentRequiresClause`、`LambdaBodyIndentation`，或预设对这些选项采用不同于 LLVM 基线的值时，会返回尚未参与交互缩进的诊断。`AlignOperands: AlignAfterOperator` 编译为独立的 AfterOperator 策略值，目前执行时采用 Align 的续行规则，并返回诊断。GNU、Whitesmiths 或自定义额外 brace indentation 同样返回能力诊断。显式选择 AlignFirstComment（包括旧 true 写法）时，会说明当前采用 FunctionCall 续行规则，尚未实现首注释锚点的区别。

导出块、requires expression、StatementAttributeLikeMacros、TypenameMacros、TypeNames、TemplateNames、VariableTemplates、Macros 和 SkipMacroDefinitionBody 尚未接入语法或缩进策略。显式设置或偏离 LLVM 基线时返回能力诊断；旧 IndentRequires 先转换成 IndentRequiresClause，再参与诊断。枚举写法能通过配置校验不表示相应语法行为已经实现。

宏块正则采用 Rust `regex` 的语法，对完整标识符执行搜索；需要精确匹配时使用 `^`、`$`。配置加载和 `CppStyle::compile` 校验表达式。常用的分组、分支和字符类可直接使用，LLVM 正则的其他扩展语法不保证兼容。

能力诊断根据最终有效配置重新生成，覆盖语言分段、目录继承和预设选择。覆盖为受支持的策略后，先前的能力诊断消失。诊断保留有效选项的 YAML 文档编号，预设自带的诊断使用编号 0。

查询以用户指定的换行位置为输入，不根据排版配置另行选择换行位置。旧版 AlwaysBreak/BlockIndent 配置在解析层按新版兼容语义保存，参数对齐使用转换后的设置。

## 验证与参考

运行 `cargo test --test config` 检查 YAML、预设、覆盖、目录继承、语言选择、错误和配置到编辑操作的链路。如果安装了 `clang-format-23`，预设测试还会与其 `--dump-config` 结果对照。

配置语义参考 [LLVM 配置文档](https://clang.llvm.org/docs/ClangFormatStyleOptions.html) 及 `~/project/llvm-project/clang/lib/Format/Format.cpp` 的 YAML mapping、`parseConfiguration`、`getStyle` 和预设定义。空白策略参考同仓库的 `WhitespaceManager.cpp`，即时续行参考 `ContinuationIndenter.cpp`。

## 更新校验表与参考用例

运行 `python3 scripts/generate_clang_format_schema.py ~/project/llvm-project` 更新类型表、枚举输入用例和选项应用对照表。生成器解析 Format.cpp/Format.h 和 IncludeStyle.cpp/IncludeStyle.h 的声明，以及 TokenKinds.def 的 token 拼写；未识别的类型中止生成。生成结果记录 LLVM revision。升级时仍需阅读条件兼容转换及选项使用点，分别检查 `config/cpp.rs` 的策略映射和语言求解器行为。

运行 `python3 scripts/generate_clang_format_indent_cases.py clang-format-23` 捕获参考布局。测试固定参考实现已经选定的布局，只扰动并恢复非空行的前导空白，不改变换行位置。编辑中的空行保留供下一次输入使用的缩进，不套用完整 formatter 的空行清理规则。独占一行的结构左括号以所属声明或控制语句的行首为基准，输入 `{` 时的前导空白调整与字符插入合并为一个撤销单元；额外括号缩进策略受上述能力诊断限制。

`cargo test --test clang_format_options --test config` 验证枚举兼容、可选字段和序列类型、策略映射以及编辑结果。类型定义取自本地 LLVM 的记录 revision，布局用例及预设记录其 clang-format 可执行文件版本；二者可能处于不同版本，新增取值需以对应来源分别核对。

完成预处理分支关键字 endif、else、elif 等时，语言服务重新求解当前指令的层级，使输入 # 时的临时缩进随关键字收敛。普通文本先按行首过滤，字符串和注释中的字符不参与这个触发路径。调整与最后一个字符的插入属于同一事务。
