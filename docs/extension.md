# 扩展模型

soda 的扩展分两层。命令行沿用 kakoune 的形式，键位目标、用户命令、钩子和 `:` 执行的是同一种东西。配置和需要逻辑与数据结构的扩展都写成 Lua（Lua 5.4，经 mlua 嵌入），配置文件就是 `init.lua`；Lua 与命令行共用同一组接口。

kakoune 没有脚本语言，所以要用 `%sh{}` 和 `evaluate-commands` 把 shell 的输出再当命令执行，转义层层叠加，数据只能是字符串。soda 不走这条路：命令语言停在配置所需的规模，不加条件、循环或执行 shell 输出；有逻辑的部分交给 Lua。

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

- **读**：命令通过 `&Application` 和交互层的只读查询读取状态。展开（`%val{…}`、`%opt{…}`）是命令语言读状态的方式。
- **写**：所有修改都表达为 `Command`，最终变成 Application 事件。命令语言、注册的 Rust 处理函数和以后的脚本都只能产生命令，不能直接修改状态，所以撤销分组、视口映射、文件保护等不变量只需要在一处维护。
- **通知**：Runtime 在观察每次更新时产生通知（打开、保存、关闭、模式变化等），钩子把通知映射回命令行。

## 选项

选项是带类型的命名值，由 Application 持有，前端与交互层只读。

- **作用域**：全局，以及单个文档。读取时先查文档，再查全局，最后用内置默认值。文档关闭时它的选项一并删除。
- **类型**：布尔、带范围的整数、固定选项之一。设置时按类型校验，失败时不改变原值。
- **命令**：`set NAME VALUE` 设置全局值；`set-local NAME VALUE` 只对当前文档生效；`unset-local NAME` 去掉文档值，回到全局值。`init.lua` 运行时还没有文档，所以只设置全局值。
- **生效**：选项变化作为 Application 更新传播。编辑行为相关的选项（缩进）由 Application 推给对应文档的编辑器；显示相关的选项由前端每帧读取。

C++ 的缩进、制表符宽度由 clang-format 配置决定，`indent-width`、`tab-width`、`expand-tab` 只作用于其他语言。

| 选项 | 取值 | 默认 | 作用 |
| --- | --- | --- | --- |
| `indent-width` | 0–16 | 4 | 每级缩进的列数 |
| `tab-width` | 1–16 | 4 | 制表位间隔 |
| `expand-tab` | true/false | true | 用空格缩进；false 时缩进用制表符 |
| `auto-pairs` | true/false | true | 成对输入括号和语言配置列出的引号，退格删除空的一对 |
| `line-numbers` | absolute/relative/off | absolute | 行号栏；relative 时光标行显示自身行号，其他行显示距离 |
| `tab-bar` | auto/on/off | auto | 文档标签行；auto 只在单窗口时显示 |
| `window-title` | true/false | true | 有多个窗口时在每个窗口顶部显示标题 |
| `wrap` | true/false | false | 长行折到下一屏幕行，能在空格后断开时在空格后断开 |
| `show-whitespace` | true/false | false | 用 `»` 标出制表符，用 `·` 标出行尾空格 |
| `cpp-fallback-style` | LLVM/Google/Chromium/Mozilla/WebKit/GNU/Microsoft | LLVM | 没有可用的 `.clang-format` 时的 C++ 风格；只对之后打开的文档生效，用全局的 `set` 设置 |
| `ruler` | 0–1000 | 0 | 在这一列之后画竖线；0 不画 |
| `scroll-lines` | 1–100 | 3 | 鼠标滚轮每格滚动的行数 |
| `idle-time` | 10–60000 | 500 | 最后一次按键之后多少毫秒运行 `idle` 钩子 |
| `theme` | auto/dark/light | auto | 配色的深浅变体，auto 时跟随终端背景 |
| `mouse` | true/false | true | 关闭后终端恢复自己的文本选择 |
| `trim-trailing-whitespace` | true/false | true | 保存时去掉上次加载或保存以来编辑过的行的行尾空白 |
| `final-newline` | true/false | true | 保存时给有内容的文件补上末尾换行 |
| `auto-reload` | true/false | true | 磁盘上变化了的文件没有未保存编辑时自动重新加载 |
| `clipboard` | system/internal | system | internal 时复制和粘贴不经过系统剪贴板 |

`set` 在解析命令行时就按类型检查取值，所以错误在命令执行前报告，Application 收到的永远是合法值。布尔值也接受 yes/no、on/off。`set` 和 `set-local` 的选项名可以在命令行中补全，候选附带说明。

`init.lua` 在第一个文档创建之前运行，其中设置的选项都是全局的；按文档的设置写在钩子里。

## 展开

命令行在执行时展开，而不是在定义时展开：
- `%opt{NAME}`：选项在当前文档的值。
- `%val{NAME}`：编辑器状态：`file`、`name`、`kind`、`line`、`column`、`selection`、`word`、`root`、`mode`、`column-limit`，钩子中还有 `hook`（事件参数）。
- `%arg{N}`、`%arg{@}`：用户命令的参数（已有）。

用户命令按 `;` 分成语句，每条语句在轮到它执行时才展开 `%opt` 和 `%val`。这样 `goto 10; shell echo %val{line}` 读到的是跳转后的行号。命令名和不读状态的语句仍在执行前检查，读取状态的语句在展开后检查参数，失败时停止后续语句。展开结果按原文替换，不再拆分；包含空格的值只适合放在最后一个参数位。`map`、`define-command`（以及以后的 `hook`）的参数是延后执行的命令行，其中的展开保留到执行时。

## 钩子

`hook EVENT FILTER COMMAND`：事件发生且 FILTER 完整匹配事件参数时执行 COMMAND。FILTER 是一个不含空白的正则表达式，`.*` 匹配一切；COMMAND 是一条命令行，需要多条命令时用 `define-command` 组合。`unhook EVENT [FILTER]` 去掉一个事件的全部钩子，或只去掉 FILTER 相同的那些。同一事件的钩子按添加顺序执行。

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
| `idle` | 文档名 | 最后一次按键之后 `idle-time` 毫秒（默认 500）没有按键时，每次按键之后至多一次 |

- **时机**：Application 在更新中带出打开、新建和关闭通知；Runtime 根据保存结果产生 `save`，并在每次输入、命令或后台完成之后比较模式和当前视图，产生 `mode` 和 `focus`。钩子在触发它的整个操作完成之后执行。
- **作用对象**：`open`、`new` 和 `save` 的命令作用于触发它的文档的视图，即使它不在当前窗口，所以 `set-local` 设置的是那个文档；其余事件作用于当前视图。钩子移动焦点后，后续命令跟随新的焦点。
- **消息**：钩子命令不设置消息时，保留触发它的操作留下的消息（如 "Saved …"）。
- **嵌套**：钩子执行的命令可以再触发钩子，连续 16 轮之后停止并报错。所以 `change` 钩子如果每次都修改文本，16 轮后会停下。
- **展开**：COMMAND 中的 `%opt`、`%val` 在钩子执行时展开。

按语言的设置通过钩子表达，不另设作用域：`hook open .*\.py set-local indent-width 4`。

## 语言映射

`language-map NAME LANGUAGE`（Lua 里是 `soda.language(name, language)`）让之后打开的文件按 LANGUAGE 处理：NAME 是完整的文件名（如 `Justfile`），或以点开头的扩展名（如 `.h`、`.inc`）。完整文件名优先，扩展名取最长的匹配，都先于内置的识别。LANGUAGE 是语言的 id（`cpp`、`rust`、`makefile` 等，命令行里可以补全），`text` 表示纯文本。映射到 `cpp` 的文件同样读取 `.clang-format`。已经打开的文档不变。

## Lua

启动时先加载内置模块（见下），再运行配置文件 `init.lua`，所以配置可以改写内置模块的命令和键位。配置目录下 `lua/` 中的模块可以用 `require` 加载，同名文件优先于内置模块；启动目录不在模块搜索路径上。命令行上 `lua CODE` 执行一段 Lua。Lua 通过全局的 `soda` 表操作编辑器：

| 函数 | 作用 |
| --- | --- |
| `soda.command(line)` | 执行一条命令行，与 `:` 相同；返回是否成功和当前消息 |
| `soda.val(name)` | 读取 `%val{name}` |
| `soda.option(name)` | 选项在当前文档的值，按类型返回布尔、整数或字符串 |
| `soda.set(name, value, [local])` | 设置选项，`local` 为真时只对当前文档；取值按类型检查，不合法时报错 |
| `soda.declare_option(name, spec)` | 声明模块自己的选项，见下文 |
| `soda.map(mode, keys, target, [doc])` | 绑定按键：`target` 是命令行，或一个 Lua 函数（prompt 之外）；`doc` 是按键提示和帮助里显示的说明 |
| `soda.unmap(mode, keys)` | 去掉用户绑定，恢复默认 |
| `soda.bindings(mode)` | 当前生效的绑定，用户的在默认之上：`{ {keys = "<c-x>o", command = "window-next"}, ... }` |
| `soda.face(name, spec)` | 设置界面或语法分类的颜色，见[终端界面](ui.md#主题) |
| `soda.language(name, language)` | 让文件名或扩展名对应一种语言，同 `language-map` |
| `soda.buffers()` | 所有打开的文档，返回句柄数组 |
| `soda.windows()` | 屏幕上的窗口：`{buffer, x, y, width, height, active}`，分屏窗口按阅读顺序，然后是侧边窗口 |
| `soda.defer(ms, fn)` | `ms` 毫秒后在当前视图上调用 `fn` 一次，返回编号 |
| `soda.cancel(id)` | 取消还没到时间的 `defer`，返回是否取消了 |
| `soda.message(text)` | 设置状态消息 |
| `soda.flag(group, face, sign, lines)` / `soda.unflag([group])` | 行标记，`lines` 是从 1 开始的行号数组；`unflag` 没有标记可去时不报错 |
| `soda.hint(text)` | 消息行没有消息时显示的文字，一直保留到下一次调用；`nil` 清除 |
| `soda.status(name, text, [face])` | 状态栏右侧的一段文字，按名字替换，按第一次设置的顺序排列；`text` 为 nil 或空时去掉。`face` 是任一 face 名 |
| `soda.indicator(line, text)` | 在当前文档第 `line` 行的行尾显示文字，下一个按键清除 |
| `soda.keys(notation)` | 按键记法输入按键，如 `soda.keys("foo<ret>")`，走和键盘一样的路径 |
| `soda.prompt(text)` | 打开命令行并预填 `text` |
| `soda.input(title, [initial], fn)` | 在命令行里要一行文字，预填 `initial`，回车后以这行文字调用 `fn`；取消时不调用 |
| `soda.choose(title, items, fn)` | 在命令行里从 `items` 中选一项，输入过滤，选中后以从 1 起的序号调用 `fn`；取消时不调用 |
| `soda.hook(event, filter, fn)` | 事件发生时以事件参数调用 `fn`，返回编号 |
| `soda.unhook(id)` | 去掉 `soda.hook` 加的这一个钩子，返回是否去掉了；同一事件的其他钩子不受影响 |
| `soda.define_command(name, [doc], fn, [options])` | 定义命令，调用时把参数文本整体传给 `fn`；`doc` 是一句说明，按键提示、帮助和命令补全显示它，省略时显示命令名。`options.args` 声明参数位，命令行按它补全，见下文 |
| `soda.results(kind, lines)` | 把结果行写入 `*kind*` 并设为最近的结果，回车和 `M-g n`/`M-g p` 与 `grep`、`run` 的结果相同；`lines` 可以是 `路径:行:列:` 行，或文件名行加缩进的 `行:列  文本` 分组行；其他行留作标题，一个位置都没有时只显示消息 |
| `soda.open(path, [line], [column])` | 打开文件并放置光标，行列从 1 开始，列按字节；打开是异步的，文件内容要在之后的请求里读 |
| `soda.clipboard([text])` | 带文字时替换剪贴板内容，与编辑器自己的复制一样同步到系统剪贴板；不带时返回粘贴会用的内容，先读系统剪贴板 |
| `soda.spawn(argv, fn, [options])` | 后台运行程序（不经过 shell），结束后调用 `fn(code, stdout, stderr)`，返回编号；见下文 |
| `soda.kill(id)` | 停止 `soda.spawn` 启动的进程及其子进程，返回它是否还在运行 |
| `soda.popup(text)` | 在光标旁的浮窗里显示文字，下一个按键关闭 |
| `soda.paint(group, items)` | 给当前文档的一组范围上色：`{from, to, face}`，位置同文档句柄，`face` 是任一 face 名；同组再调用时替换，空表去掉这一组。范围随编辑移动 |
| `soda.note(group, items)` | 给当前文档的一组范围加注（诊断）：`{from, to, severity, text}`，位置同文档句柄 |
| `soda.tokens(data, names)` / `soda.inlays(items)` | 语义高亮和 inlay hint，供 LSP 模块使用，见[语言服务器](lsp.md) |
| `soda.completion.register(source)` | 注册补全来源，见[补全](completion.md) |
| `soda.lsp.*` | 语言服务器接口，见[语言服务器](lsp.md) |

`soda.define_command` 的 `options.args` 是参数位的数组，每一项是一种类型，或者一个表：
- 类型：`file`（项目文件）、`path`、`buffer`、`option`、`face`、`language`、`recent`、`word`、`rest`；写成字符串时参数位必填，名字是类型的大写。
- 表：`{ name = "SIDE", choices = { { "left", "说明" }, "right" }, optional = true }`，或者 `{ name = "FILE", kind = "file" }`。`choices` 的每一项是词，或者词加说明；补全时只能从中选。

最后一个参数位取到行尾，前面的取一个词；参数文本仍然整体交给函数。

`soda.spawn` 的第三个参数可以是写入标准输入的文字，也可以是选项表：
- `input`：写入标准输入的文字。
- `cwd`：工作目录，相对路径从项目根目录算起；默认是项目根目录。
- `env`：加上的环境变量，`{ NAME = "value" }`。
- `stdout`、`stderr`：每一行输出到来时以这一行（不含换行）调用的函数，在结束函数之前按顺序调用；给了的流不再交给结束函数，结束函数里它是空字符串。

进程在自己的进程组里运行，`soda.kill` 停掉整个组；被信号停止的进程，结束函数收到的 `code` 是 nil。

模块的选项用 `soda.declare_option(name, spec)` 声明，之后与内置选项一样可以 `set`、`set-local`、`%opt{}` 和补全。类型由 `spec.default` 决定：布尔；整数，可以给 `min`、`max`；字符串时必须给 `choices`，取值只能是其中之一。`spec.doc` 是说明。同样的声明重复执行没有影响，换一种声明报错；不能声明内置选项的名字。选项名只能用小写字母、数字和 `-`。

- **执行模型**：Lua 运行在编辑器线程上，同一时间只运行一个请求（一段代码、一次钩子或命令调用、一个进程的回调）。请求运行时 `soda` 的函数直接作用于编辑器。请求中引发的 Lua（例如 `soda.command` 触发的钩子、执行的 `lua` 命令）排队，等当前请求返回后运行。
- **作用对象**：每个请求在它产生时所在的视图上运行，就像钩子一样。所以 `soda.spawn` 的回调作用于调用 `spawn` 时的文档，即使用户已经切换到别的文档；焦点不因此改变。
- **错误**：Lua 错误以 `lua: ` 开头显示在消息行并写入 `*messages*`，不影响编辑器继续运行。
- **时限**：一个请求最多运行 3 秒，超时报错 `lua: … stopped after 3 s`，编辑器继续运行。Lua 在编辑器线程上运行，不设时限的话，一个不会结束的循环会让编辑器永远卡住。超时之后 `pcall`、`xpcall` 和 `coroutine.resume` 不再吞掉错误，而是继续向外抛出，所以在循环里捕获错误也停不住它。下一个请求重新计时。
- **钩子和命令**：`soda.hook` 和 `soda.define_command` 保存 Lua 函数本身，在命令表和钩子中表现为 `lua-call ID`。这个命令体对读者没有意义，所以 Lua 命令在按键提示和帮助里显示 `doc` 或命令名，而不是命令体。钩子的事件参数也可以在命令行钩子中用 `%val{hook}` 读取。

### 内置模块

`lua/` 目录的模块编译进二进制，用户无需安装。启动时加载的模块只增加命令和键位，用到时才做事；`git-flags` 每打开或保存一个文件都运行 git，所以要在 `init.lua` 里 `require("git-flags")` 才生效。不想要某个键时用 `unmap`（Lua 里是 `soda.unmap`）。leader 指 Normal 的 `SPC`，它读作 `<c-c>`，所以这些键在 `global` 表里绑成 `<c-c>` 加一个键，所有模式下 `C-c` 加同一个键也能用。

| 模块 | 内容 | 键位 |
| --- | --- | --- |
| `lsp` | 跳转、引用、调用层级、hover、诊断、重命名、代码动作、符号、格式化、签名提示和补全，见[语言服务器](lsp.md) | `<a-.>`、`<a-?>`，leader 下的 `k`、`c`、`C`、`R`、`a`、`s`、`S`、`h` |
| `pairs` | 结构化编辑，见[交互层](interaction.md#结构化编辑) | 见交互层 |
| `comment` | 切换行注释 | `<a-;>` |
| `emacs` | Emacs 的单词大小写、对调和空白命令，见[交互层](interaction.md#emacs-键位) | 见交互层 |
| `snippets` | 按语言注册 snippet，作为补全候选，见[补全](completion.md#snippet) | 无 |
| `surround` | 在选区两侧加上成对的文本 | `SPC` 加括号或引号 |
| `clang-format` | 用 clang-format 格式化文档或选中的行，只替换有变化的行 | 无 |
| `symbol-overlay` | 标记符号并在标记之间跳转、改名，见[交互层](interaction.md#高亮模式) | leader 下的 `i`、`I`，`<a-n>`、`<a-p>`，以及 `mark` 键位表 |
| `git-changes` | 把 `git diff` 的每个改动块列入 `*changes*` | leader 下的 `g` |
| `git-flags` | 用行标记标出新增、修改和删除的行，不随启动加载 | 无 |

### 文档

`soda.buffer()` 返回当前文档的句柄；`soda.buffer(path)` 返回打开着这个绝对路径的文档的句柄，没打开时为 nil。句柄只记住文档编号，可以保存到以后的请求中使用；文档关闭后，它的方法报错。

| 方法 | 作用 |
| --- | --- |
| `buf:text()`、`buf:text(from, to)` | 全文或一段范围的文本 |
| `buf:line(n)` | 第 n 行的文本，不含换行 |
| `buf:line_count()` | 行数；最后一个换行之后的空行不算 |
| `buf:revision()` | 文本修订号，文本每次改变都变化 |
| `buf:selection()` | 返回 anchor 和 head 两个位置 |
| `buf:set_selection(anchor, head?)` | 设置选区；省略 head 时为 caret |
| `buf:select(anchor, head)` | 选中这段范围；`head` 可以在 `anchor` 之前 |
| `buf:edit(changes, revision?)` | 应用编辑，返回新的修订号 |
| `buf:indent(n)` | 语言给第 n 行的缩进字符串；语言不给出时为 nil |
| `buf:line_comment()` | 该语言的行注释标记，来自语言档案；没有行注释时为 nil |
| `buf:offset(position)`、`buf:point(offset)` | 位置与字节偏移互相转换 |
| `buf:name()`、`buf:path()` | 显示的文档名；文件路径，没有文件时为 nil |
| `buf:modified()` | 是否有未保存的修改 |
| `buf:language()` | 语言的 id，如 `cpp`、`rust`，纯文本是 `text` |
| `buf:show()` | 在当前窗口显示这个文档，与 `buffer` 相同 |
| `buf:in_literal(position)` | 位置是否在注释、字符串或字符字面量内 |
| `buf:enclosing(position)` | 包围该位置的最内层平衡括号，返回 `{from, inner_from, inner_to, to}` 四个位置；没有时为 nil |
| `buf:next_item(position)`、`buf:prev_item(position)` | 紧邻该位置的条目，返回 `{from, to, kind}`；`kind` 是 `group`、`atom`、`literal`、`comment` 或 `directive`。到达所在分组的边界或遇到没有配对的括号时为 nil |

- **坐标**：位置是 `{line, column}`，都从 1 开始，列按字节计，与 `string.sub` 一致。范围由两个位置组成，不包含第二个位置。行尾文本之后的列合法，`{line_count() + 1, 1}` 在文本以换行结束时也合法。字节偏移同样从 1 开始。位置严格校验：超出文档或落在字符内部都会报错，不做 clipping。
- **编辑**：`changes` 是 `{ {from, to, text}, ... }`，所有位置都相对同一份修订，范围不能重叠。传入 `revision` 时，文档已经变化就报错；`soda.spawn` 的回调应该这样做，因为进程运行期间用户可能继续编辑。
- **撤销**：一次请求对一个文档的全部编辑合并成一个撤销步。钩子是单独的请求，所以它的编辑自成一步，不并入 Insert 模式的输入。
- **作用视图**：选区属于视图。请求所在的视图显示该文档时用它，否则用屏幕上的视图，再否则用任一视图。
- **结构**：条目是词、字面量、注释、预处理指令或整个括号分组，标点不属于任何条目；位置落在条目中间时，返回的是位置一侧的部分。C++ 的答案来自语法树，能区分模板的 `<` 和比较，未闭合的分组和被 `#if` 分支拆开的分组都不算分组。其他语言按 `(`、`[`、`{` 配对，字面量和注释来自 TextMate，跨行的字符串和注释按行算；纯文本没有字面量。
- **选区与模式**：选区是半开区间，读到的范围就是选中的文本。`anchor` 和 `head` 相同时没有选区。

## 实施顺序

1. **选项**：选项表与作用域、`set`/`set-local`/`unset-local`；把现有写死的值改为选项（纯文本缩进、行号、滚轮行数、鼠标、系统剪贴板）。（已完成）
2. **展开**：`%opt{}`、`%val{}`，用户命令改为逐条展开。（已完成）
3. **钩子**：通知、`hook`/`unhook`。（已完成）
4. **脚本语言**：Lua 5.4（mlua），`soda` 表、函数钩子与命令、后台进程。（已完成）
