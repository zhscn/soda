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

`resolve_config` 接受待编辑文件路径，包括尚未创建的文件，从文件所在目录向上查找。同一目录优先选择 `.clang-format`，其次选择 `_clang-format`。匹配配置默认基于 LLVM，找不到配置时使用调用者提供的 fallback 预设。

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
| `UseTab` | Never、ForIndentation、ForContinuationAndIndentation、AlignWithSpaces、Always 分别处理 |
| `NamespaceIndentation` | None、Inner、All |
| `AccessModifierOffset` | 保存相对普通成员的偏移，具体列在查询时计算 |
| `IndentAccessModifiers` | 兼容 bool，以及 Never、Always、AfterFirstAccessModifier |
| `IndentCaseLabels` | case/default 相对 switch 的缩进 |
| `IndentWrappedFunctionNames` | 换行后的函数声明名称缩进 |
| `AlignAfterOpenBracket` | 兼容 bool 和旧版枚举，控制用户已经选定换行位置的参数对齐 |
| `AlignOperands`、`BreakBeforeTernaryOperators` | 操作数和三元表达式续行 |
| `Cpp11BracedListStyle`、`BracedInitializerIndentWidth` | 区分块式与函数参数式初始化列表及独立宽度 |
| `ConstructorInitializerIndentWidth`、`BreakConstructorInitializers` | 初始化列表独立宽度、首项与逗号对齐 |
| `IndentPPDirectives`、`PPIndentWidth` | BeforeHash 的前导空白和 AfterHash 的关键字间距，包含 include guard 处理 |
| `IndentExternBlock` | 与有效 BraceWrapping.AfterExternBlock 组合决定 extern body 缩进 |
| `DisableFormat` | 保留既有缩进；Enter 沿用已有行首空白 |
| `ForEachMacros`、`IfMacros`、`NamespaceMacros` | 识别循环、条件和 namespace 结构 |
| `StatementMacros`、`AttributeMacros` | 区分独立宏语句和声明修饰宏 |
| `WhitespaceSensitiveMacros` | 保留宏内部已有缩进 |

LLVM 当前映射里的旧字段拼写保留在已知选项表中。未知顶层选项默认报错，调用者可以选择警告并保留。核心缩进字段校验类型与枚举；宽度限制在 0 到 4096，TabWidth 必须大于零。嵌套配置检查形状和已知子字段。

## 已解析选项与实现范围

完整选项树保留列宽、排序、换行及其他排版配置，缩进器只使用与当前交互能力相关的字段。配置层没有实现完整 formatter 的语义校验与跨字段约束。

显式配置 `IndentCaseBlocks`、`IndentGotoLabels`、`IndentRequiresClause`、`LambdaBodyIndentation`、`MacroBlockBegin` 和 `MacroBlockEnd`，或预设对这些选项采用不同于 LLVM 基线的值时，会返回尚未参与交互缩进的诊断。`AlignOperands: AlignAfterOperator` 编译为独立的 AfterOperator 策略值，目前执行时采用 Align 的续行规则，并返回诊断。GNU 或自定义额外 brace indentation 同样需要后续语言规则实现。

能力诊断根据最终有效配置重新生成，覆盖语言分段、目录继承和预设选择。覆盖为受支持的策略后，先前的能力诊断消失。诊断保留有效选项的 YAML 文档编号，预设自带的诊断使用编号 0。

查询以用户指定的换行位置为输入，不根据排版配置另行选择换行位置。旧版 AlwaysBreak/BlockIndent 配置在解析层按新版兼容语义保存，参数对齐使用转换后的设置。

## 验证与参考

运行 `cargo test --test config` 检查 YAML、预设、覆盖、目录继承、语言选择、错误和配置到编辑操作的链路。如果安装了 `clang-format-23`，预设测试还会与其 `--dump-config` 结果对照。

配置语义参考 [LLVM 配置文档](https://clang.llvm.org/docs/ClangFormatStyleOptions.html) 及 `~/project/llvm-project/clang/lib/Format/Format.cpp` 的 YAML mapping、`parseConfiguration`、`getStyle` 和预设定义。空白策略参考同仓库的 `WhitespaceManager.cpp`，即时续行参考 `ContinuationIndenter.cpp`。
