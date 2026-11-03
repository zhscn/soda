# 模态编辑的设计

这篇记录交互层为什么是现在的样子：放弃了什么，参照了什么，哪里有意偏离参照，以后调整时要注意什么。每个键的行为见[交互层](interaction.md#模态编辑模型)，这里只讲理由。

## 1 为什么移除 Vim

soda 早期是 Vim 的 Normal/Insert/Visual 和 operator 语法，Emacs 键加在 Vim 没用到的位置上。问题不在 Vim 本身，而在于 **Vim 语法是固定的底层**，其他东西只能往上贴：

- **Emacs 键没有自己的语义**：`C-f` 翻译成 `l`，`M-d` 翻译成 `dw`，结果既不像 Vim 也不像 Emacs。
- **键表不是最底层**：没有绑定的键落进语法分析器，`w`、`d`、计数都不是命令，`map` 改不了。
- **选区有两套**：核心的半开 `Selection` 之外，Visual 另有端点。
- **产出范围的功能接不进来**：结构化选择、symbol-overlay、LSP 产出的都是范围，而 Vim 的主线是 operator + motion。

最后一点最关键：soda 的核心资产是增量 CST，结构化选择本该最自然，在 Vim 语法里却处在语法之外。

## 2 设计理念

1. **先选中，再操作**。选区是核心里唯一的一份，移动就是设置选区，操作作用于选区。没有 operator-pending，没有 Visual。
2. **每个键是一条命令**。键表是唯一的分发入口，没有语法兜底。所有行为都有名字，可以 `map`，出现在帮助和命令面板里。
3. **用户层面以 meow 为规格**。用户日常用 meow + puni，肌肉记忆在那里，meow 的交互设计没有需要推翻的地方；但只把它当规格，不搬它的已知问题（第 5 节）。
4. **结构化操作走 CST**。这是 soda 相对 meow 多出来的东西：meow 的块和 thing 靠语法表或纯文本配对，soda 的 `o`、`,r` 等问语言结构，字符串和注释里的括号不算分组。
5. **小于 meow**。不做自定义状态、多键盘布局、与第三方包共存的适配。`interaction/modal/` 约 1900 行，比删掉的 Vim 层（约 2350 行）小。

## 3 关键决定

### 3.1 模式固定三个

| 模式 | 单键的含义 |
| --- | --- |
| Normal | 移动、选择、对选区操作 |
| Insert | 输入字符 |
| Beacon | 在 grab 范围里派生和编辑多个选区 |

模式的本质区别是单键怎么解释，三个就够了。meow 允许自定义状态，是因为它要寄生在任意 Emacs 模式上。meow 另外两个状态在 soda 里另有归宿：

- **Motion**（给特殊 buffer）：用文档相关的键位表代替，如树文档的 `tree`。
- **Keypad**：只是“正在读一个键序列”，和普通多键序列同类，不是模式。soda 是事件循环，不需要 meow 那种阻塞的 `read-key`。

### 3.2 键位表是 Emacs 式的栈，不是 kakoune 式的平表

Emacs keymap 的灵活来自“当前有哪些表”是运行时状态：表有名字，按优先级排成栈，前缀键绑定到子表，表可以挂在文本上。kakoune 是每个作用域一张按（键，模式）索引的平表，只支持单键，前缀靠临时模式模拟，所以没有采用。

soda 取了够用的部分（`Layers::stack`），先查到的算数：

| 模式 | 栈 |
| --- | --- |
| Insert | `completion`（列表显示时）、`snippet`（还有位置时；在选项列表上时排到 `completion` 之前）、不是模态编辑时同 Normal 的 `mark`/`tree`/`results`、`insert`、`global` |
| Normal | `mark`（光标在标记上时）、`tree`（树文档里）或 `results`（结果文档里）、`normal`、`global` |
| Beacon | `beacon`、`normal`、`global` |

补全、snippet、标记盖过下层，都只是栈里的普通表，路由里没有特判。

**有意没做的**：Lua 新建表、表挂在 note 上、按表定义默认绑定。`mark` 是唯一挂在文本上的表，按光标处的高亮生效；等有第二个使用者再做成通用机制。Emacs 的键翻译层（`input-decode-map` 等）、菜单项、`:filter` 动态绑定和 `remap` 都不做。

### 3.3 keypad 是一条查找规则，不是第二套表

需求是 `x s` 和 `C-x C-s` 走同一个命令，同时 `C-x o` 和 `C-x C-o` 仍是两个命令：

| 方案 | 问题 |
| --- | --- |
| 两套绑定 | 用户绑定都要写两遍 |
| 去掉修饰键，统一成 `x s` | `C-x o` 和 `C-x C-o` 塌成一个键 |
| `x` 直接绑到 `C-x` 子表 | `x s` 查到 `C-x s`，不是 `C-x C-s` |
| **单向翻译（meow 的做法）** | 一棵树，两个入口，槽位都保留 |

所以绑定只在 `global` 表里存一份真实按键；keypad 读键时每个键先试加 Ctrl 再试原样，Space 让下一个键不加修饰。翻译只发生在 keypad 读键时，不是独立的层。

keypad 只查 `global`，不查 Normal 表，否则 `x` 之后的键会被当成移动；meow 同样排除自己的状态表。leader（`SPC`）就是 `<c-c>`，模块把键绑在 `<c-c>` 下，就同时得到 `SPC` 入口和所有模式下的 `C-c` 入口。代价是 `C-c` 必须是前缀：stop 在 `C-c C-c`（与 Emacs comint 的中断键一致），Insert 也不能用 `C-c` 离开。

### 3.4 多选区只存在于 Beacon

kakoune 是真多选区，Normal 下所有命令对每个选区执行；meow 没有多光标，beacon 是 overlay，退出 Insert 后逐点回放 kmacro。soda 取中间：**Normal 和单选区的 Insert 永远只有一个选区，多个选区只在 Beacon（及从它进入的 Insert）里出现。**

- **范围小**：需要懂多选区的只有输入、`d`、`r`、`s` 几类编辑，移动命令一个都不用改。
- **不进核心**：其余选区是交互层里跟随编辑的位置（`DocumentPosition`），核心的 `Selection` 和事务不用改成列表。
- **输入是实时的**：每个键是同一个事务里的多处修改，不像 meow 那样退出后才回放。
- **代价**：没有 Normal 下所有光标一起移动，逐光标的复杂操作靠宏。这本来就是 meow 的用法。

Beacon 里的移动不是“每个选区各自移动”，而是改变主选区后**按它的种类重新派生**其余选区，派生表基本照搬 meow。一处不同：`w` 之后 meow 在每个词尾放光标，主选区却是整个词，`i` 和 `a` 在两边落到不同位置；soda 让其余选区也是整个词。

### 3.5 多选区回车不缩进

单选区回车是 CLion 式缩进，这是 soda 的核心目标；多选区回车只插入换行。

原因：soda 的缩进读文档里实际的空白，多光标的结果依赖处理顺序，逐光标投机解析要 N 次全文件解析（kakoune 逐选区跑缩进脚本，是平方复杂度）。用户在 Emacs 里用 kmacro 时也是换行后手动调整缩进，不值得为它设计批量缩进。

### 3.6 选区种类跟着选区走

每个选区带一个种类（词、行、块等），决定下一条命令是扩展还是替换、数字往哪里扩展。meow 的种类和导航函数是两份独立状态，后者是全局的，会过期：按 `e`，取消，`H`，`2` 会用行的导航扩展字符选区。

soda 把种类和它标记的选区存在一起（`Tag`），读取时比较选区是否还是那一个，选区一变（编辑、鼠标、Lua）就自动失效。字符选区例外，只比较 anchor：它就是 Emacs 的 mark，任何移动都在扩展它。

### 3.7 宏录按键，没有 `.`

宏录的是按键，回放走同一条路由，所以宏里做什么都能重放。kakoune 的 `.` 只重放插入的按键，meow 没有 `.`，用户用的是 Emacs 的 `repeat`，所以 soda 也不做 `.`，`` ` `` 重复上一条命令。

在 Beacon 里录宏时只编辑主选区，结束后在其余选区逐个回放，从录制开始到回放结束是一次撤销，然后离开 Beacon。这是 meow 的行为；kakoune 要 `-itersel` 才能逐选区执行。

### 3.8 光标是 point，不在字符上

光标是 Emacs 的 point，位于两个字符之间；Normal 的方块只是画在 point 后面的字符上。由此：

- 光标能停在行尾，离开 Insert 时不往回退。
- 最后一个换行之后的空行是一行：始终显示，`j`、`C-n`、`goto` 都能到达，`a\n` 显示两行。
- 没有选区时 `i` 和 `a` 在同一处，有选区时才分别落在两端，与 meow 默认一致。

没有采用 meow 的 `meow-use-cursor-position-hack`（无选区时 `a` 后移一个字符）：行尾的方块盖着换行符，文件末尾的方块下面什么也没有，`a` 在这两处只能不动，同一个键因位置而异。要让 `a`、`i` 处处不同，只能回到 Vim 的“光标在字符上”，禁止停在换行符和文件末尾，这正是移除的约束，也和 `C-e` 停在最后一个字符之后冲突。

### 3.9 结构查询交给 runtime

结构分析需要可变访问（C++ 会话有增量缓存），交互层只拿到不可变的 Application。所以 `o`、`O` 和括号 thing 产出 `Command::Effect(Structure)`，runtime 拿编辑器问 CST，再以 `Action::Found` 送回交互层设定选区和种类。交互层因此保持纯粹，测试可以直接驱动。

### 3.10 模态编辑是插件，不是默认

没有配置的 soda 应当和裸 Emacs 差不多，meow 在 Emacs 里也是另装的包。所以模态编辑拆成两半：

- **机制在 Rust**：选区种类、Beacon、keypad、宏都留在 `interaction/modal/`，不搬进 Lua。它们要在每个键上读写选区和种类，跨过 Lua 边界既慢又会把种类、Beacon 位置这类状态暴露成接口。
- **开关和布局在插件**：`modal` 选项决定用不用这套机制，默认关；关着时只有 Insert，Esc 是 `keyboard-quit`，状态栏不显示模式名，`C-Space` 之后的移动扩展选区。`meow` 插件设这个选项，并给出 Normal 中能打出字符的键。meow 本身也没有默认键位，README 给的 `meow-setup` 是让用户抄的；插件的 `qwerty` 布局对应它，作者自己的布局写在自己的 `init.lua`。

打不出字符的 Normal 键（`C-f`、方向键、Esc、Enter）仍是 Rust 的默认键：它们相当于 meow 把没有绑定的键交回 Emacs 的全局表，不属于布局。thing 表同理：默认是 meow 的 `meow-char-thing-table`，`soda.thing` 对应 `meow-thing-register`。

`modal` 只在变化时起作用（`Layers::sync_modal`，每次操作结束时调用）：打开时停在 Insert 而没有插入在进行的，回到 Normal；关掉时离开 Beacon，回到 Insert。

## 4 参照的调研

**kakoune**

- 学了：帮助由当前键表生成；寄存器每个选区一个值。选择器是纯函数加一个负责遍历、排序和合并的驱动，但 Normal 只有一个选区，驱动没有用上。
- 不学：两端闭合、不能为空的选区（它大部分特例的来源），soda 用半开、可为空的选区；撤销分组由每个命令自己开（`<` 忘了开，撤销会和下一次编辑合在一起）；查找失败时选区被静默丢弃；平表。

**meow**（及用户的 `init-meow.el`）

- 没有多光标：一个 point，beacon 是 overlay，回放 kmacro；回放在一个 change group 里，一次撤销，出错整批回滚。
- 选区是 Emacs region 加类型标签，方向由 point 和 mark 推出；扩展还是替换没有集中的规则，由每个命令决定。
- keypad 没有自己的命令表，拼出按键描述后调用 `key-binding`，Ctrl 没绑定时退回原样。

## 5 与 meow 的差别

| 方面 | meow | soda | 理由 |
| --- | --- | --- | --- |
| 数字扩展 | 把 `(expand . word)` 改成 `(select . word)`，下一个 `w` 变成替换 | 保持种类 | meow 的行为是意外，不是设计 |
| 无选区时按数字 | 报错 | 作为计数 | 数字键不该无效 |
| 无选区时按 `<escape>` | 报错 “No selection” | 什么也不做；Beacon 里退出 Beacon | 用户配置里的别名绕过了回退规则 |
| 查找失败 | 只提示 | 选区不变并提示 | 同上 |
| keypad 的 `m`、`g` | 序列中任意位置都生效 | 只在开头生效 | 否则 `C-x p g` 要写成 `x p SPC g` |
| leader 后的保留键 | `c h x m g SPC` 不能做 leader 键 | 只有 `SPC` | soda 已有 `SPC c`、`SPC h`、`SPC g` |
| keypad 未绑定 | 退回键的原义 | 提示未定义 | 行为可预测 |
| beacon 状态下的 keypad | `SPC` 命令被静默丢弃 | 正常 | 走同一条路由 |
| Beacon 输入 | 退出 Insert 后回放 | 实时同步 | 真实的多处修改 |
| 块和括号 thing | 语法表、纯文本配对 | CST | soda 的核心资产 |
| 标记上的单键 | symbol-overlay 的 overlay 键表盖过 meow | `mark` 表盖过 Normal，`mark-keys` 关闭 | 与 Emacs 同构，选项对应 `symbol-overlay-inhibit-map` |

`f` 不限于行、`v` 是 `visit`，两者与 meow 一致。用户配置里 `t` 是 query-replace，soda 的 `t` 是 till，query-replace 在 `R`。

## 6 已知的缺口

- Lua 命令在 Beacon 里只作用于主选区，Lua 也读不到其余选区。
- Lua 设的选区不带种类，数字不能扩展它。
- Lua 只能声明服务器的键位表（`soda.keymap`），不能新建其他种类的表。
- 没有 undo-in-selection、sync-grab、跳回 grab、`d`（defun）thing；`y` 在没有选区时报错。
- 数字提示的消失时间固定为 1.5 秒，不是选项。

## 7 以后调整时

- **加键**：能打出字符的 Normal 键属于布局，加在 `lua/meow.lua` 的 `qwerty` 表里（只放 meow README 里有的）；打不出字符的加在 `interaction/keymap.rs` 的表里。命令注册在 `registry.rs`。不在默认键里占用 `C-c` 加字母。不要重新引入 operator 语法或“没有绑定时交给某个分析器”的兜底。
- **加选择命令**：在 `modal/text.rs` 写纯函数求位置，在 `execute.rs` 里通过 `select` 设定选区和种类。需要结构信息的，加一个 `Query` 变体交给 runtime。
- **让某种操作支持多选区**：在 `beacon.rs` 里处理，不要把选区列表推进核心，除非 Normal 也要有多选区（那是推翻 3.4，需要重新评估事务、历史和渲染）。
- **加一张生效条件特殊的键位表**：加进 `Layers::stack`，不要在路由里写特判。
- **测试**：模态行为在 `tests/modal.rs`，布局来自 `tests/fixtures/modal.lua`；没有配置时的行为在 `tests/plain.rs`。用 `|` 表示光标、`[ ]` 表示选区，期望值以 meow 的实际行为为准；有意偏离 meow 的地方在测试里写明。
