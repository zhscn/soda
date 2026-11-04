# Emacs 为什么特殊

> 基于 GNU Emacs 源码（commit `7c188d9bf23`，2026-09-15）整理，文中行号均对应该版本。另参考了 Juicemacs 作者 Kyo 的几篇文章：[Why Rewriting Emacs Is Hard](https://kyo.iroiro.party/en/posts/why-rewriting-emacs-is-hard/)、[Extensibility: The "100% Lisp" Fallacy](https://kyo.iroiro.party/en/posts/100-percent-lisp/)、[This year, I will write a shitty GUI for my Emacs clone](https://kyo.iroiro.party/en/posts/this-year-a-shitty-gui/)；以及 matklad 的 [An Engine For An Editor](https://matklad.github.io/2023/03/08/an-engine-for-an-editor.html)。

## 起因

写编辑器的人迟早会问一个问题：Emacs 为什么这么特殊？

最常见的答案是"因为 elisp"。可这个答案经不起推敲。Common Lisp 在每个维度上都比 elisp 强，用 CL 写的 lem 理应只会更可扩展。但 lem 的设计其实相当朴素，写扩展时并不能像想象中那样"直接用上 CL 的全部能力"。Kyo 把这种说法称为"100% Lisp 谬误"：

> Writing a Lisp-extended editor in Lisp won't immediately make your editor more extensible.

soda 这个编辑器项目也走过同样的弯路。最初的设想是用 Chez Scheme 实现，指望靠 Chez 的运行时重定义拿到 Emacs 式的扩展能力。结果光是复刻 minibuffer，就卡在一个怎么也处理不干净的焦点问题上。后来改用 Rust，把"Emacs"定义为"实际用到的那些操作的可观察行为"，只复刻语义，不复刻机制。这反而是最成功的一次。

这说明 Emacs 的特殊性多半不在语言。

## 两种可扩展性

谈 Emacs 的可扩展性时，其实混着两件事：

1. **修改编辑器**：用 advice、hook、变量，让编辑器按自己的方式工作。
2. **在编辑器上构建应用**：magit、dired、customize、comint、org，这些本身就是完整的应用，却是用编辑器的原语搭出来的。

matklad 在 *An Engine For An Editor* 里讨论的是第二种。他借用游戏引擎和游戏的类比：很多人在写编辑器，但很少有人在写**编辑器引擎**，也就是编辑器各个组件共同依赖的那一层"细腰"（thin waist）。他把几种候选的细腰排了个序：

- **纯文本**：Unix 管道，最可组合，但表达力最弱；
- **ANSI 转义序列**：纯文本加颜色和光标控制，vim 就建在这上面；
- **Emacs**：frame、window、buffer，加上**带属性的文本**；
- **HTML / canvas**：表达力最强，但没有结构上的约束。

Emacs 的位置在 ANSI 和 HTML 之间：比 canvas 和 HTML 弱，但比 ANSI "更通用，也有原则得多"，而且保住了纯文本的可组合性。matklad 的例子是：Emacs 里文件管理器的状态就是文本，所以批量重命名用的是普通的文本编辑工具，而 GUI 文件管理器需要一个专门的批量重命名程序。

别的编辑器在第一种可扩展性上未必差多少，Emacs 真正独一无二的是第二种。第一种主要靠运行时，第二种几乎完全来自细腰。

本文回到 Emacs 的源码，把这两种可扩展性合在一起，拆成三个来源来看：

1. **架构**决定扩展点放在哪里；
2. **运行时**让扩展点变得廉价；
3. **几十年积累的数据模型**决定扩展点有多少、多细。

## 先看比例

| | C（`src/`） | Emacs Lisp（`lisp/`） |
| --- | --- | --- |
| 代码量 | 约 52 万行 | 约 200 万行（直接计数，含生成文件） |
| 函数 | 1840 个 primitive（`DEFUN`） | 4.6 万多个 `defun` |
| 交互命令 | 118 个 | 一万两千多处 `(interactive ...)` |
| 暴露给 Lisp 的变量 | 972 个 `DEFVAR_*` | — |

C 核心不小，单是显示引擎 `xdisp.c` 就近 4 万行。但用户能直接调用的命令几乎全在 Lisp 里。

光看比例说明不了什么，Kyo 也指出 lem 同样"大约 90% 是 Lisp"。更关键的问题是：**C 核心在每个做决定的地方，是不是把决定权交给了 Lisp；它的内部状态，是不是 Lisp 能直接读写的**。

---

# 第一部分：架构决定扩展点在哪里

这一部分的六节合起来，就是 matklad 说的 Emacs 的细腰：只有 buffer 一种东西，焦点就是当前窗口，命令循环可以重入，按键查找是分层的数据，C 的状态和决策点对 Lisp 开放。

## 1. 命令循环：C 写的循环，Lisp 做的决定

命令循环在 `keyboard.c` 的 `command_loop_1`（1318 行）。它每一轮做的事情大致是：

1. `read_key_sequence` 读一个按键序列，按当前生效的 keymap 解析成命令；
2. 经过 command remapping，把结果写进 `this-command`（1506 行）；
3. 运行 `pre-command-hook`；
4. **通过符号**调用 `command-execute`：`calln (Qcommand_execute, Vthis_command)`；
5. 运行 `post-command-hook`、处理 undo boundary、重显示。

第 4 步是关键。`command-execute` 不是 C 函数，它定义在 `simple.el`（2794 行），开头还有一句注释："BEWARE: Called directly from the C code."。循环虽然是 C 写的，但"执行一个命令意味着什么"这件事是由 Lisp 定义的，而且是通过符号间接调用的，所以它可以被重定义、被 advice。连 undo boundary 也是通过符号调用 `undo-auto--add-boundary` 来处理的。

`this-command` 也是一个普通的 Lisp 变量。在 `pre-command-hook` 里改写它，就能把用户刚按下的命令换成另一个。

## 2. 按键：分层查找、按命令重绑定、可编程的解码

keymap 就是一个以符号 `keymap` 开头的 list（`keymap.c` 106–125 行）。它没有专门的对象类型，就是普通的 Lisp 数据，可以构造、拼接、遍历，也可以作为 `parent` 继承。

**分层查找。** `current-active-maps`（`keymap.c` 1649 行）会依次收集当前生效的各层 keymap。按 Emacs 手册的描述，优先级从高到低大致是：

1. `overriding-terminal-local-map`
2. `overriding-local-map`
3. 光标处文本的 `keymap` 属性
4. `emulation-mode-map-alists`（evil、meow 这类模态插件就挂在这里）
5. `minor-mode-overriding-map-alist`
6. `minor-mode-map-alist`
7. 光标处文本的 `local-map` 属性，否则用 buffer 的 local map
8. global map

每一层都是一个 Lisp 变量或一个文本属性。模态编辑之所以能作为插件存在，靠的不是 elisp 有多强，而是 C 核心在查找按键时，预先留好了一层"模拟模式"的位置。文本属性能携带 keymap 也一样：一个按钮、一段链接、一块 diff hunk，各自有自己的按键，不需要任何专门的机制。

**按命令重绑定。** keymap 里可以写 `[remap kill-line]`，意思是"无论哪个键绑定了 `kill-line`，在这个 keymap 生效时都改成执行另一个命令"（`keymap.c` 1848、2719 行）。major mode 和 minor mode 因此可以替换"语义上的操作"，而不必猜用户把它绑在哪个键上。

**可编程的解码。** `read_key_sequence` 在查 keymap 之前，先经过 `input-decode-map`、`local-function-key-map`、`key-translation-map` 三层翻译（`keyboard.c` 11031–11032 行起）。终端发来的转义序列怎么解码成按键，是用户可以改的 Lisp 数据，新终端、新协议不必等编辑器支持；`C-x 8` 输入特殊字符也是靠 `key-translation-map` 实现的。另有 `unread-command-events`（13776 行）可以让程序往输入队列里塞事件，键盘宏的回放用的是同一套机制。

## 3. minibuffer：没有第二种东西

这正是 Chez 版本卡住的地方，值得逐步拆开看。`read_minibuf`（`minibuf.c`）做的事情是：

1. 把 minibuffer 这个**普通 buffer** 放进 minibuffer 窗口：`set_window_buffer (minibuf_window, ...)`（839 行）；
2. `Fselect_window (minibuf_window, Qnil)`（840 行），**焦点就是 selected window**；
3. 把 prompt 当成普通文本插进 buffer，再给它加上 `field`、`front-sticky`、`rear-nonsticky` 文本属性（858–866 行）。这样光标移动和删除都不会越过 prompt 的边界，这件事也是由通用的 field 机制完成的；
4. 运行 `minibuffer-setup-hook`（912 行）；
5. 调用 `recursive_edit_1 ()`（917 行），**嵌套跑一层完全一样的命令循环**。

所以在 minibuffer 里可以用全部编辑命令，可以 isearch，可以 yank，可以再嵌套打开一个 minibuffer。这些都没人专门实现过，因为 minibuffer 本来就是 buffer，输入时跑的本来就是命令循环。

Chez 版本的焦点问题，根源在于 prompt 和 buffer 是两种东西：两套输入路径、两套焦点状态，需要互相同步。Emacs 根本不存在这个问题，因为它只有一种东西。

但这个解法没法只拿走 minibuffer。它依赖三个前提：window 和 buffer 是统一的；命令循环可以重入；文本属性系统足够通用，能用 field 表达"prompt 不可编辑"。三者缺一不可，**minibuffer 是整个架构的产物**，不是一个功能。

## 4. C 的状态就是 Lisp 变量

C 代码里有 972 个 `DEFVAR_*`。它们不是"提供给 Lisp 的 getter/setter"，而是**转发**（forwarding）：Lisp 变量直接指向 C 的全局变量或 buffer 结构体的字段。

- `DEFVAR_LISP`/`DEFVAR_BOOL`/`DEFVAR_INT` 把 C 全局变量变成 Lisp 变量（分别有 618、198、74 个）。
- `DEFVAR_PER_BUFFER`（`buffer.c` 5016 行，共 65 个）把 `struct buffer` 的字段变成 buffer-local 的 Lisp 变量，例如 `major-mode`、`tab-width`、`fill-column`、`buffer-display-table`。`data.c` 在读写变量时识别 `Lisp_Fwd_Buffer_Obj`（1350、1518 行），转去读写当前 buffer 的对应字段。

再加上 elisp 的动态绑定（见第二部分），一行 `let` 就能临时改变 C 代码的行为。**C 和 Lisp 之间的边界，对状态来说几乎是透明的**，每一个被转发的变量都是一个扩展点。

## 5. 显示也接受 Lisp

可扩展性一直延伸到重显示里。Kyo 把文本属性形容为"CSS for text"，而且部分是图灵完备的。代码里可以看到几个 C 在重显示过程中同步调用 Lisp 的地方：

- **display 属性的 `(when FORM . SPEC)`**：`xdisp.c` 的 `handle_single_display_spec`（6134 行）会在重显示时求值 FORM，决定这个显示规格是否生效。
- **字形组合**：`composite.c` 查 `composition-function-table`，命中后通过 `safe_calln (Vauto_composition_function, ...)`（979 行）调用 Lisp 来决定如何组合字形。连字体连字都可以在 Lisp 里编程。
- **按需高亮**：`xdisp.c` 在需要显示还没高亮的文本时调用 `fontification-functions`（4663–4741 行），jit-lock 就建在这上面。
- **滚动**：`window-scroll-functions`（19271 行）。
- **mode line**：`(:eval FORM)` 在重显示过程中执行任意 Lisp。

`xdisp.c` 里通过 `safe_call` 系列调用 Lisp 的地方有二十多处。这是可扩展性最深的一层，代价在后文讨论。

## 6. 在子系统入口分派

这一类设计最不起眼，影响却最大：在某个子系统的入口放一张分派表，整个子系统就都可以被重定向，而且对下游代码透明。

**文件名处理器。** 主流编辑器的文件操作直接调用操作系统；远程文件、压缩文件要么不支持，要么是某个插件自己实现的一套 VFS，其他插件得主动适配。Emacs 的 `fileio.c` 里，文件操作原语在执行前都会先调用 `find_file_name_handler`（全文件 44 处），按文件名匹配 `file-name-handler-alist` 里的正则。匹配上了，就把**整个操作**交给对应的 Lisp 函数处理。`dired.c`、`process.c` 里也有同样的分派。于是：

- TRAMP（`tramp.el`）：`/ssh:host:/path` 形式的文件名会被交给 TRAMP，打开、保存、列目录、甚至启动进程都在远程执行；
- `jka-compr.el`：透明地打开和保存 `.gz` 文件；
- `epa-file.el`：透明地打开和保存 `.gpg` 文件。

dired、find-file、compile、grep 这些包都不需要知道远程文件的存在，原样就能处理远程文件。这是 Emacs 里"为某个需求做的一次决定，造福所有后来者"最好的例子。

**输出目标。** `print`、`princ` 的输出目标 `standard-output` 可以是 buffer、marker、函数，或者 `t`（回显区）（`print.c` 147、153、195 行）。所有用 `print` 系列函数产生输出的代码，都可以被调用方重定向。

**子进程输出。** 子进程的输出交给一个 Lisp 函数处理（`set-process-filter`，`process.c` 1397 行）；默认行为是插入 buffer 中 `process-mark`（1364 行）所在的位置，这个位置是一个普通的 marker。comint（shell、各种 REPL 的基础）和 compilation 因此完全在 Lisp 层实现。

**窗口放置。** 主流编辑器里，哪个面板显示在哪里由每个功能自己决定。Emacs 中几乎所有"把某个 buffer 显示出来"的操作都经过 `display-buffer`（`window.el` 8183 行），它按 `display-buffer-alist`（8079 行）里的规则决定在哪个窗口、以什么方式显示。用户可以统一规定"帮助总在右侧""编译输出总在底部且不抢焦点"，包的作者也不需要关心窗口布局。

---

# 第二部分：运行时让扩展点变得廉价

## 经由符号的间接调用和即时重定义

Lisp 调用函数时，先找到符号，再取它的函数槽。advice 正是建在这个基础上：`nadvice.el` 用 `advice--defalias-fset`（477 行）替换符号的函数槽，此后所有经由这个符号的调用都会经过 advice。Kyo 在用 Truffle 实现 elisp 解释器时特别处理了这一点：重定义一个函数，用户期望它**立刻**对所有调用者生效，连 `+` 都可以被 advice。

elisp 的动态性比这还彻底：宏在运行时展开，`(something a b)` 在运行前分不清是函数调用还是宏；连特殊形式都能起别名，`(defalias 'my-if #'if)` 之后 `my-if` 也是特殊形式。

## 动态绑定和 buffer-local 变量

`eval.c` 的 specpdl 栈专门区分 `SPECPDL_LET_LOCAL` 和 `SPECPDL_LET_DEFAULT`（753、772 行），`let` 一个变量时能正确处理 buffer-local 值和默认值，退出时恢复。配合第一部分第 4 节的变量转发，它能穿透 C。`search.c` 在搜索时直接读 `Vcase_fold_search`（287、408、1074 行），所以

```elisp
(let ((case-fold-search nil))
  (re-search-forward ...))
```

能改变 C 搜索代码的行为，而且只在这段动态范围内生效。调用方不需要传参数，被调用的 C 代码也不需要提供 API。

## 运行时的作用

这两样东西的作用，是让第一部分里的每个扩展点都变得廉价：加一个扩展点，只需要读一个变量，或者通过符号调用一个函数，不需要设计 API。这是 Emacs 能积累出成千上万个扩展点的前提。

## 边界：Emacs 自己也越不过 C

Emacs Lisp 手册（`functions.texi` 2194–2200 行）写得很直白：

> It is possible to advise a primitive, but one should typically *not* do so... many primitives are called directly from C, and such calls ignore advice.

C 代码调用 `Fgoto_char` 是直接的函数调用，不经过符号，advice 对它无效。**Emacs 的可扩展性同样止步于 C 边界。** 它和"Rust 核心加脚本语言"的组合面对的是同一道墙。区别在于墙的位置和透明度：Emacs 的 C 层在决策点上主动回调 Lisp，状态通过转发对 Lisp 透明。

Kyo 还指出，这道墙也有好处：正是因为 C 和 Lisp 之间隔离清楚，Juicemacs 这样的重新实现才可行。

---

# 第三部分：积累出来的数据模型

Kyo 举过一个例子：Emacs 的大小写转换不是一个写死的函数，而是一张**可修改的 case table**（`casetab.c`）。于是 `erc.el` 可以按 IRC 协议（RFC 1459）造一张表，让 `[]\` 和 `{}|` 互为大小写，再用 `with-case-table` 在一段代码里临时换上它。

这个例子的结构很典型：

- 主流做法：某个行为写死在实现里（大小写按 Unicode 转换）；
- Emacs 的做法：把它做成一份可替换的数据，按 buffer 设置，可以动态绑定；
- 换来的能力：某个具体需求（IRC 昵称比较）不需要改核心就能满足。

这样的设计在 Emacs 里到处都是。每一项都是某个时候为某个具体需求做的决定，几十年积累下来，就成了扩展代码可以直接操作的数据模型。扩展代码用的就是核心自己用的数据结构，没有"给插件用的简化版"。下面按类别列举。

## 字符

Emacs 有一种通用数据结构叫 char-table（`chartab.c`）：按字符索引，支持父表继承和按区间赋值。很多在别的编辑器里写死的字符属性，在 Emacs 里都是一张 char-table。

- **字符范围**：`character.h` 里 `MAX_CHAR = 0x3FFFFF`（49 行），远超 Unicode 的 `0x10FFFF`。`0x3FFF80` 以上表示原始字节，所以解码错的文件保存时能原样写回；中间一段留给尚未与 Unicode 统一的字符。
- **显示宽度**：主流做法是调用 `wcwidth` 或 Unicode 宽度库，结果写死。Emacs 的 `char-width-table` 是一个 Lisp 变量（`character.c` 1115 行），默认值在 1118–1119 行初始化。东亚歧义宽度字符（例如 `○`、`→`）、emoji 的宽度在不同字体和终端里不一致，用户可以按自己的字体改表，不用等编辑器发版本。
- **词边界**：主流做法按 Unicode UAX #29 或"字母数字下划线"判断。Emacs 的每个字符可以属于多个 category（`category.c`）。`forward-word` 在 `syntax.c`（1515、1566 行）除了看 syntax，还会调用 `word_boundary_p`（`category.c` 377 行），后者查 `word-combining-categories` 和 `word-separating-categories` 两个变量（442、487 行）。于是日文中汉字与平假名之间、不同文字系统之间是否算词边界，可以由语言环境决定。`kinsoku.el` 用 category `?>`、`?<` 标记"不能出现在行首/行尾"的字符，`fill.el` 在折行时据此做日文禁则处理（`enable-kinsoku`，74 行）。
- **编码转换**：可以用 CCL 这门字节码语言来写（`ccl.c` 约 2400 行），任何编码都能在 Lisp 层定义。

## 语法和正则

- **syntax table 加上按位置覆盖**：主流做法是每种语言一个 tokenizer，或者一个 tree-sitter 语法。Emacs 的 syntax table 给每个字符一个语法类别（词、符号、括号、字符串定界符、注释起止……），一个通用引擎（`syntax.c`）据此实现 `forward-sexp`、括号匹配、`parse-partial-sexp`，对所有语言通用。关键在于：开启 `parse-sexp-lookup-properties` 后，引擎会查文本的 `syntax-table` 属性（`syntax.c` 390 行），**某个具体位置的字符可以拥有和表里不同的语法**；`syntax-propertize-function`（`syntax.el` 48 行）负责按需计算这些属性。Perl/Ruby 的正则字面量、shell 的 heredoc、C++ 模板参数里的 `<>`，都可以只在那几个位置覆盖语法，然后通用的 sexp 移动、括号匹配、注释识别就都能正确工作。一个 major mode 只需要提供"哪里特殊"，不需要重写整个解析器。
- **正则不是通用的字符串库，而是 buffer 原语**：`regex-emacs.c` 有一个 `at_dot` 操作码（326 行），对应 `\=`，匹配光标所在的位置；`\w`、`\b` 查当前 buffer 的 syntax table；`[:lower:]` 和 `case-fold-search` 查 case table。

## 文本区间带着行为

主流编辑器的文本装饰（decoration、extmark、inlay）基本只影响显示。Emacs 的文本属性用区间树存储（`intervals.h` 的 `struct interval`），挂在字符串和 buffer 上，`insert`、`buffer-substring` 时随文本一起移动。它和 overlay 都可以携带**行为**：

- `read-only` 属性：`textprop.c` 的修改检查（2244–2275 行）会拒绝修改带这个属性的文本，还处理了前后粘性。
- `field` 属性：minibuffer 的 prompt 就是一个 field，移动命令按 field 约束光标。
- `modification-hooks`、`insert-in-front-hooks`、`insert-behind-hooks`：文本属性（`textprop.c` 2314、2345 行）和 overlay（`buffer.c` 4189、4204 行）上都可以挂函数，**这段文本**被修改时调用。
- `cursor-sensor-functions`（`cursor-sensor.el`）：光标进入或离开某段文本时调用。

这些属性组合起来，可以在普通 buffer 里做出"表单"。`customize` 的界面就是一个 buffer，里面的可编辑字段、按钮、只读说明文字，全靠这些属性组合出来（`widget.el`）。comint 和 eshell 的提示符是只读的 field，历史输出不可误改。别的编辑器要做同样的东西，通常需要一个独立的 UI 组件。

换句话说，这些属性的作用不只是"让编辑器可以定制"，而是**构成了一套 UI 语言**，第二种可扩展性的应用就是用它写出来的。而且用这套语言写出来的界面，仍然是文本，所以仍然能用所有文本工具操作。wdired 是最好的例子：把 dired 的目录列表切换成可编辑状态，用查找替换、矩形编辑、键盘宏去改文件名，提交时再把改动写回文件系统。批量重命名不需要专门的功能，它只是"编辑文本"的一个特例。matklad 说 "Text is surprisingly good at communicating with humans!"，magit 也是同样的道理。

还有两个属性：

- **可见性**：主流做法是把折叠做成一个独立的数据结构（fold range 列表）。Emacs 的折叠就是给文本加 `invisible` 属性（`xdisp.c` 1019 行注册了它的处理函数），属性值可以是任意符号；buffer-local 的 `buffer-invisibility-spec`（`buffer.c` 5837 行）决定哪些符号当前生效，以及隐藏处要不要显示省略号。多个包的隐藏因此可以共存，各自用自己的符号开关。outline、org、hideshow 的折叠都是这样做的，隐藏的文本仍然在 buffer 里，搜索、编辑照常进行。
- **粘贴行为跟着文本走**：被复制的字符串可以带一个 `yank-handler` 文本属性，指定粘贴时调用的函数（`subr.el` 4872 行起）。在 `rectangle-mark-mode` 下复制的矩形，存进 kill ring 的就是一个带 `yank-handler` 的字符串（`rect.el` 826 行），粘贴时自动按矩形插入。kill ring 和 `yank` 都不需要知道"矩形"这个概念。

## 命令元数据和输入流水线

- **符号属性做命令元数据**：主流编辑器里，命令的属性（是否可重复、是否影响选区）在注册命令时一次性给出，由命令的作者决定。Emacs 的命令就是符号，符号有属性表（plist），**任何人**都能往上面放东西：
  - `delete-selection-mode` 在 `pre-command-hook` 里检查即将执行的命令有没有 `delete-selection` 属性（`delsel.el`），有就先删掉选区；
  - isearch 检查 `isearch-scroll` 属性（`isearch.el` 1555 行），决定某个命令能不能在搜索过程中执行而不退出搜索；
  - `command-execute` 检查 `disabled` 属性（`simple.el` 2821 行），给新手禁用某些命令；
  - file-local 变量的安全性由变量的 `safe-local-variable` 属性决定（`files.el`），属性值是一个判断值是否安全的谓词。

  包 A 可以给包 B 的命令或变量打标记，不需要 B 的配合，也不需要 B 知道 A 的存在。
- **输入一个字符也是一条带钩子的流水线**：主流编辑器里，输入字符是编辑器内部的特殊路径。Emacs 的 `self-insert-command` 是一个普通命令，它的实现（`cmds.c`）在插入前后依次经过：缩写展开 `expand-abbrev`（424 行），自动折行 `internal-auto-fill`（490 行），最后运行 `post-self-insert-hook`（499 行）。自动配对括号（`electric-pair-mode`）、输入时自动缩进（`electric-indent-mode`）都只是往这个 hook 里加一个函数。

## 历史就是数据

主流编辑器的 undo 历史是不透明的内部结构，最多提供 undo/redo 两个操作。Emacs 的 `buffer-undo-list` 是一个普通的 Lisp list，元素是文本插入、删除、属性变化、marker 位置调整（`undo.c` 127 行的 `record_marker_adjustments`）等记录，还有一种 `(apply FUN . ARGS)` 记录（`simple.el` 3710 行），undo 时调用任意函数。于是：

- undo-tree、vundo 这类可视化的树状 undo 完全在 Lisp 层实现，不需要核心支持；
- 包可以往 undo 历史里放自己的记录，让非文本的状态变化也能被 undo；
- `undo-in-region` 只撤销某个区域内的修改，也是在这份数据上算出来的。

## 同一份文本，多种视角

- **每个窗口有自己的 point**（`window-point`，`window.c` 1787 行）：同一个 buffer 在两个窗口里显示，光标位置各自独立。
- **narrowing**（`narrow-to-region`，`editfns.c` 2948 行）：把 buffer 限定在一个区间内，**所有**原语，包括搜索、移动、`point-min`/`point-max`，都只看得见这个区间。org 的 `org-narrow-to-subtree` 让所有命令只作用于当前子树，命令本身不需要知道 org 的结构。
- **indirect buffer**（`make-indirect-buffer`，`buffer.c` 807 行）：和基础 buffer 共享文本和文本属性，但有自己的 major mode、narrowing、overlay 和 marker。可以用它把 Markdown 里的一段代码块用对应语言的 mode 来编辑，文本仍然是同一份。

---

# 归纳

## 反复出现的五种手法

把上面这些放在一起，可以归纳出几种反复出现的手法：

1. **表代替函数。** case table、char-width-table、category table、syntax table、keymap、`display-buffer-alist`、`file-name-handler-alist`，行为被参数化成一份可修改的数据。用户改的是数据而不是代码，而且这些数据大多可以按 buffer 设置、可以动态绑定。
2. **行为附着在文本位置上。** keymap、syntax、只读、field、修改钩子、可见性、粘贴方式，都可以挂在一段文本上。行为局部化到它所描述的文本，复制时还会跟着文本走。
3. **符号是开放的元数据载体。** 任何包都能给任何命令、变量打标记（`delete-selection`、`isearch-scroll`、`safe-local-variable`），元数据的作者和对象的作者解耦。
4. **在子系统入口放分派点。** 文件操作、打印输出、进程输出、窗口放置，入口处的一次分派让整个子系统都能被重定向，而且对下游代码透明。
5. **状态和历史是普通数据。** C 的状态通过转发成为 Lisp 变量；undo list、kill ring、keymap 都是 Lisp 能直接读写的 list，于是可以在上面构建核心作者没想到的功能。

这五种手法都不依赖 elisp 的语言能力。它们是数据结构和接口的设计决定，任何语言都能做。Emacs 的特殊之处在于，几十年里它在几乎每一个子系统上都做了这种决定。

## 代价

Kyo 有一句很精确的话："in (GNU) Emacs, everything influences everything"。可扩展性的代价至少有四种：

- **性能和并发**：任何 Lisp 变量都可能被动态绑定，任何函数都可能被重定义，重显示里会跑任意 Lisp。这让 Emacs 很难优化（JIT 需要处处设下"假设失效"的检查），也很难并行。重显示必须在主线程上同步跑 Lisp，就没法把渲染交给另一个线程或进程。Kyo 在给 Juicemacs 写 GUI 时，明确决定**不支持**在重显示中同步执行 Lisp，也不支持 `composition-function-table`，只打算支持异步计算的文本属性和 mode line。
- **查表的开销**：每张表都是一次查找。正则引擎匹配时要查 syntax table、case table 和 category table。
- **重写的难度**：第三部分的数据模型全都是 API，已经有大量 Lisp 代码在依赖。复刻 Emacs 就得把它们全部复刻一遍。Kyo 的结论是，重写的难处不在"写编辑器本身很难"，而在于这些设计选择已经变成了 API。
- **扩展本身的脆弱性**：Kyo 举的例子是修改 Org 导出 HTML 时的锚点 ID。advice 了 `org-export-get-reference` 之后，发现 Org 有时直接调用 `org-html--reference`，还得再 advice 一个双横线的内部函数，而它随时可能在下个版本里改掉。走得更远的 `el-patch` 直接改写函数体内部的代码，需要专门的工具去检查补丁是否还有效。暴露一切让什么都能改，也让什么都没有稳定的契约。正如 xkcd 那幅漫画说的：every change breaks someone's workflow。

## 细腰其实有多细

matklad 说 Emacs 的腰很细：就是带属性的文本。Kyo 从实现的角度看到的却是：腰其实很粗。display 属性部分图灵完备，`composition-function-table` 可以调 Lisp，重显示里同步执行任意代码，display table 能改写换行符的显示。

两者都对。**概念上的腰很细，但属性的词汇表是开放的，粗细就藏在那里。** "带属性的文本"这个说法本身很简单，可每多一个有行为的属性，尤其是会在重显示时回调 Lisp 的属性，细腰就粗一点。到最后，要准确复刻 Emacs 的显示，就必须复刻整个 Lisp 运行时。

Juicemacs 在 GUI 上的取舍，本质上是把腰削回去：只同步文本、属性和 overlay，拒绝在重显示中同步执行 Lisp。这样细腰才能跨进程传输，渲染端才能独立于 Lisp 运行时。代价是放弃了属性词汇表里最开放的那一部分。

所以，设计细腰时真正要决定的，不只是"有哪些原语"，还有"属性词汇表封闭到什么程度"。

## 结论

| 能力 | 来源 | 换成"Rust 核心 + 脚本语言"能否做到 |
| --- | --- | --- |
| 命令有名字、可替换 | 架构（命令循环通过符号分派） | 能：命令注册表 |
| 分层 keymap、模态作为插件、按命令重绑定 | 架构 | 能 |
| minibuffer 等于 buffer、焦点等于 selected window | 架构 | 能，但必须一开始就这么设计 |
| 可重入的命令循环 | 架构 + C 栈 | 能，换成显式的输入上下文栈，脚本侧用协程写出同步风格 |
| C 在决策点回调 Lisp、在子系统入口分派 | 架构 | 能 |
| 重显示中同步执行任意 Lisp | 架构 | 能做，但要放弃并发和渲染分离。Juicemacs 选择不做 |
| C 状态即 Lisp 变量，`let` 能改变 C 的行为 | 架构（转发）+ 运行时（动态绑定） | 部分：可以做带作用域的选项栈，但只覆盖显式登记的选项 |
| advice 任意 Lisp 函数、即时重定义 | 运行时（符号间接调用） | 只限脚本层 |
| 可编程的字符表、按位置覆盖的语法、带行为的文本属性、数据化的历史…… | 积累 | 能，但每一项都是一次设计决定，也是一份长期承诺 |
| 改写 C 里没预留扩展点的行为 | 都不行 | 不行。Emacs 也不行 |

Emacs 的特殊性有三个来源：

1. **架构决定扩展点在哪里**：命令循环在哪里交出控制权，按键查找有哪几层，minibuffer 是不是 buffer，C 的哪些状态做成了 Lisp 变量，重显示里允不允许跑 Lisp，子系统入口有没有分派点。
2. **运行时让扩展点变得廉价**：动态绑定、符号间接调用、即时重定义。
3. **积累决定扩展点有多少、多细**：可编程的 case table、CCL、`composition-function-table`、`\=`……这一项既不来自语言，也不来自整体架构，而是 Kyo 说的"API design, learning from history, listening to users"。

lem 的运行时比 elisp 强，也就是第二项更强，但缺第一项，第三项也还没来得及积累。CL 的能力找不到地方发挥。

## 对写编辑器的人意味着什么

**换一门更强的 Lisp 拿不到 Emacs。** 不管是 Chez 还是 CL，语言只能让扩展点变便宜，不能凭空产生扩展点，更不能替代几十年的积累。

**真正定义了 Emacs 的是它的细腰，也就是这几条架构决定：**

1. 只有一种东西：buffer。prompt、列表、输出、帮助都是 buffer；
2. 焦点就是当前窗口，没有第二套焦点状态；
3. 命令循环可以重入，"等待输入"就是再跑一层命令循环；
4. 按键查找按固定的分层顺序进行，每一层都是可替换的数据；
5. 核心在每个决策点回调扩展层，在子系统入口留分派点，内部状态对扩展层透明，而不是只在末端提供 API；
6. 扩展层操作的是核心自己的数据模型。

**这些决定在 Rust 加脚本语言里基本都能实现**，但每一条都要权衡代价。最需要提前想清楚的是两件事：

- **细腰的单位和属性词汇表。** 细腰的单位是"带属性的文本加 buffer"，还是更结构化的东西；属性只允许声明式的，还是允许在重显示中回调脚本。允许回调，就得到 Emacs 那种最深的可扩展性，代价是单线程重显示。只允许声明式或异步计算的属性，像 Juicemacs 那样，就能保住渲染的并发和分离，TUI 和 GUI 也能共享同一个显示模型。
- **内部状态暴露到什么程度。** 全部暴露，什么都能改，但没有稳定契约，Org 和 el-patch 的例子就是结果。只暴露登记过的选项和命令，契约清楚，但用户会撞到墙。

**也可以不复刻机制，只复刻语义。** 把 Emacs 定义为"实际用到的操作的可观察行为"，用测试固定下来，这条路的范围是有界的，也最容易成功。代价是没有涌现：Emacs 里因为"都是 buffer"白得的能力，在这条路上要逐项补齐。一个可行的折中是：当某类东西（prompt、候选列表、输出面板）反复需要补齐编辑能力时，再把它们收敛成统一的原语。只在需求证明有必要时才统一，不提前追求 Emacs 那种全局统一。

**第三部分的手法可以按需挑选。** 以 soda 为例，下面几项实现成本低，又直接对应已有的需求：

- **字符宽度覆盖表**：soda 目前用 `unicode-width` 计算宽度。加一张用户可配置的覆盖表，就能解决东亚歧义宽度和 emoji 在不同字体、终端下的对齐问题。
- **命令元数据开放给脚本**：soda 已经以命名命令作为统一接口。如果命令能带任意属性，并且任何 Lua 脚本都能给已有命令加属性，模态插件和其他插件之间就能像 `delete-selection` 那样协作，而不需要互相知道对方。
- **按命令重绑定**：keymap 里支持 `remap` 一类的条目，让插件替换"语义上的操作"，而不是猜测键位。
- **undo 记录可以携带回调**：类似 `(apply FUN . ARGS)`，让非文本状态的变化也能进入 undo 历史。
- **窗口放置规则集中化**：所有"打开一个面板"的操作经过同一个策略函数，让用户统一配置。

文件名处理器、文本属性携带行为、按位置覆盖语法这几项能力最强，但需要的架构改动也最大，适合等到有具体需求时再评估。

## 案例：键盘宏和 Beacon

2026 年 11 月，soda 按 Emacs 的 kmacro 和 meow 的 beacon 对齐行为，前后修了一串 bug。复盘下来，它们几乎都不是某个行为写错了，而是**行为所依附的那条边界在 soda 里不存在**。这和第 3 节 minibuffer 的情况同构：功能是架构的产物，只照抄功能，就得逐个补上它默认存在的前提。

| 现象 | Emacs 里行为依附的机制 | soda 当时的做法 |
| --- | --- | --- |
| `b` 之后各词首的假光标，约一秒后消失 | meow 在 `post-command-hook` 里重算 overlay（`meow-core.el` 157 行）；这个钩子只在命令循环里运行（`keyboard.c` 1338 行），定时器不触发 | 挂在"执行一条命令"的统一入口上；LSP 的 idle 钩子经由同一入口执行命令，也触发了重算 |
| `C-u 3 <f4>` 把 `C-u 3` 录进了宏 | 宏只在命令结束、且没有待用的前缀参数时确认边界（`finalize_kbd_macro_chars`，`keyboard.c` 1684 行），结束录制的命令连同前缀参数都不进宏 | 每个按键判断"是不是新开头"来推算，漏了前缀参数 |
| `C-x e e` 的第二个 `e` 起初被当成文字 | `set-transient-map`（`subr.el` 7006 行）只对下一条命令生效，按命令的按键（`this-single-command-keys`）查表 | 路由里的一个零散字段，查表时按键没规范化 |
| 第二选区和主选区看不出区别 | 第二选区是一个带 `secondary-selection` face 的 overlay，假光标、假选区是 meow 的另外两个 overlay，face 混色 | 只有一个"是否选中"的布尔值 |
| 在 grab 开头输入的字落到 grab 外面 | overlay 两端的推进方向由 `make-overlay` 的 FRONT-ADVANCE、REAR-ADVANCE 决定（`buffer.c` 3639 行），默认开头输入的文字在内，末尾输入的在外 | 两端都用了"跟在输入之后"，开头就漏了 |

前三条是同一个缺口：**soda 没有显式的命令循环。** Emacs 的一次按键是一条有开始和结束的命令，`this-command`、`last-command`、`this-command-keys`、宏的边界、临时键表、`pre-command-hook` 和 `post-command-hook` 都挂在这两条边上。soda 的按键直接解析成命令执行，这些概念各自用一个字段、一个判断模拟。单独看都对，但它们分散在不同入口，钩子、Lua、宏回放和用户按键走的又是同一个执行入口，组合起来就在没想到的路径上出错。

修法不是再加判断，而是把边界补出来：`interaction/command_loop.rs` 显式区分一条命令的开始和结束，上面这些都挂到对应的边上；Lua、钩子、定时器和前端执行的命令不经过它，和 Emacs 里定时器在命令循环之外运行一样。之后再照搬"每条命令之前或之后"的 Emacs 行为，只需要挂到这里。

教训和 minibuffer 那次一样：**复刻语义的路线可行，但语义往往是定义在某条架构边界上的。** 照抄之前先问它依附在哪条边上，那条边在自己的编辑器里有没有；没有的话，先把边补出来，或者干脆不照抄这个行为。
