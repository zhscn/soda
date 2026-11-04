# 扩展模型

扩展分两层。命令行沿用 kakoune 的形式：键位目标、用户命令、钩子和 `:` 执行的是同一种命令行。配置和需要逻辑、数据结构的扩展写成 Lua（5.4，经 mlua 嵌入），配置文件是 `init.lua`，Lua 与命令行共用同一组接口。

kakoune 没有脚本语言，只能用 `%sh{}` 和 `evaluate-commands` 把 shell 输出再当命令执行，转义层层叠加，数据只有字符串。soda 的命令语言停在配置所需的规模，没有条件、循环，也不执行 shell 输出；逻辑交给 Lua。

## 分层

```
键位 / 命令行 / 钩子              init.lua / 模块 / lua 命令
              │                               │
              └──────────── 命令行 ────────────┘
                             │  展开 %opt{} %val{} %arg{}
                             ▼
                     Command（交互层）
                             │
                    Application 事件  ← 选项存放在这里
                             │
                      editor / files
```

- **读**：命令通过 `&Application` 和交互层的只读查询读状态；命令语言用展开读。
- **写**：所有修改都表达为 `Command`，最终变成 Application 事件。命令行、Rust 处理函数和 Lua 都只能产生命令，所以撤销分组、视口映射、文件保护等不变量只在一处维护。
- **通知**：Runtime 观察每次更新产生通知（打开、保存、关闭、模式变化等），钩子把通知映射回命令行。

## 选项

选项是带类型的命名值，由 Application 持有，前端与交互层只读。

- **作用域**：全局和单个文档。读取时先查文档，再查全局，最后用默认值。文档关闭时它的选项一并删除。
- **类型**：布尔（也接受 yes/no、on/off）、带范围的整数、固定选项之一、任意文字。`set` 在解析命令行时就按类型检查，错误在执行前报告，失败时原值不变。
- **命令**：`set NAME VALUE` 设全局值，`set-local NAME VALUE` 只对当前文档，`unset-local NAME` 回到全局值。选项名可以补全，候选带说明。
- **生效**：选项变化作为 Application 更新传播。缩进类选项推给对应文档的编辑器，显示类选项由前端每帧读取。

`init.lua` 在第一个文档创建之前运行，其中设置的选项都是全局的；按文档的设置写在钩子里。C++ 的缩进和制表符宽度由 clang-format 决定，`indent-width`、`tab-width`、`expand-tab` 只作用于其他语言。

| 选项 | 取值 | 默认 | 作用 |
| --- | --- | --- | --- |
| `modal` | true/false | false | 模态编辑：插入之间回到 Normal，状态栏显示模式名；由 meow 插件设置，只看全局值 |
| `indent-width` | 0–16 | 4 | 每级缩进的列数 |
| `tab-width` | 1–16 | 4 | 制表位间隔 |
| `expand-tab` | true/false | true | 用空格缩进；false 时用制表符 |
| `auto-pairs` | true/false | false | 成对输入括号和语言列出的引号，退格删除空的一对；同 Emacs 的 `electric-pair-mode`，默认关 |
| `line-numbers` | absolute/relative/off | absolute | 行号栏；relative 时光标行显示自身行号，其他行显示距离 |
| `tab-bar` | auto/on/off | auto | 文档标签行；auto 只在单窗口时显示 |
| `window-title` | true/false | true | 有多个窗口时在每个窗口顶部显示标题 |
| `wrap` | true/false | false | 长行折到下一屏幕行，尽量在空格后断开 |
| `show-whitespace` | true/false | false | 用 `»` 标出制表符，`·` 标出行尾空格 |
| `ruler` | 0–1000 | 0 | 标出这一列之后的一列，0 不标；见[终端界面](ui.md) |
| `cpp-fallback-style` | LLVM/Google/Chromium/Mozilla/WebKit/GNU/Microsoft | LLVM | 没有可用的 `.clang-format` 时的 C++ 风格；只对之后打开的文档生效 |
| `inlay-hints`、`inline-notes` | true/false | true | 显示语言服务器的 inlay hint、行尾的诊断，见[语言服务器](lsp.md) |
| `completion`、`completion-min-prefix`、`completion-preview` | | | 见[补全](completion.md#键) |
| `scroll-lines` | 1–100 | 3 | 鼠标滚轮每格滚动的行数 |
| `idle-time` | 10–60000 | 500 | 最后一次按键之后多少毫秒运行 `idle` 钩子 |
| `theme` | 内置或定义的主题名 | tokyonight | 配色主题，见[终端界面](ui.md#主题) |
| `mouse` | true/false | true | 关闭后终端恢复自己的文本选择 |
| `trim-trailing-whitespace` | true/false | true | 保存时去掉上次加载或保存以来编辑过的行的行尾空白 |
| `final-newline` | true/false | true | 保存时给有内容的文件补上末尾换行 |
| `auto-reload` | true/false | true | 磁盘上变化了的文件没有未保存编辑时自动重新加载 |
| `clipboard` | system/internal | system | internal 时复制和粘贴不经过系统剪贴板 |
| `font`、`ui-font` | 文字 | 空 | 图形界面的正文和界面字体，见[图形界面](gui.md) |
| `font-size`、`line-height` | 6–72、100–300 | 14、135 | 图形界面的字号（点）和行高（字号的百分比） |
| `smooth-caret`、`smooth-scroll` | true/false | true | 图形界面的光标滑动和平滑滚动 |
| `mark-keys` | true/false | true | 光标在标记的符号上时 `mark` 键位表生效；false 对应 Emacs 的 `symbol-overlay-inhibit-map` |

## 展开

命令行在执行时展开，不在定义时展开：
- `%opt{NAME}`：选项在当前文档的值。
- `%val{NAME}`：`file`、`name`、`kind`、`line`、`column`、`selection`、`word`、`root`、`mode`、`column-limit`（clang-format 的 `ColumnLimit`，没有时为 0），钩子中还有 `hook`（事件参数）。
- `%arg{1}`…`%arg{9}`、`%arg{@}`：用户命令的参数。

`define-command` 的命令体按 `;` 分成语句（`\;` 是字面的分号），每条语句轮到它时才展开，所以 `goto 10; echo %val{line}` 读到跳转后的行号。不读状态的语句在执行前检查，读状态的语句展开后检查，失败时停止后续语句。展开结果按原文替换，不再拆分，含空格的值只适合放在最后一个参数位。`map`、`define-command`、`hook` 的参数是延后执行的命令行，其中的展开保留到执行时。

## 钩子

`hook EVENT FILTER COMMAND`：事件发生且 FILTER 完整匹配事件参数时执行 COMMAND。FILTER 是不含空白的正则表达式，`.*` 匹配一切；COMMAND 是一条命令行，多条命令用 `define-command` 组合。`unhook EVENT [FILTER]` 去掉一个事件的全部钩子，或只去掉 FILTER 相同的。同一事件的钩子按添加顺序执行。

| 事件 | 参数 | 时机 |
| --- | --- | --- |
| `open` | 文件路径 | 文件加载为新文档之后 |
| `new` | 文档种类（`file` 或 scratch 名） | 新建无标题或 scratch 文档之后 |
| `save` | 文件路径 | 保存成功之后 |
| `close` | 文档名 | 文档关闭之后 |
| `mode` | 新模式名 | 编辑模式变化之后 |
| `focus` | 文档名 | 当前窗口显示的视图变化之后 |
| `change` | 文档名 | 文档的文本变化之后 |
| `selection` | 文档名 | 选区或光标移动、文本没变之后 |
| `idle` | 文档名 | 最后一次按键之后 `idle-time` 毫秒没有按键时，每次按键之后至多一次 |

- **时机**：钩子在触发它的整个操作完成之后执行。
- **作用对象**：`mode`、`focus`、`close` 作用于当前视图；其余事件作用于触发它的视图，即使不在当前窗口，所以 `open` 钩子里的 `set-local` 设置的是新打开的文档。钩子移动焦点后，后续命令跟随新焦点。
- **消息**：钩子命令不设消息时，保留触发操作留下的消息（如 "Saved …"）。
- **嵌套**：钩子执行的命令可以再触发钩子，连续 16 轮后停止并报错；每次都改文本的 `change` 钩子会在这里停下。

按语言的设置用钩子表达，不另设作用域：`hook open .*\.py set-local indent-width 4`。

## 语言映射

`language-map NAME LANGUAGE`（Lua 里是 `soda.language(name, language)`）让之后打开的文件按 LANGUAGE 处理。NAME 是完整文件名（如 `Justfile`）或以点开头的扩展名（如 `.h`）；完整文件名优先，扩展名取最长匹配，都先于内置识别。LANGUAGE 是语言 id（`cpp`、`rust`、`makefile` 等，可补全），`text` 是纯文本。映射到 `cpp` 的文件同样读 `.clang-format`。已打开的文档不变。

## Lua

启动时先加载内置模块（见[插件](#插件)），再运行 `init.lua`，所以配置可以改写内置模块的命令和键位。配置目录下 `lua/` 中的模块可以 `require`，同名文件优先于内置模块；启动目录不在搜索路径上。`lua CODE` 在命令行上执行一段 Lua。Lua 通过全局表 `soda` 操作编辑器：

| 函数 | 作用 |
| --- | --- |
| `soda.command(line)` | 执行一条命令行，与 `:` 相同；返回是否成功和当前消息 |
| `soda.val(name)` | 读取 `%val{name}` |
| `soda.option(name)` | 选项在当前文档的值，按类型返回布尔、整数或字符串 |
| `soda.set(name, value, [local])` | 设置选项，`local` 为真时只对当前文档；不合法时报错 |
| `soda.declare_option(name, spec)` | 声明模块自己的选项，见下文 |
| `soda.map(keymap, keys, target, [doc])` | 绑定按键：`keys` 用 Emacs 记法，如 `"C-c v c"`（见[按键记法](interaction.md#按键记法)）；`keymap` 是上下文、文档键位表或语言 id（见[键位上下文](interaction.md#键位上下文)）；`target` 是命令行，或 Lua 函数（prompt 除外）；`doc` 显示在按键提示和帮助里 |
| `soda.map_default(keymap, keys, target, [doc])` | 插件绑定按键：参数同 `soda.map`，但作为默认绑定，见[插件](#插件) |
| `soda.unmap(keymap, keys)` | 去掉用户绑定，恢复默认（内置的或插件的） |
| `soda.keymap(name, { server = NAME, doc = ... })` | 声明服务器的键位表：在名为 `NAME` 的语言服务器服务的文档里生效，`"*"` 表示任一服务器；再次调用更新说明和范围 |
| `soda.bindings(keymap)` | 当前生效的绑定：`{ {keys = "C-x o", command = "window-next"}, ... }` |
| `soda.face(name, spec)` | 设置界面或语法分类的颜色，见[终端界面](ui.md#主题) |
| `soda.theme(name, { base, palette, faces })` / `soda.themes()` | 定义主题、列出主题名；用 `soda.set("theme", name)` 或命令 `theme` 切换，见[终端界面](ui.md#主题) |
| `soda.language(name, language)` | 同 `language-map` |
| `soda.thing(key, kind)` | 让 `,`、`.` 之后的 `key` 选中一种 thing：`round`、`square`、`curly`、`angle`、`string`、`symbol`、`word`、`paragraph`、`line`、`buffer`；`kind` 为 nil 时去掉。初始是 meow 的 `r s c g e w p l b` |
| `soda.buffers()` | 所有打开的文档的句柄 |
| `soda.windows()` | 屏幕上的窗口 `{buffer, x, y, width, height, active}`，分屏窗口按阅读顺序，然后是侧边窗口 |
| `soda.defer(ms, fn)` / `soda.cancel(id)` | `ms` 毫秒后在当前视图上调用 `fn` 一次，返回编号；`cancel` 取消还没到时间的，返回是否取消了 |
| `soda.message(text)` | 设置状态消息 |
| `soda.log(text)` | 只写进消息日志（`*messages*`） |
| `soda.hint(text)` | 消息行没有消息时显示的文字，保留到下一次调用；`nil` 清除 |
| `soda.status(name, text, [face])` | 状态栏右侧的一段文字，按名字替换，按首次设置的顺序排列；`text` 为空时去掉 |
| `soda.flag(group, face, sign, lines)` / `soda.unflag([group])` | 行标记，`lines` 是从 1 开始的行号数组 |
| `soda.indicator(line, text)` | 在当前文档第 `line` 行行尾显示文字，下一个按键清除 |
| `soda.popup(text)` | 在光标旁的浮窗里显示文字，下一个按键关闭 |
| `soda.paint(group, items)` | 给当前文档的一组范围上色：`{from, to, face}`；同组再调用时替换，空表去掉。范围随编辑移动 |
| `soda.note(group, items)` | 给当前文档的一组范围加注（诊断）：`{from, to, severity, text}` |
| `soda.keys(notation)` | 按 Emacs 记法输入按键，如 `soda.keys("foo RET")`，走与键盘相同的路径；要原样输入一段文字时把字符用空格隔开，免得 `RET` 这样的词被读成键 |
| `soda.prompt(text)` | 打开命令行并预填 `text` |
| `soda.input(title, [initial], fn)` | 在命令行里要一行文字，回车后以它调用 `fn`；取消时不调用 |
| `soda.choose(title, items, fn)` | 从 `items` 中选一项，输入过滤，以从 1 起的序号调用 `fn`；取消时不调用 |
| `soda.hook(event, filter, fn)` / `soda.unhook(id)` | 事件发生时以事件参数调用 `fn`，返回编号；`unhook` 只去掉这一个 |
| `soda.define_command(name, [doc], fn, [options])` | 定义命令，参数文本整体传给 `fn`；`doc` 显示在按键提示、帮助和补全里，省略时显示命令名；`options.args` 见下文 |
| `soda.tree(spec)` | 在 `*name*` 文档里显示一棵树，见[树](#树) |
| `soda.results(kind, lines)` | 把结果行写入 `*kind*` 并设为最近的结果，回车和 `M-g n`/`M-g p` 与 `grep` 相同；行可以是 `路径:行:列:`，或文件名行加缩进的 `行:列  文本`，其他行留作标题 |
| `soda.open(path, [line], [column])` | 打开文件并放置光标（列按字节）；打开是异步的，内容要在之后的请求里读 |
| `soda.clipboard([text])` | 带文字时替换剪贴板并同步到系统剪贴板；不带时返回粘贴会用的内容 |
| `soda.file_kind(path)` | `"file"`、`"directory"` 或 nil；相对路径以项目根目录为基准，下同 |
| `soda.create_file(path)` | 写一个空文件（已有的清空），补建上级目录 |
| `soda.rename_file(from, to)` | 改名文件或目录，补建上级目录；打开着的文档跟着换路径，目标处原来打开的文档关闭 |
| `soda.delete_file(path, [recursive])` | 删除文件或空目录，`recursive` 时连同内容；其中打开着的文档关闭，未保存的修改丢弃 |
| `soda.json_decode(text)` | JSON（允许注释和尾随逗号）转成 Lua 值，`null` 是 nil |
| `soda.spawn(argv, fn, [options])` / `soda.kill(id)` | 后台运行程序（不经 shell），结束后调用 `fn(code, stdout, stderr)`，返回编号；`kill` 停止它及其子进程，返回它是否还在运行 |
| `soda.tokens(data, names)` / `soda.inlays(items)` | 语义高亮和 inlay hint，见[语言服务器](lsp.md) |
| `soda.completion.register(source)` | 注册补全来源，见[补全](completion.md) |
| `soda.lsp.*` | 语言服务器接口，见[语言服务器](lsp.md) |

`soda.define_command` 的 `options.args` 是参数位数组，每项是一种类型或一个表：
- 类型：`file`（项目文件）、`path`、`buffer`、`option`、`face`、`theme`、`language`、`recent`、`symbol`（当前文档的符号）、`word`、`rest`。写成字符串时参数位必填，名字是类型的大写。
- 表：`{ name = "SIDE", choices = { { "left", "说明" }, "right" }, optional = true }` 或 `{ name = "FILE", kind = "file" }`。有 `choices` 时补全只能从中选。

最后一个参数位取到行尾，前面的各取一个词；参数文本仍整体交给函数。

`soda.spawn` 的第三个参数是写入标准输入的文字，或选项表：`input`（标准输入）、`cwd`（相对项目根目录，默认是根目录）、`env`（加上的环境变量 `{ NAME = "value" }`）、`stdout`/`stderr`（每行输出到来时以这一行调用的函数，在结束函数之前调用；给了的流在结束函数里是空字符串）。进程在自己的进程组里运行，`kill` 停掉整个组；被信号停止时 `code` 是 nil。

`soda.declare_option(name, spec)` 声明的选项与内置选项一样可以 `set`、`set-local`、`%opt{}` 和补全。类型由 `spec.default` 决定：布尔；整数，可给 `min`、`max`；字符串，给了 `choices` 时只能取其一，否则是任意文字。`spec.doc` 是说明。重复相同的声明没有影响，换一种声明或用内置选项的名字报错。名字只能用小写字母、数字和 `-`。

- **执行模型**：Lua 运行在编辑器线程上，同一时间只运行一个请求（一段代码、一次钩子或命令调用、一个回调），其间 `soda` 的函数直接作用于编辑器。请求中引发的 Lua（如 `soda.command` 触发的钩子）排队，等当前请求返回后运行。
- **作用对象**：请求在它产生时所在的视图上运行，所以 `soda.spawn` 的回调作用于调用时的文档，即使用户已切换；焦点不因此改变。
- **错误**：Lua 错误以 `lua: ` 开头显示在消息行并写入 `*messages*`。
- **时限**：一个请求最多运行 3 秒，超时报错 `lua: … stopped after 3 s`。超时后 `pcall`、`xpcall`、`coroutine.resume` 不再吞掉错误，循环里捕获也停不住它。下一个请求重新计时。
- **钩子和命令**：`soda.hook` 和 `soda.define_command` 保存函数本身，在命令表和钩子里表现为 `lua-call ID`，所以按键提示和帮助显示 `doc` 或命令名。

### 插件

没有配置的 soda 是裸 Emacs：只有 Insert，Emacs 的键，状态栏没有模式名。`lua/` 下的模块编译进二进制，启动时全部加载，分两种：

- **内置模块**补齐裸 Emacs 本来就有的东西，加载即生效，只绑 Emacs 自己的默认键。
- **插件**对应 Emacs 里要另装、另开的包。加载只定义命令（`M-x` 能用），`setup(options)` 才打开。

插件的约定：

1. **加载无副作用**。`require(name)` 只定义命令，不绑键、不加钩子、不设选项、不启动进程、不改显示。所以启动可以全部加载，不用的插件只多几个命令名。
2. **`setup(options)` 打开插件**。键、钩子、选项、键位表声明都在这里。重复调用不重复加钩子。能关的插件另有 `disable()`。
3. **键是默认绑定**。插件用 `soda.map_default` 绑键：它们和 Rust 里的默认键同一层，用户的 `soda.map` 遮住它们，`unmap` 去掉用户绑定后插件的键回来；后绑的默认键替换相同或互为前缀的默认键，如 puni 的 `C-k` 替换内置的 `kill-line-end`。要整个不要插件的键，传 `keys = false`；要关掉其中一个，把它绑到 `nop`。
4. **`C-c` 加字母留给用户**。这是 Emacs 的约定，内置模块和插件都不在默认键里占用；leader（Normal 的 `SPC`，读作 `C-c`）下的键由用户自己绑。插件可以绑在自己的键位表里（`mark`、`lsp`、`ccls`），也可以绑 Emacs 的标准键。
5. **插件之间**只通过命令名和键位表协作，不互相 `require` 内部函数；`lsp` 例外，它把服务器接口交给 `ccls` 这样的扩展。
6. **模态编辑本身也是插件**。选区种类、Beacon、keypad 这套机制在 Rust 里，`modal` 选项决定用不用它；`meow` 插件设这个选项，再给出 Normal 中能打出字符的键（布局）。打不出字符的键（`C-f`、方向键、Esc、Enter）是内置的默认键。

内置模块：

| 模块 | 内容 | 键 |
| --- | --- | --- |
| `emacs` | 单词大小写、对调、空白、`open-line`、`back-to-indentation`，见[交互层](interaction.md#emacs-键位) | Emacs 的默认键 |
| `comment` | 切换行注释 | `M-;` |
| `pairs` | 按表达式移动、选中、剪切，以及 puni 的各个命令，见[交互层](interaction.md#结构化编辑) | `C-M-f`、`C-M-b`、`C-M-u`、`C-M-Space`、`C-M-k`、`C-M-Backspace` |
| `lsp` | 语言服务器的各项功能，没有服务器时什么也不做，见[语言服务器](lsp.md) | `lsp` 表：`M-.`、`M-?` |
| `snippets` | snippet 作为补全候选，见[补全](completion.md#snippet) | 无 |
| `clang-format` | 用 clang-format 格式化文档或选中的行，只替换有变化的行 | 无 |
| `git` | 只读查询：`root(path)` 找工作树顶层；`status(path, fn)` 在后台得到根目录、分支、提交、上游和前后差几个提交，以及路径的跟踪、忽略、暂存、修改、冲突状态 | 无 |
| `git-changes` | `git-changes` 命令：把 `git diff` 的改动块列入 `*changes*` | 无 |

插件：

| 插件 | `setup` 打开什么 | 选项 |
| --- | --- | --- |
| `meow` | 模态编辑：设 `modal`，绑 Normal 的布局，加 thing；`disable()` 回到只有 Insert | `layout`：`"qwerty"`（默认，meow README 的 QWERTY 布局，去掉 soda 没有的命令）、`{ 键 = 命令 }` 或 false；`things`：`{ a = "angle" }` |
| `puni` | puni-mode-map 的键：Insert 的 Backspace、`M-Backspace`、`C-Backspace`、`C-w` 不拆配对，`C-k`、`C-M-a`、`C-M-e` | `keys = false` |
| `symbol-overlay` | `mark` 表：光标在标记上时的单键，见[交互层](interaction.md#高亮模式)；`mark-keys` 选项可关 | `keys = false` |
| `surround` | `C-c` 加括号或引号（Normal 中 `SPC` 加同样的键） | `keys = false` |
| `git-flags` | 打开、保存时运行 git，用行标记标出新增、修改和删除的行；`disable()` 关掉 | 无 |
| `ccls` | 让 C++ 使用 ccls，声明 `ccls` 键位表，变暗跳过的预处理分支，见[语言服务器](lsp.md#ccls) | `command`、`init`、`settings`、`roots`、`auto`、`languages` |

插件的命令没有用户键，用户在 `init.lua` 里绑：

```lua
require("meow").setup()
require("puni").setup()
require("symbol-overlay").setup()
soda.map("global", "C-c i", "symbol-toggle")
require("ccls").setup()
soda.map("ccls", "C-c v c", "ccls-callers")   -- ccls 表在 setup 之后才有
```

### 文档

`soda.buffer()` 返回当前文档的句柄；`soda.buffer(path)` 返回打开着这个绝对路径的文档的句柄，没打开时为 nil。句柄只记文档编号，可以留到以后的请求里用；文档关闭后，方法报错。

| 方法 | 作用 |
| --- | --- |
| `buf:text()`、`buf:text(from, to)` | 全文或一段范围的文本 |
| `buf:line(n)` | 第 n 行的文本，不含换行 |
| `buf:line_count()` | 行数；最后一个换行之后的空行不算 |
| `buf:revision()` | 文本修订号，文本每次改变都变化 |
| `buf:selection()` | anchor 和 head 两个位置 |
| `buf:set_selection(anchor, [head])` | 设置选区；省略 head 时为光标 |
| `buf:select(anchor, head)` | 选中这段范围，`head` 可以在 `anchor` 之前 |
| `buf:edit(changes, [revision])` | 应用编辑，返回新的修订号 |
| `buf:kill(from, to)` | 剪掉这段文字进 kill ring，与编辑器自己的剪切相同（连续剪切合并、同步系统剪贴板）；光标留在 `from` |
| `buf:indent(n)` | 语言给第 n 行的缩进字符串，不给出时为 nil |
| `buf:line_comment()` | 语言的行注释标记，没有时为 nil |
| `buf:offset(position)`、`buf:point(offset)` | 位置与字节偏移互相转换 |
| `buf:name()`、`buf:path()` | 文档名；文件路径，没有文件时为 nil |
| `buf:modified()` | 是否有未保存的修改 |
| `buf:language()` | 语言 id，纯文本是 `text` |
| `buf:show()` | 在当前窗口显示这个文档 |
| `buf:in_literal(position)` | 位置是否在注释、字符串或字符字面量内 |
| `buf:enclosing(position)` | 包围位置的最内层平衡分组 `{from, inner_from, inner_to, to}`；没有时为 nil |
| `buf:next_item(position)`、`buf:prev_item(position)` | 紧邻位置的条目 `{from, to, kind}`，`kind` 是 `group`、`atom`、`literal`、`comment` 或 `directive`；到达所在分组的边界或遇到没有配对的括号时为 nil |

- **坐标**：位置是 `{line, column}`，从 1 开始，列按字节计，与 `string.sub` 一致；字节偏移也从 1 开始。范围不包含第二个位置。行尾之后的列合法，`{line_count() + 1, 1}` 在文本以换行结束时也合法。超出文档或落在字符内部的位置报错，不做 clipping。
- **编辑**：`changes` 是 `{ {from, to, text}, ... }`，位置都相对同一修订，范围不能重叠。传入 `revision` 而文档已变化时报错；`soda.spawn` 的回调应当这样做。
- **撤销**：一个请求对一个文档的全部编辑合成一个撤销步。钩子是单独的请求，它的编辑自成一步，不并入 Insert 的输入。
- **选区**：选区是半开区间，属于视图；`anchor` 与 `head` 相同时没有选区。请求所在的视图显示该文档时用它，否则用屏幕上的视图，再否则用任一视图。
- **结构**：条目是词、字面量、注释、预处理指令或整个分组，标点不属于条目；位置在条目中间时返回位置一侧的部分。C++ 的结构来自语法树，能区分模板的 `<` 和比较，未闭合的分组和被 `#if` 分支拆开的分组不算分组。Rust 来自自有的词法和配对（`src/rust/`）：泛型的 `<>` 和闭包参数的 `|…|` 也是分组，生命周期是词，原始字符串和嵌套块注释是字面量和注释，未闭合的分组不算。其他语言按 `(`、`[`、`{` 配对，字面量和注释来自 TextMate，跨行的按行算；纯文本没有字面量。

### 树

`soda.tree` 把一棵树显示在文档 `*name*` 里，位置规则与结果文档相同（`display` 可以改）。节点是普通的 Lua 表：

```lua
soda.tree({
  name = "callers",
  roots = {
    { label = "main", detail = "a.cpp:12", children = { ... } },  -- 子节点已知
    { label = "helper", detail = "b.cpp:3" },                      -- 展开时再问 expand
    { label = "done", leaf = true },                               -- 没有子节点
  },
  expand = function(node, add) add({ ... }) end,  -- 可以晚些调用，比如在服务器回答之后
  open = function(node) soda.open(node.path, node.line) end,
})
```

- 每行是缩进、`▸`/`▾`、`label` 和灰色的 `detail`。`expanded = true` 的节点一开始就展开。
- 有 `expand` 时，没有 `children` 也不是 `leaf` 的节点可以展开：第一次展开时调用 `expand`，等待期间节点后显示 `…`；`add` 给出的子节点之后一直保留，给空表则节点成为叶子。
- `open` 和 `expand` 收到传进去的那张表，节点上可以放任何字段（位置、服务器的原始对象）。
- `tree` 键位表：`Tab`（`tree-toggle`）展开或收起，`Enter`（`tree-open`）调用 `open`，`Backspace`（`tree-collapse`）收起节点、已收起时回到父节点；其他键照常是 Normal 的。可以用 `soda.map("tree", ...)` 改。
- 重绘时光标留在原节点上；同名的树再显示一次就整个替换。
