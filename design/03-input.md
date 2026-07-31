# 编辑器输入系统

## 实现状态

| 能力 | 状态 |
|---|---|
| raw terminal、Kitty keyboard 与 bracketed paste | 已实现 |
| 增量 decoder 与规范 `InputEvent` | 已实现 |
| 分层 keymap、prefix map、tombstone 与内省 | 已实现 |
| per-View `InputState`、文本策略与单键捕获 | 已实现 |
| prefix argument、selection、View-local mark ring 与 kill ring | 已实现 |
| Editor-global mark ring | 已实现 |
| change ring 与跨 Buffer change navigation | 已实现 |
| 基础 motion、editing、search、replace 与 window command | 已实现 |
| Unicode regexp matcher、编号 capture 与双向搜索 | 已实现 |
| regexp capture replacement 与大小写转换 | 已实现 |
| literal/regexp search case policy 与 smart-case | 已实现 |
| `edit.transpose-lines` | 已实现 |
| `edit.join-line` | 已实现 |
| `edit.delete-blank-lines` | 已实现 |
| `edit.sort-lines` | 已实现 |

本文只定义文本编辑器当前使用的输入路径。minibuffer 的读取与焦点规则由
[12-minibuffer.md](12-minibuffer.md) 定义；command 与 interactive 参数由
[14-command-extensibility.md](14-command-extensibility.md) 定义；TUI application
需要的 handler、application text policy、组件 focus 和 pointer 路由由
[16-tui-applications.md](16-tui-applications.md) 定义。

## 输入管线

```text
terminal bytes
  -> incremental decoder
  -> InputEvent
  -> active View InputState
  -> layered keymap
  -> command invocation
  -> Buffer transaction
```

decoder 只归一终端协议。keymap 只解析命令。command 通过显式 context 访问 Editor、
View、Buffer、selection 和 prefix argument。异步完成事件也进入同一个 command loop，
并在应用前校验 identity、generation 和 revision。

## 终端协议

TUI 持有终端期间启用 raw mode、alternate screen、Kitty keyboard disambiguation 和
bracketed paste，退出时恢复原状态。decoder 同时接受：

- Kitty `CSI u`；
- legacy CSI/SS3、控制字符与 Alt 前缀；
- UTF-8 文本；
- 可跨 read 边界的 bracketed paste。

legacy control byte `0x08` 表示 `C-h`。Backspace 只由 DEL（`0x7f`）或 Kitty
协议中明确的 Backspace 事件表示；decoder 不使用终端的历史 `C-h`/Backspace
兼容映射。

按键归一为：

```text
KeyEvent {
  key,
  codepoint,
  shifted_codepoint,
  base_layout_codepoint,
  modifiers,
  type: press | repeat | release,
  text
}
```

独立文本提交归一为 `TextInputEvent { kind: text | paste, text }`。paste 作为一个原子
事件，不再解释其中的控制字节。传统终端中不完整的 Escape 序列由单次 timer 决定
何时 flush；未知序列形成受控事件，不会把 decoder 留在 pending 状态。

## Keymap

keymap 是具名、可继承的稀疏映射。definition 可以是 command、prefix keymap 或
显式 undefined。undefined 是 tombstone，会遮蔽 parent 和低优先级层；删除本地
definition 后恢复继承结果。

解析层从高到低为：

```text
Editor override
pending prefix argument
top InputState
View keymaps
minor modes
major mode and parents
Editor default
```

解析结果为 `none | prefix | command | undefined`。同一个纯查询入口供实际 dispatch、
`describe-key`、`where-is`、which-key 和配置内省使用。`C-g` 位于 Editor override，
负责清除 pending sequence、prefix argument、completion、prompt 和 transient state。

## InputState

每个 View 持有一个 durable state 和零个或多个 transient state：

```text
InputState {
  name,
  keymap_layers,
  text_policy: accept | ignore,
  text_command,
  key_capture_command?
}
```

只有栈顶 transient state 参与临时输入策略；被遮蔽的 transient state 不参与解析。
durable state 描述该 View 的常态编辑姿态，major mode 描述 Buffer 内容的语言语义。
同一 Buffer 的多个 View 因此可以拥有不同的 pending prefix、selection 和交互状态。

KeyEvent 先经过 keymap。未消费且携带文本的事件按 `text_policy` 交给
`text_command`；`TextInputEvent` 清除 pending key sequence 后原子提交。单键读取、
query-replace decision 和退出确认使用 transient state，不启动递归 command loop。

通用 TUI application 扩展后的完整 `InputState` 和 handler contract 只在
[16-tui-applications.md](16-tui-applications.md) 中定义。

## Prefix argument

prefix argument 是下一次 command invocation 的显式字段：

```text
PrefixArgument {
  sign,
  magnitude,
  kind: universal | digits | negative
}
```

`C-u` 建立并累乘 4，`M-0` 至 `M-9` 输入数字，`M--` 切换符号。下一条普通命令
取得参数后清除 pending 值；取消、未定义按键和命令异常也会清除它。command target
如何根据 prefix、region 和 thing 选择操作范围由
[14-command-extensibility.md](14-command-extensibility.md) 定义。

## Selection 与编辑原语

View 的 point、mark 和 local mark ring 使用 `DocumentAnchor`。Editor-global mark
ring 的 entry 保存 Buffer identity 和该 Buffer 中的 anchor，可通过独立命令跨 Buffer
push/pop；Buffer 关闭时释放对应 entry。Editor 持有 kill ring；连续 kill 依据方向
追加或前置，yank-pop 只在紧随 yank 且 Buffer revision 与范围仍匹配时替换上一条
yank。

Buffer 在 revision 发生变化的 transaction commit 后发布 change 通知。Editor 仅在
interactive command 边界内把通知记录到 change ring，entry 保存 Buffer identity、
稳定 anchor 和 command class。连续 `self-insert`、`kill` 与 `yank` transaction 按
class 和 Buffer 合并；previous/next change 命令沿同一历史跨 Buffer 移动。直接的
后台或初始化修改不进入用户 change ring。

motion 从 snapshot 和当前位置计算目标，不直接修改 Document。thing 解析 word、
sentence、paragraph、delimiter、sexp、defun 或 language text object 的范围。编辑命令
把选区或 thing 转换为单个 Buffer transaction。word policy 按 Buffer setting、
language profile 和 Unicode 默认实现解析。

默认命令覆盖：

- 字符、行、word、sentence、paragraph、page 和 Buffer 边界移动；
- mark、region、mark ring、kill ring、yank 与 transpose；
- undo、open-line、删除、case conversion、comment 与 fill；
- literal/regexp incremental search 和 query replace；
- 文件、Buffer、Window、帮助和 command invocation；
- delimiter、sexp、defun 和 Tree-sitter text object 导航。

`edit.transpose-lines` 把 point 前一行与 point 起始的 prefix-count 行作为一个连续
target，并将前一行旋转到 target 末尾；位于首行时以首行和其后行构造同一 target。
末尾空逻辑行归属于文件终止换行，不作为独立交换对象。命令保留原范围是否具有末尾
newline，并以一次 Buffer transaction 提交整个旋转。

`edit.join-line` 默认删除当前逻辑行与前一行之间的 newline；带 prefix argument 时
删除当前行与下一行之间的 newline。连接点两侧的 horizontal whitespace 一并归一；
两侧都有非空内容时保留一个空格，否则不插入分隔符。该归一化和 newline 删除属于
同一次 Buffer transaction。

`edit.delete-blank-lines` 在 point 位于空行时把连续空行压缩为一行，只有一行时删除
该行；point 位于非空行时删除紧随其后的连续空行。仅含 horizontal whitespace 的行
属于空行，文件末尾 newline 产生的空逻辑行不参与操作。删除作为一次 Buffer
transaction 提交。

`edit.sort-lines` 按 UTF-8 code-unit 的字典序排列 active region 内的行；prefix argument
选择降序。region 的起止位置是替换边界，边界外文本不参与排序；命令保留 region 是否
以 newline 结束，并以一次 Buffer transaction 替换排序结果。

## Search 与 query replace

incremental search 使用 minibuffer `PromptSession` 读取 query，同时保存来源 View、
live location、方向、当前 match 和 wrap 状态。query 改变时从来源位置重新匹配；
接受时通过普通 navigation 落点，取消时恢复来源位置。

query replace 由 query、replacement 和 decision 三个非递归阶段组成。decision state
处理替换、跳过、全部替换和结束。literal 与 regexp 版本共享同一遍历和 Buffer
transaction 机制；每次替换从 replacement 末尾继续扫描。

regexp matcher 返回结构化的 `RegexpMatch`，其中 group 0 是完整匹配，后续 group 按
左括号出现顺序稳定编号；未参与当前 alternative 的 group 为 `#f`。所有 range 使用
UTF-8 byte offset。forward search 选择最早起点，并在同一起点选择最长结果；backward
search 选择最晚结束点，并在同一结束点选择最长结果。两者共享 capture 结果契约。

matcher 的 `.` 不跨 newline，`^`/`$` 匹配文档或逻辑行边界。`\d`、`\w`、`\s` 及
其反向形式使用 Unicode character predicate，word 额外包含 `_`；`\b`/`\B` 使用同一
word 定义。字符 class、range、capturing group、`(?:...)`、alternation 和
`*`/`+`/`?` 在 forward/backward 中使用相同语义。case-fold 是一次 match request 的
显式参数，使用 Unicode case-insensitive character comparison。零长度结果是合法
的 `[offset, offset)` range；遍历者负责在消费该结果后推进至少一个字符边界。

regexp replacement 直接消费当前 `RegexpMatch`。`\&` 和 `\0` 引用完整匹配，
`\1` 等十进制编号引用 capture；未参与的 capture 展开为空字符串。`\\`、`\n`、
`\t`、`\r` 处理 replacement escape，`\u`/`\l` 转换下一个字符，`\U`/`\L` 持续
转换直到 `\E`。case conversion 使用 Unicode character mapping。decision UI 的
replacement preview 与最终 transaction 保存并消费同一个展开结果。

query replace 的 scan position 始终位于 UTF-8 character boundary。消费非空匹配后
从 replacement 末尾继续；零长度匹配在 replacement 末尾再推进一个完整字符，位于
EOF 时进入显式终止位置，因此 skip、逐项 replace 和 replace-all 都单调前进。

`search-literal-case-policy` 与 `search-regexp-case-policy` 分别接受 `sensitive`、
`insensitive` 或 `smart`，默认值为 `smart`。smart-case 在 query 不含有意的大写字符时
启用 Unicode case-fold；regexp 的 `\W`、`\D`、`\S`、`\B` 等语法 escape 不计为
大写意图。每个 incremental search 或 query-replace session 在创建时冻结 setting
值，query 改变只重新计算该 policy 下的有效 case-fold。状态区和 replacement preview
显示 `case-fold` 或 `case-sensitive`，使当前匹配模式可见。

## View 边界

输入只改变 Editor 状态、View 状态或 Buffer transaction。Window layout、Frame、
modeline、popup 和终端 presenter 属于
[13-rendering-theme.md](13-rendering-theme.md)。输入系统只通过 active View、
minibuffer focus 和 command context 观察这些对象，不直接生成 ANSI 或绘制 cell。
