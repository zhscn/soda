# 交互层与搜索会话

交互层（`src/interaction/`）管理模态编辑、键位、命令和输入组件，输出 Application 事件。编辑核心拥有文档、选区、位置映射和历史；Runtime 执行事件、观察更新并调度后台任务；前端转换平台输入并绘制交互状态。

## 输入路由与命令循环

前端把平台事件转换为 `UserInput`：按键（`KeyStroke`，含修饰键、未支持修饰键和释放标记）、粘贴、鼠标（`Pointer`）、焦点变化或未识别输入。重复按键与按下使用相同绑定；释放和未配置的组合不会提交、取消或修改输入。

`Layers::route_input` 是入口。`Layers` 在编辑视图上方最多持有一个模态层（`Layer`）：命令行、保存等待、帮助、搜索、替换、屏幕标签、窗口调整。有模态层时只由它处理输入，它不识别的键也被阻止；关闭模态层的那个键不再交给文档。没有模态层时，按键经键位栈解析为 `interaction::Command`，粘贴解析为一次插入，再由 `Layers::execute` 执行。Lua 和钩子也走 `Layers::execute`，共用目标解析和安全检查。

结果是 `InputResult`：`Pass`（没有绑定，Runtime 忽略）、`Blocked`（被模态层阻止）或 `Handled(Response)`。`Response` 包含有序的 Application 事件、picker 任务、重绘、退出和消息操作（保留、清除、替换）。Runtime 每执行一个事件，先把更新交给 `Layers::observe` 并处理后续响应，再执行下一个事件或读下一次输入；文件和 picker 的完成事件同样如此。模态层内部转换为 `Blocked`、`Active(Response)`、`Closed(Response)`，`enter`、`close` 和确认都统一处理前一会话的恢复事件与任务取消。

**命令循环**（`interaction/command_loop.rs`）对应 Emacs 的 `command_loop_1`：输入读成一条条命令，每条命令有开始和结束。前缀参数或按键序列还没输完时，命令在读取中；不留下这两者的那个输入结束这条命令。

- **开始时**：这条命令的按键从头记；正在录的键盘宏记下命令从哪里开始，所以结束录制的那条命令连同它的前缀参数都不进宏（`finalize_kbd_macro_chars`）；上一条命令设的临时键表接这一个键（`set-transient-map`，如 `C-x e` 之后的 `e`）；`C-g` 放弃正在录的宏（`keyboard-quit`）。
- **结束时**：`last-command` 变成这条命令；用户输入的命令还要做命令后的工作（`post-command-hook`），现在是 Beacon 跟随光标。
- **不经过命令循环的**：Lua、钩子、定时器和前端直接执行的命令不是用户的命令，同 Emacs 里定时器在命令循环之外运行，不触发命令后的工作。宏回放的输入经过命令循环，标为执行中（`executing-kbd-macro`），也不触发命令后的工作。
- **焦点等事件**：不算命令，同 Emacs 的 special event。

新的"每条命令之前或之后"的行为都挂在这里，不要另找入口。

命令在执行时解析活动视图；活动视图变化时命令行和保存等待结束，所以另存为、跳转不会落到另一个视图上。没有活动视图时，需要视图的命令不产生事件。前端显式提供项目根目录，交互层不读取进程工作目录。

输入组件 `TextInput` 持有单行文字和有方向的 UTF-8 字节选区，操作维持 grapheme 边界，按词操作使用 Unicode word 边界，插入和粘贴过滤控制字符。文字变化触发查询，只有选区变化时只重绘。

## 模态编辑模型

模态编辑是可选的：没有配置时只有 Insert，键与裸 Emacs 一样，状态栏不显示模式名。`require("meow").setup()` 设 `modal` 选项、绑上 Normal 的布局，才有下面的模型（见[插件](extension.md#插件)）。模型取自 meow：先选中，再对选区操作。设计理由、与 meow 和 kakoune 的差别见[模态编辑的设计](modal.md)。`interaction/modal/` 的划分：

| 文件 | 内容 |
| --- | --- |
| `mod.rs` | `Action`（键触发的动作）和模态状态 |
| `text.rs` | 文本中的位置，纯函数 |
| `execute.rs` | 每个动作如何改变或使用选区 |
| `beacon.rs` | Beacon 的多选区 |
| `replay.rs` | 键盘宏的录制、宏环和计数器 |
| `kmacro.rs` | 键盘宏命令，同 kmacro.el |

`modal` 打开时模式有三个；关掉时只有 Insert，`SetMode` 和离开 Insert 都不会到别的模式，Esc、`C-g` 只清除选区和待完成的键，与 Emacs 的 `keyboard-quit` 相同：

| 模式 | 单键的含义 |
| --- | --- |
| Normal | 移动、选择、对选区操作；没有绑定的键什么也不做 |
| Insert | 输入字符 |
| Beacon | Normal 的键，加上派生选区：选区在 grab 范围内成组出现 |

下文讲行为时用的单键是测试所用的布局（`tests/fixtures/modal.lua`，即 meow 成为插件之前内置的布局）：`w`/`b`/`W`/`B` 为 `next-word`/`back-word`/`next-symbol`/`back-symbol`，`[`/`]` 为 `mark-word`/`mark-symbol`，`e` 为 `select-line`，`r`/`s` 为 `kill`/`change`，`'` 为 `join`，`` ` `` 为 `repeat`，`Z` 为 `pop-all-selection`，`N` 为 `search-pop`，`U` 为 `redo`，`S` 为 `swap-grab`，`E`/`V` 为 `macro-lines`/`macro-matches`，`x`/`c`/`m`/`g` 为 keypad。meow 的 `qwerty` 布局里这些命令在别的键上，见 [Normal 键](#normal-键)。

选区是核心中的半开范围，空选区就是光标。光标可以停在行尾，离开 Insert 时不回退。提示输入是覆盖在模式上的层；keypad 是读键状态，都不是模式。

### 选区的种类

选区带一个种类（`Kind`）：字符、词、符号、行、块、查找（`f`/`t`）、visit（搜索匹配）、join、thing。种类随选区记住；选区被其他方式改变（编辑、鼠标、Lua）后种类失效。字符选区是 mark：锚点不变时，头部怎么移动都保持字符种类。

命令按种类决定扩展还是替换：

| 命令 | 同种类已有选区 | 其他情况 |
| --- | --- | --- |
| `h j k l` | 字符选区：移动头部 | 取消选区后移动 |
| `H J K L` | 移动头部 | 从光标开始字符选区 |
| `w b W B` | 由 `[`、`]` 产生的：扩展；由 `w` 产生的：替换为下一个 | 从光标开始 |
| `e` | 向选区方向扩展 | 选中当前行，不含换行 |
| `o` | 取父分组 | 取周围的分组，光标紧贴开括号时取这一组 |
| 数字 | 按种类再走 N 步，保持远端和种类 | 没有选区时是计数 |

`w` 取到下一个词的结尾，包含词前的空白，遇到标点停止：`foo bar, baz` 连按 `w` 依次选中 `foo`、` bar`、` baz`。词只含字母数字，符号另含下划线。选中后行尾附近显示 1 到 0 的数字，表示按该数字能扩展到哪里，1.5 秒后或下一个键时消失。

`o`、`O`、`,`、`.` 的括号走语言结构，字符串和注释里的括号不算分组；C++ 模板和 Rust 的泛型 `<>`、闭包 `|…|` 也是分组。结构查询需要可变访问，所以经 `Effect::Structure` 交给 Runtime，答案以 `Action::Found` 回到交互层。

### Normal 键

Normal 的键分两层。打不出字符的键是内置默认键（`interaction::keymap` 的 `NORMAL` 表），与 Insert 中的 Emacs 键对应：方向键、`C-b C-n C-p C-f` 移动，Shift+方向键扩展，`Home`/`End`、`C-a`/`C-e`、`M-<`/`M->`、`M-b`/`M-f`，PageUp/PageDown；`C-Space` 开始字符选区；`C-w`、`M-w`、`C-y`、`M-y`、`C-d`、`C-k`、`M-d`、`M-Backspace`；`C-s`/`C-r` 搜索；`Esc`/`C-g`/`C-[` 清除选区和历史；Enter `jump`，`C-o`/`C-i`（Tab）跳转历史，`F1` 帮助。

能打出字符的键是布局，由 meow 插件给出。默认布局 `qwerty` 是 meow README 里的 QWERTY 布局，去掉 soda 没有的命令（`meow-beginning-of-thing`、`meow-end-of-thing`、`meow-backward-delete`、`meow-quit`、`meow-replace`、`meow-undo-in-selection`、`meow-sync-grab`）：

| 类别 | 键 |
| --- | --- |
| 移动 | `h j k l`；`H J K L` 扩展 |
| 选择 | `w`/`W` 选中此处的词/符号并设为搜索；`e`/`E`、`b`/`B` 向后/向前选词/符号；`x` 行；`o` 周围分组，`O` 到下一个分组结尾；`f`/`t` 加字符：选到/选到之前；`,`/`.` 加 thing：内部/包括边界；`m` 本行与上一行之间的空白（join）；`;` 交换两端；`g` 清除选区 |
| 选区历史 | `z` 退一步 |
| 计数 | `0`–`9` 扩展（无选区时为计数），`-` 反向下一条命令 |
| 进入 Insert | `i`/`a` 选区开头/结尾，`I`/`A` 在上方/下方开新行 |
| 操作 | `s` 剪切，`c` 修改，`d` 删除，`y` 复制，`p` 粘贴 |
| 搜索 | `n`、`v` |
| 其他 | `u` 撤销，`'` 重复上一条命令，`Q`/`X` 跳到行，`G` grab，`R` 与 grab 交换，Space keypad leader |

布局也可以是自己的表：`setup({ layout = { h = "left", ... } })`。所有可绑的命令见 `F1`；`layout = false` 时不绑，自己用 `soda.map("normal", ...)` 绑。

thing 键（`,`、`.` 之后）开始是 meow 的 `meow-char-thing-table`：`r s c` 圆、方、花括号，`g` 字符串，`e` 符号，`w` 词，`p` 段落，`l` 行，`b` 整个文档。`soda.thing(key, kind)` 或 meow 的 `things` 选项加键，如 `{ a = "angle" }` 让 `a` 选尖括号。

### 操作

| 键 | 命令 | 无选区 | 有选区 |
| --- | --- | --- | --- |
| `r` | `kill` | 剪切到行尾 | 剪切；正向的行选区带上换行；join 选区合并两行 |
| `s` | `change` | 删一个字符，进入 Insert | 删除，进入 Insert，不写剪贴板 |
| `d` | `delete` | 删一个字符 | 删除，不写剪贴板；join 选区合并两行 |
| `y` | `save` | 报告 No selection | 复制，然后取消选区，光标留在原处（同 Emacs 的 `kill-ring-save`） |
| `p` | `put` | 粘贴 | 收起选区后粘贴，不替换 |

查找失败时选区不变并报告。`u` 撤销后恢复修改前的选区。每次选择都把旧选区记入历史，供 `z`、`Z` 退回。`;` 交换两端后，`e`、数字、`n` 都跟随新方向。

`n` 取下一个匹配：选区不是当前搜索的匹配时，先把选中文本设为新的搜索。选区反向时反向走，到头绕回。`N` 丢弃当前搜索，退回上一个。`v`（`visit SYMBOL`）在命令行中补全当前文档的符号，按模糊匹配排序，同分时离光标近的在前；确认后从光标往后选中下一处并设为当前搜索。选的是文档中的符号时按整个符号找（`add` 不匹配 `add_x`），否则按字面文字找。`C-s`、`C-r` 打开带实时预览的搜索（见[搜索与替换](#搜索与替换)）。跳转后行尾显示 `[i/N]`，下一个键清除。

计数来自无选区时按的数字，或绑到 `digit-argument N` 的键（之后的数字继续累加）。`` ` `` 重复上一条命令，不包括插入的文字。

### Keypad

keypad 的入口是普通命令：`keypad leader`（meow 布局里是 Space）、`keypad C-x`、`keypad C-c`、`keypad meta`、`keypad ctrl-meta`，绑在布局的哪个键上由布局决定；下表假设 `x`、`c`、`m` 绑了后三个。绑定只有一份：`C-x C-s` 写在 `global` 表里，keypad 读键时每个键先试加 Ctrl，再试原样，只查 `global` 表；`m`、`g` 给下一个键加 Meta / Ctrl-Meta，按当前键位栈查找。

| 键 | 序列 | 说明 |
| --- | --- | --- |
| `x s` | `C-x C-s` | Ctrl 优先 |
| `x k` | `C-x k` | 没有 Ctrl 绑定，退回原样 |
| `x SPC o` | `C-x o` | Space 强制下一个键不加修饰，与 `C-x C-o` 区分 |
| `SPC f` | `C-c f` | leader 的第一个键不加修饰 |
| `m x` | `M-x` | 只作用于下一个键 |

Backspace 退掉上一个键，Esc 取消，计数跨过 keypad 保留。与 meow 的差别见[模态编辑的设计](modal.md)。

### 宏

照 Emacs 的 kmacro.el 做，键位和行为都对应：

**录制与播放**

| 键 | 命令 | 对应 | 行为 |
| --- | --- | --- | --- |
| `F3` | `macro-start` | `kmacro-start-macro-or-insert-counter` | 开始录制；录制或播放中插入计数器 |
| `C-x (`、`C-x C-k s` | `macro-record` | `kmacro-start-macro` | 开始录制；已在录制时提示 |
| `F4` | `macro-end` | `kmacro-end-or-call-macro` | 结束录制，否则播放上一个宏 |
| `C-x )` | `macro-stop` | `kmacro-end-macro` | 只结束录制，没在录制时提示 |
| `C-x e` | `macro-end-and-call` | `kmacro-end-and-call-macro` | 结束录制并播放；之后单按 `e` 再播放 |
| `C-x C-k C-k` | `macro-end-repeat` | `kmacro-end-or-call-macro-repeat` | 同 `F4`；之后单按 `C-k` 再来 |

**前缀参数**

- **次数**：播放的次数；结束录制时带次数，录制本身算第一次。`0` 表示一直播放到某个命令失败，比如 `C-n` 到了最后一行。
- **用作计数器初值**：`C-u 5 F3` 让计数器从 5 开始。
- **追加**：`C-u F3` 先把上一个宏再播放一遍，然后接着往后录；`C-u C-u F3` 不播放直接追加。
- **播放第二个**：`C-u F4` 播放宏环里的第二个宏。
- **不录进宏里**：前缀参数属于后面那条命令，结束录制时的 `C-u 3` 不会录进去。

**放弃与空宏**

- **`C-g`**：放弃正在录的宏，上一个宏保留（同 `kmacro-keyboard-quit`）。
- **空宏**：什么也没录时提示 "Ignore empty macro"，上一个宏保留。

**宏环**

最近 8 个宏组成宏环（`kmacro-ring-max`），每个带着自己的计数器：

| 键 | 作用 |
| --- | --- |
| `C-x C-k C-n` / `C-x C-k C-p` | 轮换 |
| `C-x C-k C-l` | 播放第二个 |
| `C-x C-k C-t` | 交换前两个 |
| `C-x C-k C-d` | 删除当前的 |
| `C-x C-k C-v` | 显示当前宏的按键 |

这几个之后单按最后一个键继续，同 kmacro 的 repeat key。

**计数器**

| 键 | 命令 | 作用 |
| --- | --- | --- |
| `C-x C-k C-i` | `macro-insert-counter` | 插入计数器后加一；带次数时加该数，`C-u` 插入上一个值 |
| `C-x C-k C-c` | `macro-set-counter` | 设定计数器 |
| `C-x C-k C-a` | `macro-add-counter` | 加到计数器上 |
| `C-x C-k C-f` | `macro-set-format` | 设定格式：`%d`、`%x`、`%o`、`%c`，带 `0`、`-`、`+` 和宽度，如 `%03d` |

没给参数时在命令行里问。

**命名**

`C-x C-k n`（`macro-name NAME`）给上一个宏起名，它就成为命令 `NAME`，可以从 `M-x` 运行，也可以绑键。命令内部是 `macro-call NAME`。

**没有做的**

`C-x q` 查询、宏编辑（`C-x C-k e`、`RET`、`SPC`）、`C-x C-k b` 绑键、寄存器相关命令。

录的是按键，回放走同一条路由，补全列表中的选择录成结果文字。`E` 在选中的每一行行首播放，`V` 在搜索的每处匹配播放，都合成一次撤销；任一命令失败时停止。

### Beacon

Beacon 照 meow 的 `meow-beacon.el` 做，键也按 meow 的 beacon 键表分派。

**grab 与进出**

- **`G`**：把选区设为 grab，也就是 Emacs 的第二选区。没有选区时 `G` 取消 grab，只留下标记，之后用 `S` 把选区与它交换（同 `meow-grab`）。
- **进出 Beacon 跟着光标走**：同 `meow--maybe-toggle-beacon-state`，每条命令结束时看光标在不在 grab 里（含两端），在就是 Beacon，不在就是 Normal。grab 一直留着并显示，光标回来时再进入。
- **离开的方式**：Esc 只取消选区，不离开 Beacon；离开 Beacon 靠把光标移出 grab，或无选区时按 `G`。
- **不切换的时候**：录制和回放宏、按键序列没输完、搜索等交互层打开时。
- **grab 跟着编辑**：同 Emacs 的第二选区（`make-overlay` 默认参数建的 overlay），在开头输入的文字算在 grab 里，在末尾输入的不算。

**显示**

- **grab**：用 `secondary-selection` face 画出，范围越过行尾时，行尾之后那一格也画上。
- **其余选区与插入点**：其余选区用 `beacon-selection`，其余插入点用 `beacon-cursor`。没设置时，取 `selection`、`mode-beacon` 各与 `secondary-selection` 的背景对半混合，同 meow 的 `meow-beacon-fake-selection`、`meow-beacon-fake-cursor`。
- **行尾的插入点**：没有字符可以落脚，画在行尾之后那一格。

**派生**

每条命令之后，其余位置按主选区的种类重新派生（`meow--beacon-update-overlays`）。主选区在会话中，其余位置是跟随编辑的 `DocumentPosition`，不进入核心。派生出插入点的种类，主选区随之缩成光标。

| 主选区 | 其余位置 | 主选区 |
| --- | --- | --- |
| 无（只有光标） | 其他行同一字符列的插入点（按字符计，tab 算一个）；较短的行跳过 | 缩成光标 |
| 字符（`H`/`L`、mark） | 其他行同样字符列范围的选区 | 不变 |
| 词、符号（`w`/`b`） | 向前时每个词尾、向后时每个词首的插入点 | 缩成光标 |
| 词、符号（`[`、`]`） | 同一个词的其余匹配，作为 visit 选区 | 不变 |
| visit | 搜索的其余匹配 | 不变 |
| 行 | 与主选区同样高的每组行，在它上下各自对齐；凑不满一组的行跳过 | 不变 |
| join | 每行缩进处的插入点 | 缩成光标 |
| 查找、到达（`f`/`t`） | 每处该字符的插入点：查找时向前落在字符之后、向后落在字符上；到达时相反 | 缩成光标 |

**编辑**

- **`i`、`a`、`s`**：主选区单独进入 Insert，同时录宏。Esc 结束录制，然后在每个其余位置用同样的方式进入 Insert、回放输入、再按 Esc（`meow-beacon-insert`、`meow-beacon-change`）。所以 Insert 里任何键都会到达每一处，包括补全、自动配对和回车缩进。
  - 没有选区时 `s` 改光标处的一个字符，同 `meow-beacon-change-char`。
- **`r`**：把主选区剪下放进剪贴板，删除其余选区，插入点不动，一次撤销（`meow-beacon-kill-delete`）。
- **什么也不做的键**：`d`、`y`、`A`、`I`、`S`，同 meow 键表里的 `meow-beacon-noop`。

**宏**

- **在 Beacon 里录宏**：`<f3>` 先回到 Normal，只编辑主选区，其余位置留着。`<f4>` 或 `C-x e` 结束录制，在每个其余位置回放（同 `meow-end-or-call-kmacro`）。
- **在 Beacon 里按 `<f4>`**：先在主选区上播放上一个宏，再在每个其余位置播放（`meow-beacon-apply-kmacro`）。
- **回放的起点**：插入点处是光标，选区处是派生时主选区的种类和方向。
- **撤销与主光标**：在其余位置的回放合成一次撤销，主选区的修改是各自的步骤。回放完主选区回到原处（`save-mark-and-excursion`），然后照常按光标位置进出 Beacon。

## 命令、键位与配置

按 kakoune 的方式组织：所有用户可调用的操作都是有名字的命令，键位、`:` 命令行、配置、钩子和帮助只引用命令名。Lua 向同一张命令表注册命令，见[扩展模型](extension.md#lua)。

### 命令表

`interaction::registry` 保存命令，每个条目有名字、参数位和一行说明：

| 来源 | 定义方式 | 名字规则 |
| --- | --- | --- |
| 内置 | `BUILTINS` 静态表，参数解析为类型化 `Command` | 固定，不可替换 |
| 用户定义 | `define-command NAME BODY`、`soda.define_command` | 不可与内置名冲突，重复定义替换；帮助显示命令体或 Lua 给的说明 |

命令行的第一个空白分隔词是命令名，其余部分去掉首尾空白后整体作为参数，由命令自己解释（路径保留内部空格，`map` 再拆分模式、按键和目标）。`Command::Named(line)` 在执行时才解析，所以绑定可以引用之后才定义的命令。`:` 命令行、`soda.command`、键位目标和命令体使用同一个解析器；`:42` 这种纯数字表示跳转到行。

命令体用 `;` 分隔多条命令，`\;` 是字面分号；`%arg{1}` 到 `%arg{9}` 替换为按空白拆分的调用参数，`%arg{@}` 为完整参数。嵌套用户命令最多展开 16 层，超过时整条命令不执行；未知命令名和参数错误也在执行前报告。展开得到的命令依次执行，第一次失败时停止；某条命令打开交互组件后，后续命令被阻止。`%opt{}`、`%val{}` 的展开见[扩展模型](extension.md)。

### 键位上下文

键位表有两类。上下文是固定的：`global`、`normal`、`beacon`、`insert`、`completion`、`snippet`、`mark`、`tree`、`results` 和 `prompt`（所有输入框、picker 与确认）。文档键位表只在部分文档里生效，相当于 Emacs minor mode 和 major mode 的 keymap：

- **语言的表**以语言 id 命名（`cpp`、`rust`……），在这种语言的文档里生效，第一次往里绑定时建立。
- **服务器的表**由模块用 `soda.keymap(name, { server = ... })` 声明，在这个服务器服务的文档里生效；`server = "*"` 表示任一服务器。服务器停掉或退出后，它的表随之失效。内置的 `lsp` 表属于任一服务器，`ccls` 表属于 ccls。

按键在一个栈中查找，先查到的算数，与 Emacs 读 active maps 一样（`Layers::stack`）：

| 模式 | 栈 |
| --- | --- |
| Insert | `completion`（列表显示时）、`snippet`（还有位置时；位置在提供选项时排到 `completion` 之前）、不是模态编辑时同 Normal 的 `mark`/`tree`/`results`、`insert`、文档键位表、`global` |
| Normal | `mark`（光标在标记的符号上时）、`tree`（在树文档中时）或 `results`（在结果文档中时，Enter 是 `jump`）、`normal`、文档键位表、`global` |
| Beacon | `beacon`、`normal`、文档键位表、`global` |

文档键位表中，服务器的表在前，后声明的先查（`ccls` 在 `lsp` 之后声明，所以同一个键以 `ccls` 的为准），语言的表在最后。它们和 `global` 一样不分模式，在模式表之下，所以遮不住 Normal 的单键，适合 `C-c` 开头的键。`global` 是所有模式共有的键，`C-x`、`C-c` 下的键都在这里。keypad 读不加修饰的键时查文档键位表和 `global`，所以绑到 `C-c` 下的键同时有 `SPC` 入口。

每张表依次查找：

1. 用户层：`map KEYMAP KEYS COMMAND` 写入，`unmap KEYMAP KEYS` 删除，默认解释（内置的或插件的）随之恢复。`KEYMAP` 是上下文、已声明的文档键位表或语言 id，其他名字报错。
2. 默认层：`interaction::keymap` 中的静态表，引用命令名并在启动时解析，测试保证每个默认条目都能解析；内置模块和插件用 `soda.map_default` 绑的键也在这一层，后绑的替换相同或互为前缀的默认键。
3. 都没有时：Normal 和 Beacon 忽略这个键；insert 和 prompt 的可打印字符直接输入。

用户层的完整绑定不能同时是另一个用户绑定的前缀；用户层前缀会遮住默认层中相同开头的单键。序列最多四个按键。Esc、`C-[`、`C-g`、`C-c` 取消待完成序列；前三个不能作为序列的第二个及以后的按键，`C-c` 可以（`C-x C-c`）。要关闭某个默认键，绑定到 `nop`。

`prompt` 的目标是输入动作而不是应用命令：`confirm`、`cancel`、`complete`、`complete-backward`、`candidate-next`、`candidate-previous`、`candidate-first`、`candidate-last`、`page-next`、`page-previous`、`history-next`、`history-previous`、`match-next`、`match-previous`、`replace-all`、`confirm-input`、`help`、`select-all`、`nop`，以及[行编辑键](#行编辑键)。prompt 绑定只接受单个按键，所以输入组件不会执行文档命令或切换模式。

### 括号配对

Insert 中按选项 `auto-pairs`（默认关）成对输入括号，与 Emacs 的 electric-pair-mode 相同，在同一个输入事务中完成，一次撤销：

- 输入 `(`、`[`、`{` 时，若光标后是行尾、空白、右括号、`;` 或 `,`，同时插入右括号，光标留在中间。在 `{|}` 中回车展开成三行；C++ 以外的语言对 `(|)`、`[|]` 也一样。
- 输入的右括号与光标后的字符相同时，越过它。
- 光标在空的一对之间退格，两边一起删除。
- 有选区时输入左括号，用这一对包住选区。
- 引号按语言配对：C++ 配对 `"` 和 `'`，其他语言取语言配置的 `autoClosingPairs`（Rust 没有 `'`），纯文本不配对。前一个字符是字母、数字、`_` 或引号时不配对；字符串内输入同一个引号会越过结尾的引号。
- 注释和字符串内不配对。C++ 和 Rust 由自己的词法判断，其他语言用 TextMate 结果，纯文本没有这一层。
- 粘贴不配对。

### 结构化编辑

内置模块 `pairs`（`lua/pairs.lua`）提供 puni 的操作。它基于 `buf:enclosing`、`buf:next_item`、`buf:prev_item`，所以所有语言都能用；C++ 和 Rust 的分组来自自己的结构分析（含模板、泛型 `<>` 和闭包 `|…|`），其他语言按 `(`、`[`、`{` 配对。结构不明确时（未闭合的分组、被 `#if` 拆开的分组）退回普通命令的行为。这些移动不进入跳转历史。

`pairs` 只绑 Emacs 自己的 sexp 键；puni-mode-map 的键要 `require("puni").setup()`；`sexp-slurp`、`sexp-barf` 与 puni 一样没有键。

| 键 | 来源 | 命令 | 作用 |
| --- | --- | --- | --- |
| `C-M-f` / `C-M-b` | 内置 | `sexp-forward` / `sexp-backward` | 越过一个表达式，停在分组边界 |
| `C-M-u` | 内置 | `sexp-up` | 到包围它的分组开头 |
| `C-M-SPC` | 内置 | `sexp-expand` | 选中光标处或包围它的分组，再按扩大一层 |
| `C-M-k` / `C-M-DEL` | 内置 | `sexp-kill-forward` / `sexp-kill-backward` | 剪切下一个 / 上一个表达式 |
| `C-M-a` / `C-M-e` | puni | `sexp-beginning` / `sexp-end` | 到所在分组内部的开头 / 结尾 |
| `C-k` | puni | `sexp-kill` | 剪切到行尾；有表达式越过行尾时剪到它结束，遇到所在分组的闭括号时停在它之前 |
| Insert `DEL` | puni | `soft-backspace` | 删除会破坏配对时只移动光标；空的一对整个删除 |
| Insert `C-DEL`、`M-DEL` | puni | `soft-kill-word` | 向前剪一个词进 kill ring；标点剪到最近的括号为止，紧邻括号时同 `soft-backspace` |
| Insert `C-w` | puni | `kill-region-or-word` | 有选区时剪切选区，否则同 `soft-kill-word` |
| 无 | | `sexp-slurp` / `sexp-barf` | 把闭括号移到下一个表达式之后 / 最后一个表达式之前 |

没有写模式的键在 Normal 和 Insert 中都有效。`foo(a,⏎ b);` 行首的 `C-k` 留下 `;`，`if (x) {⏎} else {⏎}` 行首的留下 `else {⏎}`，与 puni 相同。插件的键是默认绑定，用户绑定遮住它，`unmap` 后恢复插件的键。

### Emacs 键位

没有配置时的键就是这些，取自 Emacs 默认值，另有 `C-v` / `M-v` 翻半页（view-mode）。开了模态编辑时它们与布局并存，Normal 中的 Emacs 移动和剪切键见 [Normal 键](#normal-键)。

所有模式（`global` 表）：

| 键 | 命令 |
| --- | --- |
| `C-x C-s`、`C-x C-w`、`C-x C-f`、`C-x C-r` | `write`、`saveas`、`open`、`recent` |
| `C-x b`、`C-x C-b`、`C-x k`、`C-x C-c` | `buffer`、`buffer`、`kill-buffer`、`quit` |
| `C-x ←`、`C-x C-←`；`C-x →`、`C-x C-→` | `previous-buffer`；`next-buffer`：按使用顺序往前 / 往后，连按继续走，不来回跳 |
| `C-x s` | `save-some-buffers`：逐个询问未保存的文件，`y` 保存、`n` 跳过、`!` 保存这个和之后的全部、`q` 不再保存；未命名文档不问 |
| `C-x 0`、`1`、`2`、`3`、`o` | `close-window`、`only`、`split`、`vsplit`、`window-next` |
| `C-x ^` | `resize-window` |
| `C-x p f`、`C-x p p`、`C-x p b`、`C-x p g` | `project`、`project-switch`、`buffer`、`grep` |
| `M-x`、`M-!`、`M-\|`、`M-%` | `commands`、`shell`、`pipe`、`replace` |
| `M-s .` | `search-symbol`：搜索光标处的符号（整个符号匹配），从符号开头开始，第一处就是它，`C-s` 往下 |
| `C-x z` | `repeat`：再执行一次上一个键的命令 |
| `C-u` | `universal-argument`，见下 |
| `M-g g`、`M-g M-g` | `goto` |
| `M-g n`、`M-g p`、``C-x ` `` | `next-result`、`previous-result`、`next-result` |
| `M-,`、`C-M-,` | `jump-back`、`jump-forward` |
| `C-v`、`M-v`、`C-l` | `half-page-down`、`half-page-up`、`recenter`（同 `recenter-top-bottom`：连按依次居中、置顶、置底，中间按过别的键就从居中重新开始） |
| `C-/`、`C-_`、`C-x u`；`C-M-/`、`C-M-_` | `undo`；`redo` |
| `C-z` | `suspend` |
| `C-c C-c` | `stop` |
| `F3`、`C-x (`；`F4`、`C-x )`；`C-x e` | `macro-start`；`macro-record`；`macro-end`；`macro-stop`；`macro-end-and-call` |
| `C-x C-k` 下的键 | 宏环、计数器和命名，见[宏](#宏) |

`C-u` 同 Emacs 的 `universal-argument`：给下一个命令一个次数，默认 4，再按 `C-u` 乘 4（`C-u C-u` 为 16）；之后输入的数字替换 4（`C-u 8` 是 8，`C-u 1 2` 是 12），`-` 取负。模态命令自己读次数（Normal 的移动、宏等）；编辑命令、剪切和 Lua 命令不读次数，执行这么多遍，合成一次撤销：`C-u 8 C-n` 下移 8 行，`C-u 5 a` 输入 5 个 a，`C-u 3 M-u` 大写 3 个词。`kill-line`（`C-k`）带次数时同 Emacs，剪掉整行连同换行：`C-u 2 C-k` 剪两行，`C-u 0 C-k` 剪到行首。其他命令（打开命令行、列表、窗口操作等）只执行一次，次数丢弃。负数按绝对值重复，不反转方向；`C-u C-SPC`、`C-u M-!` 这类原始前缀的特殊含义没有实现。`C-u C-g` 取消；`C-c` 开头的绑定照常接收次数（`C-u 3 C-c z`）。

"连按"同 Emacs 的 `last-command`：看上一个键执行的命令，中间输入了文字也算打断。`recenter` 的循环、`previous-buffer`/`next-buffer` 的继续走都按这个判断。

`C-c` 是前缀，不离开 Insert；模态编辑时离开 Insert 用 Esc、`C-[` 或 `C-g`。

`C-c` 加字母留给用户，内置键和插件都不占用（[插件](extension.md#插件)）。模态编辑时 Normal 的 `SPC` 读作 `C-c`，所以用户绑在 `C-c` 下的键同时是 leader 键。`project`、`recent`、`jump-to`、`window-pick`、`window-left` 等命令要用户自己绑，或用 `M-x`。

Normal、Insert 都有效（`lua/emacs.lua`、`lua/comment.lua`）：

| 键 | 命令 |
| --- | --- |
| `M-u`、`M-l`、`M-c` | `upcase-word`、`downcase-word`、`capitalize-word`；只看当前行，只转换 ASCII |
| `C-t`、`M-t` | `transpose-chars`、`transpose-words`；只看当前行 |
| `M-\`、`M-Space`、`M-^` | `delete-horizontal-space`、`just-one-space`、`join-line` |
| `M-;` | `comment`，切换行注释 |

Insert 另有 `C-Space` 设 mark（之后的移动从 mark 扩展选区，与 Emacs 一样；模态编辑时 Insert 不这样）、`C-w`（`kill-region`）剪切选区、`M-w`（`kill-ring-save`）复制选区，没有选区时两者都只报 `The mark is not set now, so there is no region`；`C-x C-x` 交换选区两端，`C-x h` 全选。不是模态编辑时，有选区时输入、回车、`C-y` 在光标处插入并取消选区（Emacs 不开 delete-selection-mode 时的行为），Backspace 删除选区（`delete-active-region`）；模态编辑的 Insert 中输入替换选区。`C-n`、`C-p`、`M-<`、`M->` 移动，`C-s`、`C-r` 搜索（结束后回到 Insert，光标在匹配结尾），`C-o`、`C-j`、`M-m` 为 `open-line`、`newline`、`back-to-indentation`，`M-/` 触发补全，`M-y` 为 `yank-pop`。输入框另有 `C-g` 取消、`C-j` 确认、`M-<` / `M->` 到第一个 / 最后一个候选、`C-v` / `M-v` 翻页、`C-s` / `C-r` 下一个 / 上一个匹配、`M-p` / `M-n` 翻历史。

Alt 加 Shift 的符号键在 kitty 协议下按美式键盘换算。

### 按键记法

按键用 Emacs 的 `kbd` 记法，配置、帮助、状态栏和消息都是同一种：

- **键之间用空格隔开**：`C-x C-s`、`C-c v c`、`SPC f`。
- **修饰键**写在键前：`C-` Ctrl，`M-` Meta（Alt），`S-` Shift，可以叠加：`C-M-f`、`C-S-<left>`、`C--`。区分大小写；Emacs 的 `s-`（super）、`H-`、`A-` 不支持。
- **特殊键**：`RET`、`SPC`、`TAB`、`ESC`、`DEL`（Backspace）；其他功能键写在尖括号里：`<left>`、`<right>`、`<up>`、`<down>`、`<home>`、`<end>`、`<prior>`、`<next>`（PageUp、PageDown）、`<delete>`、`<backtab>`、`<f1>` 到 `<f12>`，以及别名 `<return>`、`<tab>`、`<escape>`、`<backspace>`、`<deletechar>`。
- **没有修饰键也不是特殊键的词**按字符逐个算键，与 `(kbd "abc")` 相同：`each-line i; ESC` 是 `i`、`;`、Escape。要输入空格写 `SPC`；字面的制表符没有写法。

命令行的 `map`、`unmap` 里 KEYS 是一个参数，有多个键时加双引号：`map global "C-c v c" ccls-callers`；Lua 的 `soda.map("global", "C-c v c", ...)` 本来就是字符串。

### 行编辑键

Insert 和输入框共享一组 readline 风格的命令。名字只定义一次，在 Insert 中转换为编辑命令，在输入框中转换为 `InputKey`：

| 默认键 | 命令 | 说明 |
| --- | --- | --- |
| Left / Right、`C-b` / `C-f` | `char-left` / `char-right` | 按字符簇移动 |
| `C-Left` / `C-Right`、`M-b` / `M-f` | `word-left` / `word-right` | 按 Unicode 词移动 |
| Home / End、`C-a` / `C-e` | `line-start` / `line-end` | 到行首 / 行尾 |
| Backspace / `C-h`、Delete / `C-d` | `delete-backward` / `delete-forward` | 删除字符簇；Insert 的退格在行首空白中按缩进单位回退 |
| `C-w`、`C-Backspace`、`M-Backspace` | `kill-word-backward` | 剪切到前一个词边界 |
| `C-Delete`、`M-d` | `kill-word-forward` | 剪切到后一个词边界 |
| `C-u` | `kill-line-start` | 剪切到行首；只在输入框中，Insert 的 `C-u` 是 `universal-argument`（往回剪到行首用 `C-u 0 C-k`） |
| `C-k` | `kill-line-end` | 剪切到行尾；位于行尾时剪切换行 |
| `C-y` | `yank` | 粘贴 |

Shift 加方向键、Home、End 扩展选区，对应 `extend-` 前缀的同名命令。Insert 中 `kill-*` 写入 kill ring，连续剪切合并成一条（见[剪贴板](#剪贴板)），与 Emacs 的 `kill-line`、`kill-word` 一样从光标算起，不管选区。输入框使用组件自己的剪切缓冲。`pairs` 模块在 Insert 中替换了其中几个键，见[结构化编辑](#结构化编辑)。

Insert 中 Tab 是 `indent-for-tab`，同 Emacs 的 TAB（`indent-for-tab-command`，`tab-always-indent` 为默认的 t）：不管光标在行中哪里，都按语言重新缩进本行，光标在前导空白中时移到第一个非空字符；有选区时重新缩进所选各行（选区终点恰在下一行开头时不含该行）。语言没有缩进分析时（C++ 和 Rust 之外的大多数语言）退回 `insert-tab`：有选区时缩进所选行，否则按文档的 tab/space 策略插入缩进。Shift-Tab 是 `outdent`；Enter 是语言感知的 `newline`。详见[缩进](indentation.md#输入重新缩进与其他来源)。

### 配置文件

配置只有一个文件：`$XDG_CONFIG_HOME/soda/init.lua`（未设置时为 `~/.config/soda/init.lua`），不存在时不报错。它在内置模块之后、第一个文档创建之前运行，所以能改写内置模块的命令和键位，其中的钩子也作用于启动时的文档。同一目录下的 `lua/` 放自己的模块，用 `require` 加载。`--no-config` 跳过配置。同目录下还有旧格式的 `init` 文件时，启动会提示把其中的行改写为 `soda.command("…")`。

键位、选项、配色和语言映射有对应的 Lua 函数，其余用 `soda.command("…")` 执行，见[扩展模型](extension.md#lua)。出错时第一个错误以 `lua: ` 开头显示在消息行并写入 `*messages*`，文件在出错处停下。

```lua
-- ~/.config/soda/init.lua
soda.map("global", "C-c f", "project")
soda.map("insert", "C-s", "write")
soda.command([[define-command fmt pipe clang-format --assume-filename="$SODA_FILE"]])
soda.map("global", "C-c =", "fmt")
soda.map("normal", "C-c y", function()
  soda.message(soda.buffer():name())
end, "Show the buffer name")
soda.set("line-numbers", "relative")
soda.set("clipboard", "internal")
soda.command("display grep right 60")
soda.face("syntax.comment", { fg = "#7a88cf", italic = true })
soda.language(".inc", "cpp")
soda.hook("open", [[.*\.py]], function()
  soda.set("indent-width", 4, true)
end)
```

`soda.map(mode, keys, target, [doc])` 的 `target` 可以是命令行或函数，按键提示和帮助显示 `doc`；`soda.unmap` 去掉绑定，`soda.bindings(mode)` 列出生效的绑定。`map`、`unmap`、`define-command`、`hook`、`unhook` 也可以在 `:` 中执行，对当前会话立即生效，不写回配置文件。

### 外部进程

| 命令 | 行为 |
| --- | --- |
| `pipe CMD` | 把选区（没有时为整个文档）交给 `sh -c CMD` 的标准输入；成功退出后标准输出作为一次可撤销编辑替换原范围 |
| `shell CMD` | 只运行命令，标准输入为空，退出状态和输出的第一行显示在消息行 |
| `run CMD` | 构建、测试这类长时间命令，输出流式写入 `*run*` |

`pipe`、`shell` 以当前文档的目录为工作目录，提供环境变量 `SODA_FILE`（未命名文档不设置）、`SODA_LINE`、`SODA_COLUMN`（从 1 开始）。它们在后台运行，同一时间只有一个，运行期间可以继续编辑；完成时文档已经变化，`pipe` 的结果被丢弃并提示。非零退出不修改文档，消息行显示标准错误的第一行。输出超过 16 MiB 或不是 UTF-8 时丢弃。

`run` 在项目根目录运行，标准输出和标准错误合并，按行写入 scratch 文档 `*run*`：第一行是 `$ CMD`，结束时追加退出状态，消息行显示 `CMD: exited N`。光标在最后一行的视图跟随新输出，移开后停止跟随。`*run*` 默认显示在底部 12 行的侧边窗口（`display run …` 可改）。同一时间只有一个 `run`，新的先停止旧的；它可以和 `shell`、`grep` 同时运行。超过 100,000 行的输出被丢弃并注明；非 UTF-8 字节显示为替换字符。

`stop`（`C-c C-c`）停止正在运行的 `run`、`shell`/`pipe` 和项目搜索。每个外部命令在自己的进程组中运行，停止时整个进程组收到 SIGTERM。被停止的 `shell` 报告 `was stopped`，被停止的 `run` 不再写入输出；没有任务时不显示消息。退出编辑器不等待也不终止仍在运行的命令。

### 消息

消息行一次显示一条消息。Runtime 在每次输入、命令或后台完成之后把新消息记入日志，连续重复的只记一次，最多 1,000 条。`messages` 在 scratch 文档 `*messages*`（默认底部 12 行）中显示日志，光标放在最新一条；打开期间新消息追加到末尾。

### 内置命令

完整列表在 `registry.rs` 的 `BUILTINS`，帮助和 `M-x` 候选附带每条命令的说明。本文其他章节描述的命令（离开文档、外部进程、搜索、结果、高亮、行标记、跳转等）不再重复：

| 命令 | 行为 |
| --- | --- |
| `edit [PATH]`、`open PATH`、`new` | 打开文件（`edit` 无参数时重新加载）；新文件在保存时创建；新建无标题文档 |
| `write [PATH]`、`saveas PATH`、`write-quit` | 保存、另存为、保存后退出 |
| `buffer NAME`、`recent FILE`、`project FILE`、`project-switch DIR`、`project-root [DIR]` | 切换文档、打开最近或项目中的文件、选一个项目再打开其中的文件、查看或指定项目 |
| `next-view` | 在当前窗口显示下一个视图，跳过其他窗口中的视图 |
| `split [PATH]` / `vsplit [PATH]` | 上下 / 左右分屏，新窗口复制当前视图或打开 PATH |
| `close-window` / `only` | 关闭当前窗口（视图保留为隐藏）/ 只留当前窗口 |
| `window-left`、`-right`、`-up`、`-down`、`window-next`、`window-previous` | 切换窗口 |
| `resize-window [wider\|narrower\|taller\|shorter\|reset [CELLS]]` | 调整当前窗口，默认 1 格；无参数时进入逐步调整模式 |
| `display KIND PLACEMENT` | 某种文档的显示位置，见[终端界面](ui.md#窗口) |
| `goto LINE[:COLUMN]` | 跳到行列，从 1 开始，列为逻辑列，越界时限制到文档或行尾 |
| `page-down` / `page-up`、`half-page-down` / `half-page-up`、`recenter` | 翻页（一个视口减一行，保留逻辑列）、翻半页、居中 |
| `set` / `set-local` / `unset-local`、`face`、`language-map`、`hook` / `unhook` | 见[扩展模型](extension.md#选项)与[钩子](extension.md#钩子) |
| `lua CODE`、`lua-call ID [ARG]`、`choose`、`answer` | 执行 Lua、调用 Lua 注册的函数、回答 Lua 扩展的提问 |
| `snippet BODY` | 展开 snippet，见[补全](completion.md#snippet) |
| `echo [TEXT]` | 在消息行显示文字，常与 `%val{}` 合用 |
| `commands`、`help`、`suspend`、`nop` | 命令面板、帮助、挂起、什么也不做（屏蔽默认键） |
| `undo` / `redo`、`copy` / `cut` / `paste` / `yank-pop` | 历史与剪贴板 |
| `move-up` / `move-down`、`document-start` / `document-end`、`select-all`、`normal-mode` | 移动、全选、切换模式；`extend-` 前缀扩展选区 |
| `indent` / `outdent`、`indent-for-tab`、`insert-tab` / `insert-literal-tab`、`newline` | 缩进、Tab、语言感知换行 |

Normal 的模态命令（`left`、`next-word`、`block`、`kill`、`put`、`grab`、`expand N`、`keypad START` 等）对应 [Normal 键](#normal-键)。相对路径以当前文档的目录解析，支持 `~/`。

### 帮助

`F1` 打开只读帮助页，可滚动浏览，F1、Enter 或 Esc 返回。帮助页由当前键位表生成：模态键的固定说明，然后按上下文列出键、命令名和说明，包括用户绑定。`soda --help` 输出默认键位生成的同一份内容。

## 命令行

命令行是一个单行输入加一个候选列表，承担 M-x 式命令面板、打开文件、另存为、跳转和缓冲区切换。入口只是预填不同的文字：`M-x` 预填空串，`open` 预填 `open `，`project` 预填 `project `，`buffer` 预填 `buffer `。

体验取自 Emacs 的 vertico，但不嵌套、不转移焦点：一行文字就是一条命令，补全只帮助写出这行文字。

### 状态与参数位

会话状态只有输入文字、光标和候选选择；命令名、参数位以及光标所在的参数位每次按键后从文字重新解析。焦点始终在输入框，上下键只移动选中项。命令行不嵌套。

命令声明参数位序列，每个参数位有名字、类型和是否必需。中间的参数位各是一个空白分隔的词，最后一个取剩余的整行（可含空格）。命令行不解释引号。

| 类型 | 候选 | 需要匹配 | 例 |
| --- | --- | --- | --- |
| 命令名 | 命令表中的名字与说明 | 是 | 第一个词 |
| `Path` | 目录项 | 否，可输入新文件名 | `edit`、`open`、`write`、`saveas` |
| `File` | 项目文件 | 是 | `project` |
| `Recent` | 最近用过的文件 | 是 | `recent` |
| `Project` | 记住的项目 | 否，可输入目录 | `project-switch` |
| `Buffer` | 已打开的文档 | 是 | `buffer` |
| `CurrentBuffer` | 已打开的文档，初始选中当前文档，回车即取它 | 是 | `kill-buffer` |
| `Symbol` | 当前文档的符号 | 否 | `visit` |
| `Choice` | 命令声明的固定词及说明，可带单键 | 是 | `map` 的 MODE，`close`、`reload`、`quit` 的 DECISION |
| `Option`、`Face`、`Language` | 选项名、face 名、语言 id | 是 | `set`、`face`、`language-map` |
| `Item` | Lua 扩展提问的选项 | 是 | `choose` |
| `Word`、`Rest` | 无 | 否 | 其余参数 |

`Choice` 的词可以声明一个键：参数位为空、且命令行是编辑器发出的提问（带 `[unsaved …]` 这类说明）时，按这个键直接选中该词并按回车处理。自己输入的 `:quit s` 中 `s` 只是文字。DECISION 声明 `s`（save）和 `d`（discard）。

候选包含展示文字、替换文字、匹配到的字符范围和说明文字的起点；面板高亮匹配字符，说明用暗色。

| 候选 | 匹配方式 | 排序 |
| --- | --- | --- |
| 命令名 | 名字模糊匹配；都不匹配时按说明的子串匹配 | 名字完全相同的最前，然后按得分，同分时较近执行过的在前，再按命令表顺序，说明匹配最后 |
| 缓冲区 | 显示名模糊匹配 | 按得分，同分时当前文档在后 |
| 项目文件 | 路径模糊匹配 | 按得分，同分时较近选过的文件在前 |
| 最近文件、记住的项目 | 路径模糊匹配 | 按得分，同分时较近用过的在前 |
| 目录项 | orderless：空格分开的每个词都出现在文件名中，位置和顺序不限 | 与输入同名的最前，其次是这个名字的目录；然后以输入开头的在前，再是较近选过的，最后按目录顺序，目录优先；目录按其下最近选过的文件算，当前文件不算 |
| 符号 | 模糊匹配 | 按得分，同分时离光标近的在前；不看历史，同 `consult-imenu` 保持文档顺序 |
| `Choice` | 前缀匹配 | 声明顺序 |
| 选项、face、主题、语言、键位表 | 前缀匹配 | 与输入同名的最前，然后较近选过的在前，其余按声明顺序 |

“较近选过”取自参数位的[历史](#历史与持久状态)，与 Emacs 的 `minibuffer-sort-by-history`、vertico 的默认排序一致，但有得分的列表先比得分：没有输入时历史项排在最前，有输入时历史只决定同分的顺序。缓冲区、最近文件和记住的项目本身就按使用顺序排，不再叠加历史。排序之后，与输入完全相同的候选移到第一行，与 vertico 一样（命令名、目录项见上表，`Item` 只比展示文字，不比序号）。目录项与 vertico 的 `vertico-sort--history` 相同：`file` 历史中在这个目录下的条目只取下一层，所以选过 `~/.config/soda/init.lua` 之后，在 `~/` 下 `.config/` 排在前面；当前文档的文件不计，否则它总是第一个。

模糊匹配使用 nucleo；所有匹配都是 smart case：全小写时不区分大小写，含大写时区分。命令名、缓冲区、枚举的补全同步计算；目录读取和项目文件匹配在后台执行，结果携带请求身份，过期结果丢弃。光标移到别的参数位时候选随之切换。

### 按键

| 输入 | 行为 |
| --- | --- |
| 输入文字、粘贴、删除 | 编辑输入并刷新当前参数位的候选 |
| 上下键、`C-p` / `C-n` | 移动选中项，不改写输入；越过两端时绕回（`vertico-cycle`），可以选中输入框时经过它 |
| PageUp / PageDown、`C-v` / `M-v`、`M-<` / `M->`、`C-Up` / `C-Down` | 翻页、到第一行 / 最后一行；在第一行上再按 `M-<` 到输入框 |
| `M-p` / `M-n` | 翻光标所在参数位的历史，见下文；搜索输入框没有候选，上下键也翻历史 |
| Tab / Shift-Tab | 用选中项替换当前参数位，选中输入框时用第一行（`vertico-insert`）；目录候选留在该参数位并列出下一层，其他候选在后面还有参数位时追加空格 |
| Enter | 取选中的，见下文 |
| `M-RET` | 不管选中哪一行，按输入的文字确认（`confirm-input`，同 `vertico-exit-input`） |
| Backspace、`M-DEL` | `Path` 参数位光标前是 `/` 时删除前面一层目录（`vertico-directory-up`）；`~/` 先展开成 HOME，所以删到 HOME 的上一层。前面没有目录时照常删除 |
| Esc、`C-c`、`C-g` | 关闭，不执行 |

选中项按 vertico 的模型：输入框本身是列表头上的一个位置，Enter 取当前选中的；选中输入框时 Enter 按输入的文字确认，这时输入框高亮，计数显示 `*/N`。

- **能否选中输入框**：参数位不要求匹配时可以（`Path`、`Project`、符号、自由参数）。命令名和要求匹配的参数位不行；那里输入恰好是某个候选时，它已经因为“同名的排第一”成为第一行。
- **默认选中**（`vertico-preselect` 取 `directory`）：第一行；但 `Path` 的文字是目录（`/` 后面还没输入）时选中输入框，`Project` 的文字以 `/`、`~`、`.` 开头时也是；主题列表在当前主题上，`kill-buffer` 在当前缓冲区上。所以 `cc` 回车打开第一行（如 `cc.txt`），要新建 `cc` 用 `M-RET`，或 `C-p` 回到输入框再回车；没有候选时 Enter 就用输入的文字。
- **锁定**（`vertico--lock-candidate`）：用户移动过的选中项，在继续输入时只要还在结果里就保持选中，选中的输入框也保持；它从结果里消失、或者换了参数位或目录时，回到默认选中。

Enter 依次处理：

1. 选中的是候选时用它替换参数位，是目录时进入该目录，不执行。选中输入框时，要求匹配的参数位里文字必须等于某个候选。候选还在等后台结果时不能取。
2. 还有必需的参数位未填写时追加空格继续输入，不执行。命令面板因此是“选中命令，接着写参数”的连续流程。
3. 解析整行。参数错误时错误显示在命令行中并保持打开；成功则关闭并执行。`Path` 的文字以 `/` 结尾时继续浏览，不执行。

### 历史与持久状态

历史按 Emacs 的方式组织：每份历史有名字，相当于 `completing-read` 的 HIST 参数指定的历史变量；同一类东西不论哪个命令都共用一份。代码在 `interaction/history.rs`。

| 历史 | 内容 | 对应 Emacs |
| --- | --- | --- |
| `command` | 成功执行的整行 | `command-history` |
| `extended-command` | 执行过的命令名，只用于命令名的排序 | `extended-command-history` |
| `search` | 搜索 | `regexp-search-ring` |
| `file` | `Path`、`File`、`Recent` 参数位取的文件，以及启动时命令行给的文件；绝对路径，在 HOME 下的写成 `~/…` | `file-name-history` |
| `buffer`、`project` | 缓冲区名、项目目录 | `buffer-name-history`、`project--dir-history` |
| `symbol`、`option`、`face`、`theme`、`language`、`keymap` | 对应参数位取的名字 | `imenu--history-list` 等 |
| 命令名，如 `goto`、`grep`、`shell` | 这个命令的自由参数（`Word`、`Rest`）；命令有几个自由参数时为 `命令-参数名`，如 `map-keys`；`pipe` 与 `shell` 共用 | `goto-line-history`、`shell-command-history` |

规则：

- **记录**：一行通过检查、关闭并执行时，整行进 `command`，命令名进 `extended-command`，每个有历史的参数位把最终的值进各自的历史；含 `%val{…}` 这类展开的路径参数不记。空白不记，重复的移到最新，每份最多 100 条（`history-length`）。`Choice` 参数位和回答提问的行不记，Lua 提问指定了历史时除外，见[扩展模型](extension.md)。
- **翻历史**：`M-p` / `M-n` 只替换光标所在参数位的文字，取这个参数位的历史，所以 `C-x b M-p` 得到上一次切换到的缓冲区，`M-g g M-p` 得到上一次去的行。光标在命令名上或参数位没有历史时翻整行（`command`）。文件写入参数位时换成那里候选的写法：`File`、`Recent` 中项目里的文件写成相对路径，`File` 跳过别的项目的文件；`Path` 写完整路径。
- **翻历史的状态属于输入框**，与 Emacs 把 `minibuffer-history-position` 放在 minibuffer 里一样：往回翻时先保存正在输入的文字，翻过最新一条后恢复；编辑了历史项之后再翻，编辑后的文字成为新的草稿。一次翻动停在原来的范围上，直到编辑文字，所以翻出的整行即使把光标留在某个参数里，继续翻的仍是整行；光标移到别的参数位后从头开始。

退出时，前端把各份历史和最近 200 个文件的光标位置写入 `$XDG_STATE_HOME/soda/state`（未设置时为 `~/.local/state/soda/state`），下次启动时在 `init.lua` 之后、第一个文档之前读回。每行一条制表符分隔的记录，历史是 `history 名字 条目`，从旧到新；旧版本的 `command`、`search` 记录读作同名历史。先写临时文件再替换，损坏的行被忽略。写入前读一遍文件：启动之后它被别的 soda 改过时，按 savehist 的 `savehist--merge` 合并两边的历史，从最新一条起交错、各保留最新的位置，所以同时开着的几个实例谁后退出都不丢别人的历史；文件位置和项目列表不合并，以后退出的为准。不像 savehist 那样定时保存，panic 时也不写。之后打开同一路径且没有指定位置（不是 `jump`、`goto` 打开的）时回到记下的行列。寄存器、标记和窗口布局不保留。无头 Runtime 不读写这个文件，由 `host` 在启动和退出时调用 `restore` 和 `persist`。

### 异常退出与挂起

主循环提前结束（panic、终端读写出错、SIGHUP、SIGTERM）时，前端先恢复终端，再由 `host` 把每个未保存文档写入状态目录下的 `recovery/`（不可用时用系统临时目录），文件名是 `时间戳-缓冲区名`（`/` 和空白换成 `%`），并在标准错误中给出目录。panic 的报告在终端恢复后输出，之后不写状态文件。

`suspend`（`C-z`）先把终端恢复成 shell 的状态，再向自己发送 SIGTSTP；`fg` 继续后重新接管终端并重画。

### 缺参数的命令与多步交互

执行时缺少必需参数的命令不报错，而是打开预填 `命令名 ` 的命令行，相当于 Emacs 的 `interactive`。所以绑定 `open`、`project`、`buffer`、`goto` 直接得到对应的交互入口；`saveas` 预填当前文件路径，`open` 预填当前文档的目录。

多步交互由命令行串联：一条命令打开下一条预填好的命令行，步骤之间的状态写在命令文字里；命令行可以带一条不参与解析的说明（如 `[unsaved src/a.cpp] :close `）。关闭命令行会取消它的后台补全任务。

### 路径、文件与缓冲区补全

- **目录**：相对路径以当前文档的目录为基准，`~/` 使用 HOME。每个目录读取一次并缓存，目录部分变化时才重新读取。列表包含隐藏项，不列 `./`、`../`（同 Emacs 的 `completion-pcm--filename-try-filter`），手写的 `..` 照常解析；支持目录符号链接。在路径末尾输入 `//` 或 `/~` 时，前面的部分作废并删去，路径从根目录或 HOME 重新开始（file-name-shadow 加 `vertico-directory-tidy`）。读取由 `files::paths` 在后台执行，单个目录最多 10,000 项；含控制字符的文件名只展示，不能填入。补全不写磁盘，打开不存在的文件建立命名缓冲区，保存时才创建。
- **项目文件**：使用下文 [Picker 后台引擎](#picker-后台引擎)，查询就是参数位文字；候选集在进入该参数位时建立，同一命令行内复用。
- **最近文件**：最新的在前，路径相对项目根目录显示。文件在打开和关闭时成为最新；列表就是持久状态中那 200 个文件，跨会话保留（同 Emacs 的 recentf）。
- **缓冲区**：每个已加载文档一项，包括没有视图的。命名文档显示完整路径，未命名文档为 `[untitled N]`；`*` 标记当前文档，`[+]` 标记未保存。按最近使用排序，同 Emacs 的 `other-buffer`：当前文档之前最后用的排第一，所以 `C-x b RET` 在两个文档间来回切；没显示过的文档随后，当前文档最后。使用顺序记在文档上，关掉视图后仍保留。`buffer NAME` 复用已有视图，没有时创建。

## 文档的位置

每个文档有两个位置，不依赖启动编辑器时的工作目录（`application/context.rs`）：

- **目录**：手工输入的相对路径以它为基准，用于 `open`、`saveas`、路径补全、`shell` 和 `pipe`。文件文档是所在目录；无标题文档和 scratch 文档继承创建时的当前文档；结果文档是生成它的根目录。
- **项目**：覆盖整个项目的工具的范围，用于项目文件、`grep`、`run`、`recent`、状态栏路径、`%val{root}` 和 `soda.spawn`；没有项目时用目录。

项目在文档得到路径时确定，参照 Emacs 的 `project.el`：从文件所在目录向上找 `.git`、`.jj`、`.hg`、`.svn`，或用 `project-root`、`soda DIR` 指定过的目录，取最近的一个。

- `$HOME` 和 `/` 不因为标记成为项目。
- git submodule（`.git` 文件指向 `modules/`）属于外层仓库；linked worktree 自成项目。
- 文件打开后才创建的标记（比如之后才 `git init`），要重新打开文档或用 `project-root` 才生效。
- 没有项目的文件若是通过跳转打开的（结果列表、`soda.open`），继承来源文档的项目，所以从项目跳进系统头文件后，`grep` 和项目文件仍在原项目。直接打开的文件没有项目。

**记住的项目**：同 `project.el` 的项目列表，文件打开时它的项目成为最新的一个，最多 100 个，跨会话保留，已不存在的目录不列出。`project`（`C-x p f`）在活动文档有项目时直接列出项目文件；没有项目时（比如在 `$HOME` 下）先问项目，即 `project-switch`，而不是列出整个目录。`project-switch`（`C-x p p`）的候选显示成 `~/project/flowmq/` 这样；回车取高亮的项目，输入以 `/`、`~`、`.` 开头时取输入的目录，没有标记的目录从此也算项目。选定后命令行换成那个项目的 `project`，打开的文件属于它，与活动文档的项目无关。

启动目录只用于解析命令行上的路径，以及作为不带文件启动时第一个文档的目录。`soda DIR` 把 `DIR` 当作项目，不论有没有标记。

## 关闭、退出与重新加载

`close` 关闭当前文档，`quit` 退出，`reload`（或无参数的 `edit`）从磁盘重新加载。三者都带可选参数 `DECISION [PATH]`：`DECISION` 为 `save` 或 `discard`，`PATH` 只跟在 `save` 后面，未命名文档保存到这里，有路径的文档改存到这里。干净文档直接执行；未保存文档按决定执行，没有决定时打开命令行询问：

```
[unsaved src/a.cpp] :close 
  save         [s] Save first, then continue; Tab, then PATH, saves elsewhere
  discard      [d] Discard the unsaved changes
```

1. `d`（或输入 `discard` 回车）得到 `close discard`，立即丢弃并关闭；`reload discard` 明确授权用磁盘内容替换本地内容。
2. `s` 或空输入回车得到 `close save`。未命名文档继续打开 `[… needs a PATH] :close save `，在 PATH 参数位补全目录。想存到别处时按 Tab 得到 `close save ` 并停在 PATH 参数位。
3. 有路径时请求保存并进入等待层（`Saving …; Esc cancels close`）。保存成功后再执行一次 `close`：文档已经干净则关闭，保存期间有新编辑则再次询问。
4. 保存失败（写入失败、磁盘内容已变化、路径预检失败、请求被取消）时打开 `[save failed: …] :close save PATH`，可以修改后重试或 Esc 放弃。

`kill-buffer [NAME]` 同 Emacs 的 `kill-buffer`（`C-x k`）：不带参数时打开命令行，列出已打开的文档，初始选中当前文档，直接回车关闭当前文档，选别的则关闭那一个，当前窗口不动。所选文档有未保存修改时先把它显示出来，再按上面的 `close` 流程询问，决定在能看到内容的地方做。

等待层只采用带自己 Operation 身份的保存结果。等待期间 Esc 只取消离开流程，已提交的保存继续完成。已有保存任务时不启动新的关闭、重新加载或退出；未命名文档不能重新加载。

`quit` 每次询问一个未保存的文档（先当前文档，再其他的，包括没有视图的），`quit discard` 和成功的 `quit save` 之后再次执行 `quit`，直到没有未保存文档和待处理的保存。中途取消时，已丢弃的不恢复，已保存的仍有效。`write-quit` 只自动保存当前文档。

### 保存时整理空白

保存前，Application 按文档的选项整理一次，作为单独的一步撤销，写入的就是整理后的文本：

- `trim-trailing-whitespace`：去掉自加载或上次保存以来编辑过的行的行尾空格和制表符，与 ws-butler 相同，没动过的行保持原样。编辑过的范围随之后的编辑映射，重新加载时清空。
- `final-newline`：有内容但不以换行结尾时补一个换行，换行符跟随第一行（CRLF 文件补 `\r\n`）。光标在文件末尾时留在新换行之前。
- 保存会被拒绝时（正在保存、没有路径、路径被占用）不整理。scratch 文档不保存，也不记录编辑范围。

### 磁盘上的变化

终端重新获得焦点时（以及 `check-files`），逐个比较打开的文件与加载或保存时的磁盘内容：

- 内容变了、文档没有未保存的编辑、`auto-reload` 为 true（默认）时直接重新加载，光标和撤销历史保留。
- 文档有未保存的编辑或 `auto-reload` 为 false 时，只报告 `PATH changed on disk`；之后可以 `reload discard` 采用磁盘内容，或者保存（会因内容冲突失败，需要先决定）。
- 文件被删除时报告 `PATH was deleted`，文档不变。
- 没有变化时不改变消息行。正在保存的文档跳过。比较读取整个文件，只在这些时机进行，不监视文件系统。

## 只读文档

scratch 文档只由编辑器写入：grep、run、`soda.results` 的结果，树，`*messages*`，都对应 Emacs 的 special buffer，是只读的。会改文本的编辑（输入、删除、剪切、粘贴、撤销、替换、缩进，以及 Lua 的 `buf:edit`）在 `Application` 的入口被拒绝，报 `Buffer is read-only: NAME`；移动、选择、复制照常。编辑器自己的写入（`Event::Scratch`、`AppendScratch`）不经过这道检查。结果文档里 Enter 是 `jump`（`results` 表）。

## 项目搜索

`grep PATTERN` 在后台线程中搜索项目：

- **范围**：遵守 `.gitignore` 等忽略规则，跳过隐藏文件、二进制文件和非 UTF-8 文件。
- **匹配**：正则表达式，模式中没有大写字母时忽略大小写。
- **顺序和上限**：文件按名字排序，结果顺序稳定。最多 10,000 个匹配；单行结果超过 400 字节时截断。
- **新搜索**：取消还没完成的上一次。

结果写入 scratch 文档 `*grep*`，按文件分组：文件名单独一行（相对项目根目录），下面每行一个匹配 `  行:列  文本`，行号右对齐，列是从 1 开始的字节列，文本去掉行首缩进，文件之间空一行。文件名、行列和匹配文本分别着色，匹配高亮只作用于文本部分。结果文档（`*run*` 除外）默认 `line-numbers` 为 `off`。scratch 文档永远不算未保存，关闭时不询问；再次搜索替换内容并把光标和视口放回开头；没有匹配时只显示消息。

打开结果位置：

- Normal 的 Enter 执行 `jump`：当前行是位置行时打开该位置；在文件名行上时移到下面第一个结果并打开；否则移到下一行首个非空白字符。
- `M-g n` / `M-g p`（`next-result` / `previous-result`）在最近一次 `grep`、`run` 或扩展（`soda.results`）的结果文档中移动光标并打开对应位置。结果刚生成时，第一次 `next-result` 打开第一个结果。
- 位置行有两种格式。`路径:行:列:` 或 `路径:行:` 是编译器常见的格式，列缺省为 1，路径不能含空白。分组格式是缩进的 `行:列  文本`，路径取上方最近的非缩进行，可以含空白；`*run*` 和普通文档不认分组格式。相对路径以结果文档的目录为基准。
- 打开位置使用 `OpenAt` 事件：文件还没加载时，行列随打开请求保存，加载完成后再放置光标。

## 剪贴板

Application 拥有一个跨文档共享的剪贴板，它是 Emacs 式的 kill ring：每次复制、剪切或从系统剪贴板读回新内容加一条，最新一条就是剪贴板，最多 120 条，与最新一条相同的文字不重复加入。`copy`、`cut` 有选区时作用于选区，否则作用于光标所在整行（保留原换行字节）；`kill-line-*`、`kill-word-*` 总是从光标剪到行尾、行首或词边界。剪切在事务成功后才替换剪贴板。粘贴是一次独立的可撤销编辑；撤销不改变剪贴板。

- **连续剪切合并**：文档自上次剪切后没变、光标还在上次剪切留下的位置、这次剪掉的范围一端正在那里时，并进最新一条：向后剪接在后面，向前剪（`kill-line-start`、`kill-word-backward`）放在前面。所以 `C-k C-k` 剪掉一行连同换行是一条。判断看状态而不是上一个按键，宏和 Lua 的 `buf:kill` 也一样（`pairs` 模块用它）；复制或读回系统剪贴板之后不再合并。
- **`yank-pop`（`M-y`）**：粘贴之后、文档和光标都没动过时，把刚粘贴的文字换成更早的一条，再按继续往前，过了最旧的回到最新的；否则报告 the last command was not a yank。它不改变剪贴板。

选项 `clipboard` 为 `system`（默认）时，Runtime 通过前端提供的 `SystemClipboard` 与系统剪贴板同步：每次归约后剪贴板版本号变了就写出；粘贴事件执行前先读取，内容与应用剪贴板不同时加入 kill ring，读回的内容不再写出。`internal` 只用应用剪贴板。

终端前端按环境选择实现（图形前端直接用窗口系统的剪贴板，见[图形界面](gui.md#输入)）：

- 本机有图形会话时用剪贴板工具：Wayland 用 `wl-copy`、`wl-paste`，X11 用 `xclip` 或 `xsel`，macOS 用 `pbcopy`、`pbpaste`。
- 通过 SSH 登录或没有这些工具时，复制以 OSC 52 写给终端，粘贴只用应用剪贴板。tmux 中需要 `set -g set-clipboard on`。
- 写入在后台线程完成；读取最多等 500 ms，超时改用应用剪贴板。

## 鼠标

前端把鼠标位置换算成当前视图中的字节偏移，以 `UserInput::Pointer` 交给交互层，屏幕坐标不进入交互层。

- **单击**：放置光标；点在其他窗口时聚焦那个窗口。
- **拖动**：从按下处选到当前位置，模式不变。拖到文本区上下边缘之外时选区继续延伸，视口跟随。
- **滚轮**：每格滚动 `scroll-lines` 行（默认 3），最后一行最多滚到顶部。光标离开可见区时移到最近的可见行，保持列；有选区时移动的是选区头。
- **标签栏**：单击切换到该文档，同 `buffer`。
- **窗口边**：拖动分隔线调整窗口大小。
- 有模态层（命令行、搜索、帮助等）时，编辑区不响应鼠标。

选项 `mouse` 为 false 时不捕获鼠标，终端自身的文本选择可用；捕获时通常要按住 Shift 才能用终端选择。

## 高亮模式

`highlight FACE PATTERN` 在所有文档中高亮正则表达式的每处匹配，`highlight-local` 只作用于当前文档，与 kakoune 的 regex highlighter 相同。高亮只在绘制可见行时匹配，不改变文本或语法分类，叠加在语法颜色之上，重叠时后开始的匹配优先。

- **外观**：`todo`（加粗黄色）、`error`（红色）、`info`（蓝色）、`mark1` 到 `mark8`（八种背景色）；`mark` 依次取下一种背景色。
- **替换与删除**：同一模式再次添加时替换外观。`unhighlight PATTERN` 从当前文档和全局中去掉这个模式，不带参数时去掉全部；没有可去掉的高亮时报错。文档关闭时它的高亮一并删除。
- **配置**：`init.lua` 中用 `soda.command("highlight todo \\b(TODO|FIXME|XXX)\\b")`；`highlight-local` 需要文档，只能在命令行、键位或钩子中使用。

插件 `symbol-overlay` 用同一原语标记符号，对应 Emacs 的同名包。`symbol-toggle` 标记光标处的符号，每个符号取一种没在用的颜色（共 8 种），再执行一次取消；`symbol-clear` 去掉当前文档的标记；`symbol-switch-forward` / `symbol-switch-backward` 到最近的另一个已标记符号。这些命令与 Emacs 一样没有键，由用户绑定。标记属于文档，不跨文档。

`setup()` 之后，光标在标记上时键位表 `mark` 优先于 Normal，不是模态编辑时优先于 Insert，与 Emacs 的 overlay keymap 一样（数字前缀、多键序列进行到一半时除外），离开标记恢复原义；`mark-keys` 选项关掉它：

| 键 | 命令 | 作用 |
| --- | --- | --- |
| `i` | `symbol-toggle` | 取消标记 |
| `n` / `p` | `symbol-jump-next` / `symbol-jump-prev` | 下一处 / 上一处，到头回绕，保持光标在符号内的位置 |
| `<` / `>` | `symbol-jump-first` / `symbol-jump-last` | 第一处 / 最后一处 |
| `w` | `symbol-save` | 复制符号 |
| `e` | `symbol-echo-mark` | 回到上次跳转之前的位置 |
| `d` | `lsp-definition` | 到定义 |
| `s` | `symbol-search` | 以符号为查询打开搜索 |
| `q` | `symbol-query-replace` | 以符号为查询打开替换 |
| `r` | `symbol-rename [NAME]` | 重命名当前文档中所有出现处，一步撤销 |
| `h` | `symbol-help` | 列出这些键 |

这与 Emacs 一致：symbol-overlay 的键表挂在 overlay 上，排在 meow 之前。整张表不要时 `set mark-keys false`（对应 `symbol-overlay-inhibit-map`），也可以 `set-local` 只对某个文档关掉；去掉个别键用 `unmap mark h`，改绑用 `map mark KEY COMMAND`。跳转后行尾显示位置（如 `[3/12]`），下一个键清除；Lua 用 `soda.indicator(line, text)` 显示同样的提示。

与 Emacs 的差别：没有 `t`（限定在函数内）和自动高亮；`s`、`q` 按字面子串匹配，只有 `r` 和跳转按整个符号算。

## 对每行或每处匹配输入按键

`each-line KEYS` 和 `each-match PATTERN KEYS` 对应 meow 的 `meow-kmacro-lines` / `meow-kmacro-matches`，在很多场合可以代替多光标。

- **范围**：选区覆盖的行；没有选区时，`each-line` 只作用于光标所在行，`each-match` 作用于整个文档。
- **执行**：KEYS 用按键记法书写，如 `each-line i# ESC`、`each-match foo wsbar ESC`。每个目标先回到 Normal，光标放在行首或匹配开头，再像键入一样回放 KEYS。目标从下往上处理，修改不会移动上方的目标。
- **撤销**：全部修改合并为一步。
- **失败**：某个目标上的按键失败时只放弃这个目标剩下的按键。最多处理 10,000 个目标。

## 行标记

`flag-lines GROUP FACE SIGN LINES` 在当前文档行号栏的第一格画出 SIGN，与 kakoune 的 flag-lines 相同。它是给扩展用的原语：版本控制标记（`git-flags` 模块）、构建错误、书签都由配置或外部命令生成这条命令。

- **参数**：GROUP 是不含空白的组名；FACE 是 `todo`、`error`、`info` 或 `mark1` 到 `mark8`；SIGN 是一个单宽字符，如 `+`、`~`、`●`；LINES 是从 1 开始的行号或 `3-7` 这样的范围，用空格分隔，超过文档末尾的被忽略。可以使用展开：`flag-lines bookmark mark1 ● %val{line}`。
- **分组**：同一组可以多次添加。`unflag-lines GROUP` 去掉这一组，不带参数时去掉当前文档的全部标记；没有可去掉的标记时报错。一行有多组标记时显示后添加的。
- **随编辑移动**：标记保存为行首的文档位置。在行首插入的文字把标记连同这一行推下去；整行被删除时，标记留给顶替它的下一行。文档关闭时标记一并删除。
- **显示**：占行号栏的第一格，软换行的续行不显示。关掉行号时，只要文档有标记就留出两格宽的标记栏。

## 屏幕标签跳转

`jump-to` 对应 avy 的 `avy-goto-char-2`：先输入两个字符，所有窗口可见行中的每处出现都标上标签，再输入标签跳过去；目标在别的窗口时焦点随之移动。

- 查询全小写时不区分大小写，含大写时精确匹配。
- 当前窗口的目标排在最前，其余按布局顺序。标签按 `asdfghjkl` 主行优先；超过 26 处时全部用两个字母，标签之间没有前缀关系。只有一处时直接跳，没有时提示 `No XX on screen`。
- 已输入的标签字母可以退格；Esc 取消；文本、窗口或焦点变化时标签关闭。
- 只看窗口可见的行；水平滚出窗口的位置也分到标签，但不显示。

`window-pick` 对应 ace-window：每个窗口左上角显示一个标签，输入后聚焦那个窗口；只有两个窗口时直接切到另一个。

`resize-window` 不带参数时进入 kitty 式的调整模式（`Layer::Resize`，状态栏显示 RESIZE）：`w` 加宽、`n` 变窄、`t` 加高、`s` 变矮，每步 2 列或 1 行，按住 Ctrl 加倍；`r` 让所有分屏恢复等分、侧边窗口恢复打开时的大小；Esc、Enter、`q`、`C-g` 退出。消息行显示当前窗口现在和进入模式时的行列数。模式直接读按键，不经过输入框键位。焦点换到别的窗口或窗口关闭时模式结束。

标签由 `Layer::Labels` 持有，前端用 `cell_of` 把文档位置换算成窗口内的格子再绘制。

## 跳转历史

`C-o`（`jump-back`）回到跳转之前的位置，`C-i`（`jump-forward`）再前进；`M-,` / `C-M-,` 相同。整个会话共用一个列表，像浏览器的后退：后退之后再跳到别处，前方的记录被丢弃。

- **记录什么**：离开的位置。切换文档一定记录，不论是打开文件、切换缓冲区或窗口还是 `soda.open`。同一文档内只有这些记录：`o`/`O` 的分组选择、`goto`、`M-<`/`M->`、确认的搜索、`n` 与 `v`、`jump-to`、打开结果，以及 Lua 声明为跳转的移动。没有实际移动时不记录。
- **结果文档**：`*grep*` 这类 scratch 文档不是历史中的一站，记录的是进入结果之前所在的文件位置。
- **连续走结果**：连续用 Enter 或 `M-g n`/`M-g p` 走同一份结果只算一次，一次 `C-o` 就回到开始看结果之前的地方。其他跳转或新的结果结束这一段。
- **位置跟随编辑**；文档关闭时，它的位置从列表删除。
- **去重**：相邻两项在同一文档的同一行时只留一个，最多 100 项，不跨会话保存。
- 传统终端发送的 `C-i` 就是 Tab，所以 Normal 的 Tab 也绑定为 `jump-forward`。

## 搜索与替换

`C-s` / `C-r`（`search` / `search-backward`）打开向前 / 向后搜索，Insert 中也可用。查询是 smart case 的正则表达式；输入时实时预览当前匹配并显示数量；`C-s` / `C-r`、`F3` / `Shift-F3` 走到下一处 / 上一处；Enter 确认，Esc 取消并恢复原选区与视口。确认后查询成为 Normal `n` 使用的当前搜索。

`SearchSession` 绑定一个视图，保存原选区、原视口、查询和结果。查询变化时从会话开始时的光标位置搜索；前后导航从当前匹配继续并环绕。结果只保存文档版本、匹配数量和当前范围，复用核心的正则搜索，不保存匹配列表。

匹配不跨行，`^`、`$` 对着一行的首尾。为了每输入一个字都能数完大文件，核心在整段文本上一次搜索（`^`、`$` 在行首尾成立），只有跑过行尾的匹配所在那一行单独重扫，所以结果与逐行搜索相同；含 `\A`、`\z` 的模式和含孤立 `\r` 的文档仍逐行搜索。2.6 MB、6.5 万行的 C++ 文件上数完一个常见词约 0.2 ms，单个字母（17 万处）约 4 ms，原先每次约 30 ms。预览通过 `SetSelection` 显示当前匹配；空查询或没有匹配时恢复原选区与视口。搜索不修改文本，不产生撤销记录。

原选区与视口用 `DocumentPosition` 保存，随 `Layers::observe` 收到的每个更新映射，包括其他视图对同一文档的编辑；文档修改后重新计算匹配。缺失更新导致过期版本错误，不会把旧坐标用到新文本。视图关闭时搜索结束；焦点切换时取消并恢复原视图状态。

`replace`（`M-%`、Normal `R`）建立绑定当前视图的替换会话，复用 `SearchSession` 的预览、映射与取消恢复。依次输入查询、替换文字（可为空），然后进入确认阶段。替换文字可以用 `$1`、`${name}` 引用分组，`$0` 是整个匹配，`$$` 是字面的 `$`。确认阶段同 Emacs 的 `query-replace`，在每处匹配询问：

| 键 | 作用 |
| --- | --- |
| `y`、`SPC` | 替换这一处，到下一处 |
| `n`、`DEL` | 跳过这一处，到下一处 |
| `!` | 替换这一处和之后的所有匹配，结束 |
| `.` | 替换这一处，结束 |
| `q`、`RET` | 结束 |
| `F4`、`C-Enter` | 替换文档中的所有匹配，结束 |
| `C-s` / `C-r`、`F3` / `Shift-F3` | 选择后 / 前一处，环绕 |

下一处从替换进去的文字之后找，所以把 `a` 换成 `aa` 不会再问到新文字；越过最后一处时结束，不环绕（同 Emacs 停在缓冲区末尾）。结束时消息行报告替换了几处。每处替换是一个可撤销事务，`!` 和 `F4` 各是一个。查询和替换文字阶段取消恢复进入前的选区与视口；确认阶段已经替换过时，Esc 与 `q` 一样结束并保留已做的替换，光标留在停下的位置，还没替换时恢复原状。

## Picker 后台引擎

项目文件补全的后台引擎：候选集、结果模型、匹配任务和身份规则。交互由命令行承担，`PickerSession` 是 `File` 参数位的补全器。代码在 `src/interaction/picker/`：`list.rs`（候选列表状态）、`source.rs`（文件来源）、`matching.rs`（匹配适配层）、`worker.rs`（后台执行）。

### 状态

`TextInput` 持有查询文字；`CandidateListState` 持有当前候选身份、是否主动选择和滚动位置；`PickerSession` 持有会话身份、有效查询及代次、结果快照和加载状态；候选来源定义候选身份和业务数据（`PathBuf`）；匹配适配层隔离模糊匹配库；Runtime 在 owner thread 应用结果。候选的展示文字和实际路径分别保存，同名候选身份不同，非 UTF-8 路径保留原始字节；列表下标只由排序派生，不确定业务对象。

### 来源与匹配

打开时后台用 `ignore` 遍历根目录（`require_git(false)`，不读父目录和全局 Git ignore，不跟随符号链接，跳过隐藏路径和非普通文件，读不到的条目略过），形成候选集后再匹配最新查询。会话内复用这一集合，磁盘上的增删在重新进入后体现。匹配用 `nucleo-matcher` 的路径评分、smart case 和 smart normalization，查询是一个完整的 fuzzy needle；排序依次比较分数、`file` 历史中的新旧（会话建立时随来源交给 worker，之后不变）、展示文字、实际路径和身份，结果确定，不依赖线程完成顺序。只为展示的结果生成高亮。

### 身份与接收

请求携带会话身份、来源代次和查询代次。来源代次在更换根目录或失败后重建候选集时递增；查询代次在有效查询变化时立即递增（所以 A→B→A 不会接受第一轮 A 的结果）。结果只在会话仍存在、三项身份都一致时被接受，每个请求只应用第一个结果；数据、排序和高亮属于同一个快照。

新查询使旧候选立即失效：旧候选留在屏幕上直到新结果到达，避免闪烁，但 Enter 和 Tab 不采用它们；没有旧候选时才显示加载状态。关闭会话立即使身份失效，再取消任务；迟到的结果不能重建会话。

### 资源上限

| 项 | 上限 |
| --- | --- |
| 候选文件 | 100,000 个 |
| 候选记账预算 | 64 MiB（候选对象、Arc 计数、路径与展示文字容量、向量实际容量），超出时报告截断 |
| 展示的匹配 | 1,000 个 |
| 查询 | 4,096 字节或 2,048 个 grapheme，超过时不调度匹配并显示错误（后者限制匹配器 `u16` 分数） |

`PickerRunner` 使用一个常驻 worker、一个最新待执行请求槽和容量为 4 的完成队列，输入不会积累任务。取消在遍历项之间、匹配候选之间和等待队列容量时检查；会话丢弃时通过取消标志和 Waker 唤醒 worker 释放缓存。Runtime 每轮最多处理八个文件、picker 和路径补全完成结果，其余留到下一轮。任务 panic 时 worker 返回当前请求的错误快照并清空缓存；完成通道断开时报告一次失败，下一个请求重建 worker。

### 选择

查询或来源变化时清除选择，默认选排序第一项；同查询的结果更新时，用户没有导航就选第一项，导航过就按身份保留所选候选，它消失时选旧位置附近的一项；尺寸变化只调整滚动。确认时从当前有效结果取得路径并输出 `Application::Open`。Application 记录打开意图代次与焦点版本：只有最新发起、之后没有焦点变化的打开请求在完成时激活视图，较旧的请求只创建后台视图。

## 验证

`tests/picker.rs` 和 worker 单测覆盖候选排序与选择、完成事件的身份校验、原生路径、查询上限、容量记账、缓存释放、背压取消和通道断开后的恢复；`tests/application.rs` 覆盖并发打开请求不覆盖最新意图；`tests/interaction.rs` 覆盖搜索预览、确认取消、跨视图映射和模态输入隔离；`tests/command_loop.rs` 覆盖键位与直接命令等价、确认取消只消费一次、picker 任务生命周期和无活动视图；`tests/departure.rs` 覆盖离开文档的保存时序；`tests/runtime.rs`、`tests/workflows.rs` 覆盖无前端的编辑、搜索、文件和剪贴板流程。模态、键位、命令行、跳转等各有同名测试文件（`tests/modal.rs`、`tests/keymaps.rs`、`tests/command_line.rs`、`tests/jumps.rs` 等）。
