# 交互缩进设计与契约

缩进以一次编辑操作为单位：给定文档快照、行和触发方式，语言返回该行的前导空白建议，编辑操作层把建议与用户输入组合成一个事务。语法树、启发式、续行栈和规则表属于语言内部；编辑内核只看到修改范围、空白和选区。

## 1 职责与表示

| 层 | 输入 → 输出 | 位置 |
| --- | --- | --- |
| 配置适配 | clang-format 配置 → 已校验的 `CppRules` | `src/config/`，见[clang-format 配置](clang-format.md) |
| 语法分析 | 快照与 `ParserOptions` → token、结构树、宏分类 | `src/cpp/` 的 lexer、parser、incremental、container |
| 缩进求解 | 行、分析、`CppRules` 与实际布局 → `IndentDecision` | `src/cpp/indent.rs`、`expression.rs`、`indent_rules.rs` |
| 空白生成 | 列与 tab 策略 → 字节 | `language::materialize`，与语言无关 |
| 输入协调 | 用户操作与建议 → 原子事务和选区 | `src/editor/operations.rs` |

`CppRules` 只读，描述用户选择的行为，不描述分析器怎样识别；风格变化通过替换整个 `CppRules` 生效。锚点在查询时求出，分析树不保存由缩进宽度算出的列。`IndentSlot`、`IndentRole` 和规则表是求解器内部表示，不是配置格式或接口。

## 2 分析方法与参考边界

C++ 分析容忍未完成的输入：词法确定字符串、注释和预处理续行的边界，容错结构分析识别作用域和逻辑语句，模板、初始化列表、冒号和宏等歧义按需分类，续行求解重放实际布局。行为以 clang-format 为准，但保留用户选定的换行位置；插入位置查询和缩进/对齐分离借鉴 IntelliJ。

空白行或两个 token 之间的位置可能不属于任何节点，查询同时看前缀、后缀和未闭合结构：在 `call(first,|second)` 中回车，后缀仍属参数列表；`class A { public:|` 后回车，查询的是成员位置。

### 预处理与宏

- 指令按逻辑行解析，反斜杠续行属于同一指令；指令体中未闭合的括号不吞并后面的指令或代码。条件分支可以各自打开或关闭代码块，包括两段 `#ifdef __cplusplus` 包围开闭括号的 `extern "C"`。条件表达式不求值。
- `#define` 的替换部分是缩进一级的代码：取出替换文本并保留各行列位置，放进内容从宏体基准列开始的代码块，按普通代码求解，所以 `if` 体、`case` 体、`do { } while (0)` 和 `<<` 对齐与 clang-format 一致。函数式宏的参数换行时与第一个参数对齐（AlignAfterOpenBracket 关闭时从 `#define` 行续行缩进），参数跨过的行都算宏头。其他指令（`#if A && \`）的表达式是从 `#` 所在列开始的一条语句，括号内按实际列对齐。
- 宏块分类保留原 token 和源码范围。`MacroBlockBegin/End` 给出一般块边界；当前文件中可识别的对象式 `#define` 若替换为 `namespace name {`、`extern "C" {`、`extern "C++" {`、`{` 或 `}`，按对应结构处理。定义按出现顺序生效，重定义和 `#undef` 更新分类；条件结束时只保留各分支一致的分类，没有 else 的条件还须与进入前一致。文件级 `#ifndef`/`#define`/`#endif` include guard 按透明包装处理。不做通用宏展开。
- 表达式中间的指令（`#if` 等）不参与续行重放。

### 表达式与续行

- lambda 体是嵌套块，不结束所在语句。体缩进一级、`}` 对齐的基准对应 clang-format 的 NestedBlockIndent（`LambdaBodyIndentation: Signature`）：基准属于 lambda 所在的作用域，由在该层开始的续行重置为行首列，行首为条件运算符时取运算符之后的列；嵌套括号从开括号处继承，`if`/`for` 条件从括号后的首个 token 开始。在语句层级换行、带尾置返回类型的 lambda 按独立函数布局，基准为语句缩进。
- 模板参数列表内的括号和嵌套列表是独立作用域，`>>` 同时结束两层。括号内的 `<` 按 clang-format 的启发式判为比较运算符：同层有二元 `&&`/`||`；有条件运算符且 `>` 后不是 `(`/`{`；或 `>` 后紧跟字面量。TemplateNames 中的名字、类头和 `using T =` 之后的 `<` 总是模板实参，`>` 尚未输入时按未闭合列表处理；`T<X{}>` 不打断识别。实参不对齐到 `<` 之后：单个实参从所在行（或外层列表元素）缩进一级，多个实参对齐第一个。
- `f() & -> T` 中 `)` 之后的 `&`/`&&` 是引用限定符；lambda 参数之后的 `->` 是尾置返回类型，在语句层级换行时按语句续行。
- 块注释（`/*Arg=*/`）是普通 token，可作对齐锚点；行注释不参与布局，下一行从前一个代码 token 续接。例外：紧跟初始化列表 `{` 的行注释在 `Cpp11BracedListStyle` 不是 FunctionCall 时是第一个元素，后面的元素与它对齐。
- 不带花括号的控制语句体是独立逻辑行，只有条件部分是控制语句的续行。
- 超过 4096 个 token 的区域不做续行重放。

### 声明与语句边界

以下按 clang-format 的行划分识别：

- 全大写、至少五个字母、独占一行的名字（`ABSL_NAMESPACE_BEGIN`）在下一行能开始语句时自成一条语句。全大写宏调用在行尾结束语句，条件同样是下一行能开始语句（`tokenCanStartNewLine`）。
- 类体之后的声明符（`} specs[] = {...};`）属于同一条声明，续行从声明开头算起。
- 参数列表或返回类型里的 `struct`（`struct tm f(int x) {`、`static inline struct tm f()`、`f(struct addrinfo* ai)`）是类型说明，不是类定义；`static`、`inline`、`typedef` 等说明符不拆开声明。`using namespace X;` 是一条声明。
- `template<…>` 之后独占一行的 requires 子句属于模板参数，子句之后的声明回到模板层级；函数声明符之后独占一行的 requires 子句同样以声明为基准。表达式位置（`=`、`&&`、`||`、`,`、`return`、括号内或另一个 `requires` 之后）的 `requires (…) { … }` 是 requires 表达式，体按 lambda 体布局，不结束所在声明。
- `export {` 打开声明块，按 namespace 体处理。`do` 块体之后回车，新行是它的 `while`，回到 `do` 的层级。case 标签直接打开的块（中间没有独占一行的注释）以标签为基准。

### 注释的归属

- 独占一行的 `//` 注释紧跟以行尾注释结束的行、且所在列比那一行开头（或那一行最后的 `{`）靠右时，延续那段注释并与之对齐（`continuesLineCommentSection`）。`case A: // 说明` 在冒号处结束一行，下面的注释属于标签之后的内容。判断用注释当前所在的列，写在代码列的注释照常缩进。
- 独占一行的注释之后（中间只有注释）是 GNU 或 Whitesmiths 下缩进的独立 `{` 时，注释与该 `{` 同列。

### 逐字输入的局限

回车时看不到下一行，所以 `EXPECT_EQ(a, b)` 之后的新行按新语句缩进；随后在行首输入 `<<`、`?` 等不能开始语句的运算符时，该行改按续行重新缩进，与 CLion 相同。输入末尾的 `?` 视为未写完的条件表达式。后出现的低优先级运算符（`&&` 之后的 `||`）或逗号会让上面的行更深；链式条件中某一环的条件自身换行时，要等下一行的 `?` 才知道它属于链。逐字输入不回头修改已写的行，重新缩进才能得到 clang-format 的布局。

## 3 查询契约

定义在 `src/language.rs`：

```text
IndentRequest { line, position, trigger: Enter | Typed(char) | Reindent }
IndentAdvice  = Set { prefix, auxiliary: Option<Change> }
              | Preserve { newline: Verbatim | Inherit { preserve_suffix } }
              | Unavailable
EnterAdvice   { expand_pair, verbatim, continuation }
```

位置是请求快照的 UTF-8 字节坐标。Enter 和输入的快照是用户输入已应用、缩进尚未应用的临时文本，目标行可以没有 token。查询只读：不读文件、不启动进程、不提交编辑。

| 建议 | 含义与协调器的处理 |
| --- | --- |
| `Set` | `prefix` 是目标行完整的前导空白。`auxiliary` 是同一行内语法要求的局部空白修改，目前只有 AfterHash 下 `#` 之后的间距。两者只能含空格和 tab，`auxiliary` 只能替换前导空白之后、本行之内的空白；否则整个操作以 `InvalidRange` 失败 |
| `Preserve` | 保留原字节，重新缩进和输入触发都不修改。`newline` 决定在此回车得到的新行：`Verbatim` 不加空白（raw string、字符串）；`Inherit` 复制上一行前导空白，`preserve_suffix` 时插在原有空白之前（块注释内部、WhitespaceSensitiveMacros 与 SkipMacroDefinitionBody 下的宏），否则替换它（DisableFormat） |
| `Unavailable` | 没有可靠答案或该触发不适用。Enter 时新行复制上一行前导空白；输入和重新缩进不修改 |

C++ 的 `IndentDecision` 另给出结构列、续行列、目标列、角色、锚点和降级标记，供测试和 `cargo run --example inspect_indent -- <文件> <行号>` 诊断；调用者不根据角色重新实现缩进。建议不带版本标识：分析按源码相等复用（见第 6 节），事务提交时由内核校验基准版本。

闭括号 `)`、`]` 在行首时通常回到开括号所在行。自动配对会让回车落在 `call(a,|)` 这样的位置：括号前还缺操作数，接下来输入的内容在闭括号之前，所以这一行按参数行计算。只有前一个 token 是标识符、字面量或闭合符号时，才算闭括号自成一行。

## 4 空白计划与混排

`materialize(structural, continuation, target, policy)` 生成前导空白：`[0, structural)` 是结构缩进，`[structural, continuation)` 是固定续行，其余到 `target` 是对齐。求解器负责给出单调的列（负偏移先裁到目标列），生成器不访问语法树。

宽度 W 的 tab 从列 c 前进到 `c + W - c % W`。对齐锚点使用原文本的实际列，不把 tab 换成 W 个空格再测量。缩进列是逻辑列，与终端或 GUI 的显示宽度无关。

一个 tab 只在它覆盖的整个区间都允许 tab 时使用，允许的范围由 UseTab 决定，横跨两个都允许的相邻区间不受限制；其余补空格：

| `TabPolicy` | 允许 tab 的区间 |
| --- | --- |
| Never | 无 |
| ForIndentation | 结构缩进 |
| AlignWithSpaces | 结构缩进与固定续行 |
| ForContinuationAndIndentation、Always | 直到目标列 |

例如 ForIndentation、TabWidth 4、结构到第 8 列、目标第 11 列时得到 `"\t\t   "`；结构到第 6 列时得到 `"\t       "`，因为第二个 tab 会越过结构边界。

C++ 的空白策略来自 `CppRules`；其他语言来自选项 `indent-width`、`tab-width`、`expand-tab`，默认 4 个空格。

## 5 编辑操作契约

### Enter

`prepare_enter` 的步骤：

1. 删除选区，向语言取 `EnterAdvice`。`expand_pair` 时插入两个换行，把只隔空白的一对括号拆成三行；`verbatim`（光标在字符串、字符或 raw string 字面量内）时只插入换行，不调整缩进。
2. 在临时快照上以 `Enter` 查询新行；展开括号时再以 `Reindent` 查询闭合行。
3. 新行得到 `Set` 时，拆行后上一行若只剩空白则清空，不留行尾空白。注释续行标记接在新行的缩进之后，取代拆开处后面的空白。
4. 所有修改经统一的修改组合与位置映射转换到基准版本，成为一个事务：换行、空白、括号展开和光标一次撤销。caret 位于新行缩进之后、原后缀之前。不按换行长度平移建议。

注释续行由 `src/language/comment.rs` 计算，C++ 与 Rust 共用，与 CLion 一致：

- 行首的行注释（`//`、`///`、`//!` 连同其后一个空格）在光标位于标记之后时延续到新行；代码之后的行尾注释不延续。
- 块注释在行首开始时，新行在 `/*` 下对齐为 ` * `；以 `*` 开头的行延续 `* `；光标后紧跟 `*/` 时只对齐，不加星号。不以 `*` 开头的行不加前缀。
- 只读取光标所在行和注释开头的切片，不物化全文。

### 输入、重新缩进与其他来源

| 操作 | 自动缩进与提交 |
| --- | --- |
| 输入字符 | 先插入字符；语言的 `triggers(ch)` 为真时查询当前行，空白调整与字符同一事务、一次撤销 |
| 重新缩进 | `Set` 修改前导空白和辅助空白；`Preserve`、`Unavailable` 不修改 |
| 粘贴 | 按原字节插入，不缩进 |
| Tab（`indent-for-tab`） | 同 Emacs 的 `indent-for-tab-command`：按 `Reindent` 查询光标所在行并修改前导空白，光标在前导空白中时移到第一个非空字符，在正文中时随正文移动；有选区时逐行重新缩进（`indent-region`），每行在前面各行改好后的文本上查询，所以续行跟着开头行的新位置对齐，整体一次撤销。所有行都得到 `Unavailable`（语言没有缩进分析）时退回 `insert-tab` |
| `insert-tab` | 有选区时缩进选定行；否则按 tab 策略插入 tab，或插入补到下一 tab stop 的空格 |
| 字面 tab | 插入 `\t` |
| 缩进增减 | `IndentSelection` 按缩进宽度修改选定行，不等同于插入 tab |
| Beacon 多选区 | 按原文插入，回车不缩进 |

C++ 的输入触发：行首的 `{`（独占一行的花括号）、`}`、`#`；形成访问标签、case 标签、goto 标签或构造函数初始化列表的 `:`，行首的 `:`，以及把行首名字变回限定名的第二个冒号（`std:` 被当成标签移开，打出 `std::` 时移回）；行首的续行运算符（二元运算符、`.`、`->`、`?`，以及行首为 `:` 的行里的 `?`）；行首打完的 `requires`；`#` 之后打完的指令关键字（`else`、`endif`、`elif` 等），使输入 `#` 时的临时层级随关键字收敛。DisableFormat 下不触发。Rust 的触发见第 7 节。

自动生成的空白不再作为输入触发，一次操作只做一轮调整。按键绑定不进入求解器。

### 试算与失败

输入和 Enter 在克隆的语言会话上试算，事务提交后才替换文档的会话；失败的输入不改变文档分析。建议越界或版本冲突时整个操作原子失败，调用方基于最新状态重新执行。

## 6 缓存与验证

### 分析复用与增量修复

C++ 会话保留上一份分析，源码相等时直接复用；`ParserOptions` 变化清除它，缩进宽度等其他策略变化保留结构。撤销、重做和重新加载走同一规则。源码变化时以旧分析为基线修复（`parser::reparse`），按以下顺序尝试，结果记在 `ParseStrategy`：

1. 重新词法：从修改前的独立换行 token 之后开始，在未改变的后缀中遇到对应换行 token 时收敛。字符串、块注释和反斜杠续行内部不是恢复点；未闭合 token 可让扫描延伸到文件末尾。
2. `TokenEquivalent`：新旧 token 种类相同，标识符和预处理 token 的拼写也相同时，复用全部节点和宏分类。
3. `Container`：从首个不同 token 及前一个有效 token 的归属节点向外，寻找完整的 namespace、class/enum、函数、代码块或 case section。前一个有效 token 决定行尾空白的逻辑归属，例如在 case 最后一条语句后插入新行。修复恢复祖先栈和 enum 上下文，保留未修改的前缀项，重放编辑位置及其前一项（前一项可能受新插入的 else、case 内语句或 class 分号影响），再在可靠的旧项边界复用后缀。项之间以分号、闭括号或 enum 的逗号为边界。brace 容器的开闭括号必须不变；case section 保留完整标签，从冒号后重解析，在下一标签、闭块或 EOF 处校验边界，新增标签改变兄弟归属时扩大到外层 switch。区域可以位于条件分支、预处理重新打开的作用域或未闭合的外层作用域中，但新旧 token 范围都不能含预处理指令；修复不读写条件帧，窗口外的分支、缺失 token 和恢复信息原样保留。启发式重分类的括号组和自身不完整的区域改选更外层的上下文。
4. `Declarations`：顶层声明像容器一样续接，条件是新旧文件都没有条件编译指令（`#if`、`#ifdef`、`#else`、`#endif` 等），且新旧扫描窗口都不含预处理指令，所以 `#include`、`#define` 不迫使顶层编辑完整解析。续接只发生在以分号或闭括号结束的项之后，其他位置的未完成项不阻止它；新解析出的项不完整时修复失败。
5. `Full`：以上都失败时完整解析，`AnalysisFallback` 记录原因（`PreprocessorContext`、`IncompleteStructure`、`ChangedBoundary`）。

修复后的节点和 token 索引重新映射，跨越修复区间的祖先范围和后续兄弟引用一并更新；索引不跨分析保持稳定。release 构建中修复 panic 时退回完整解析，debug 构建让 panic 暴露给差分测试。

源码物化、前后缀比较、数组复制和归属索引重建仍是线性成本。在 1 MB、24.8 万 token 的 `SemaOpenMP.cpp` 上，函数体内一次局部修复中位数约 3 ms，其中解析约 10 µs，其余为 relex 复制 token 数组（约 1 ms）、宏分类（约 0.5 ms）、节点重映射（约 0.5 ms）和归属索引重建（约 0.5 ms）。`CppSession::analysis_work` 报告策略、扫描字节、重解析 token 数（含失败尝试）、复用节点数和回退原因；冷启动的完整分析不算回退。`cargo run --release --example cpp_analysis_trace -- FILE TARGET [SAMPLES]` 对标识符 TARGET 做连续不同替换，比较冷启动与增量耗时；不写文件，计时包含源码物化和一次第零行缩进查询。

### 测试

| 命令或文件 | 覆盖 |
| --- | --- |
| `cargo test incremental --lib` | 完整与增量分析的 token、节点、宏分类、归属索引和逐行缩进建议一致 |
| `SODA_TYPING_CORPUS=<dir> cargo test --release -- --ignored typing_corpus` | 从真实源码中段逐字符输入 4000 字节，每步与完整解析比较 |
| `tests/clang_format_editor.rs` | LLVM `FormatTest.cpp` 中与行首缩进有关的例子，改为 editor 命令测试 |
| `tests/typing.rs` | 开着自动配对逐键输入，与 clang-format 结果比较；覆盖重新缩进测不到的中间状态。用例由 `scripts/generate_typing_cases.py` 生成 |
| `tests/comment_enter.rs` | 注释续行 |
| `tests/indentation.rs` | Rust 和只按括号缩进的语言 |
| `cargo run --release --example indent_accuracy -- [--show N] <文件或目录>` | 对按 `.clang-format` 格式化的源码逐行重新缩进，报告与实际缩进一致、不一致和保留的比例；语料应只含 clang-format 输出无变化的文件 |

`tests/clang_format_editor.rs` 的每个例子记录上游测试名、配置覆盖和带 caret 标记的预期文本（文件头记录上游 revision）；预期取自上游排版，不在运行时调用 clang-format，也不由求解器生成。Enter 路径删除标记行前的换行和缩进再用 `Command::Enter` 恢复，Reindent 路径把缩进换成混合空白再用 `Command::Reindent` 修复；都检查文本、caret、撤销和重做，并分别跑 LF 与 CRLF。新增例子须显式选择换行边界并记录配置，自动折行、重排和行尾对齐不能作为预期。

## 7 Rust 与其他语言

### Rust

`src/rust/` 按 rustfmt 的块式风格缩进，从不做视觉对齐，所以一行的位置只由所在组的开括号行和所属单元的起点决定。高亮仍由 TextMate 语法负责。

| 情形 | 位置 |
| --- | --- |
| 组（括号、泛型实参列表、闭包参数）内 | 开括号所在行缩进一级 |
| 行首的闭括号 | 回到开括号所在行 |
| 续行 | 所属单元（语句、项、列表元素或 match 分支）起点所在行缩进一级；块之后的 `else` 开始新单元，`} else if` 的条件从这一行续行 |
| 链式调用 `.`、`?` 与闭括号 | 与上面一行的链接对齐 |
| 二元运算符 | 与上面一行的运算符对齐 |
| 以 `=` 或 `where` 结尾的行之后 | 缩进一级 |
| 独占一行的 `where` | 单元起点所在行 |
| 独占一行的 `{`、`else` | 所属关键字（`if`、`fn`、`impl`、`match` 等）所在行；在 match 分支里回到分支所在行 |
| match 守卫 `if` | 分支起点缩进一级 |
| 模式中的 `\|` | 与分支起点对齐 |
| 多行字符串内部 | `Preserve`，回车不加空白；块注释内部回车复制上一行空白 |

输入触发：行首第一个 token 由刚输入的字符开始或完成时才移动该行，即 `}`、`)`、`]`、`{`、`.`、`?`、打完的 `else`/`where`、`&&`、`||`、`|`、`>`/`=>`/`->`。Enter 的括号展开、字符串内回车和注释续行与 C++ 相同。

分析是每次文本变化后整份重新词法（约 15 ms/MB），文本不变时复用。实测与 rustfmt 输出的差异：

| 语料 | 重新缩进 | 模拟 Enter |
| --- | --- | --- |
| soda 的 `src` | 52,158 行中 22 行 | 4,396 行中 0 行 |
| rustfmt 的 `src` | 33,812 行中 74 行 | 2,166 行中 3 行 |

剩余差异来自运算符优先级嵌套、rustfmt 的视觉对齐（多行闭包参数、`#[rustfmt::skip]` 代码）以及 `macro_rules` 的 `$(…)` 体。`CORPUS=<目录>[:<目录>…] cargo test --release --lib rust::indent::corpus -- --ignored` 复现这些数字：`corpus` 逐行重新缩进，`corpus_enter` 把每行当作光标所在的空行（只计首个 token 不会移动该行的行）。

### 其他语言

没有解析器的语言只按括号缩进（`src/editor/language.rs` 的 `bracket_indent`）：Enter 后上一行以开括号结尾时缩进一级；括号展开后的闭括号回到开括号行的缩进；其他情况 `Unavailable`，新行沿用上一行空白。没有输入触发。
