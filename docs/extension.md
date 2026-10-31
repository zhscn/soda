# 扩展模型

soda 的扩展分两层。命令行沿用 kakoune 的形式，配置文件、键位、用户命令、钩子执行的是同一种东西，用来写配置。需要逻辑和数据结构的扩展写成 Lua（Lua 5.4，经 mlua 嵌入），它与命令行共用同一组接口。

kakoune 没有脚本语言，所以要用 `%sh{}` 和 `evaluate-commands` 把 shell 的输出再当命令执行，转义层层叠加，数据只能是字符串。soda 不走这条路：命令语言停在配置所需的规模，不加条件、循环或执行 shell 输出；有逻辑的部分交给 Lua。

## 分层

```
配置文件 / 键位 / 命令行 / 钩子          init.lua / lua 命令
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
- **命令**：`set NAME VALUE` 设置全局值；`set-local NAME VALUE` 只对当前文档生效；`unset-local NAME` 去掉文档值，回到全局值。配置文件只能使用 `set`。
- **生效**：选项变化作为 Application 更新传播。编辑行为相关的选项（缩进）由 Application 推给对应文档的编辑器；显示相关的选项由前端每帧读取。

C++ 的缩进、制表符宽度由 clang-format 配置决定，`indent-width`、`tab-width`、`expand-tab` 只作用于其他语言。

| 选项 | 取值 | 默认 | 作用 |
| --- | --- | --- | --- |
| `indent-width` | 0–16 | 4 | 每级缩进的列数 |
| `tab-width` | 1–16 | 4 | 制表位间隔 |
| `expand-tab` | true/false | true | 用空格缩进；false 时缩进用制表符 |
| `auto-pairs` | true/false | true | 成对输入括号（C++ 中还有引号），退格删除空的一对 |
| `line-numbers` | absolute/relative/off | absolute | 行号栏；relative 时光标行显示自身行号，其他行显示距离 |
| `wrap` | true/false | false | 长行折到下一屏幕行，能在空格后断开时在空格后断开 |
| `show-whitespace` | true/false | false | 用 `»` 标出制表符，用 `·` 标出行尾空格 |
| `ruler` | 0–1000 | 0 | 在这一列之后画竖线；0 不画 |
| `scroll-lines` | 1–100 | 3 | 鼠标滚轮每格滚动的行数 |
| `mouse` | true/false | true | 关闭后终端恢复自己的文本选择 |
| `trim-trailing-whitespace` | true/false | true | 保存时去掉上次加载或保存以来编辑过的行的行尾空白 |
| `final-newline` | true/false | true | 保存时给有内容的文件补上末尾换行 |
| `auto-reload` | true/false | true | 磁盘上变化了的文件没有未保存编辑时自动重新加载 |
| `clipboard` | system/internal | system | internal 时复制和粘贴不经过系统剪贴板 |

`set` 在解析命令行时就按类型检查取值，所以错误在命令执行前报告，Application 收到的永远是合法值。布尔值也接受 yes/no、on/off。`set` 和 `set-local` 的选项名可以在命令行中补全，候选附带说明。

配置文件中的 `set` 和 `display` 在启动时依次执行，失败的行与其他配置错误一起按行号报告。`set-local` 在配置文件中无效，因为启动时还没有确定的文档。

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

- **时机**：Application 在更新中带出打开、新建和关闭通知；Runtime 根据保存结果产生 `save`，并在每次输入、命令或后台完成之后比较模式和当前视图，产生 `mode` 和 `focus`。钩子在触发它的整个操作完成之后执行。
- **作用对象**：`open`、`new` 和 `save` 的命令作用于触发它的文档的视图，即使它不在当前窗口，所以 `set-local` 设置的是那个文档；其余事件作用于当前视图。钩子移动焦点后，后续命令跟随新的焦点。
- **消息**：钩子命令不设置消息时，保留触发它的操作留下的消息（如 "Saved …"）。
- **嵌套**：钩子执行的命令可以再触发钩子，连续 16 轮之后停止并报错。
- **展开**：COMMAND 中的 `%opt`、`%val` 在钩子执行时展开。

按语言的设置通过钩子表达，不另设作用域：`hook open .*\.py set-local indent-width 4`。

## Lua

启动时，配置文件 `init` 之后加载同一目录下的 `init.lua`；该目录下 `lua/` 中的模块可以用 `require` 加载。命令行上 `lua CODE` 执行一段 Lua。Lua 通过全局的 `soda` 表操作编辑器：

| 函数 | 作用 |
| --- | --- |
| `soda.command(line)` | 执行一条命令行，与 `:` 相同；返回是否成功和当前消息 |
| `soda.val(name)` / `soda.option(name)` | 读取 `%val{name}` / `%opt{name}` |
| `soda.message(text)` | 设置状态消息 |
| `soda.flag(group, face, sign, lines)` / `soda.unflag([group])` | 行标记，`lines` 是从 1 开始的行号数组；`unflag` 没有标记可去时不报错 |
| `soda.hook(event, filter, fn)` | 事件发生时以事件参数调用 `fn` |
| `soda.define_command(name, fn)` | 定义命令，调用时把参数文本整体传给 `fn` |
| `soda.results(kind, lines)` | 把结果行写入 `*kind*` 并设为最近的结果，回车和 `]q`/`[q` 与 `grep`、`run` 的结果相同；`lines` 可以是 `路径:行:列:` 行，或文件名行加缩进的 `行:列  文本` 分组行；其他行留作标题，一个位置都没有时只显示消息 |
| `soda.open(path, [line], [column])` | 打开文件并放置光标，行列从 1 开始，列按字节；打开是异步的，文件内容要在之后的请求里读 |
| `soda.spawn(argv, fn, [input])` | 在项目根目录后台运行程序（不经过 shell），结束后调用 `fn(code, stdout, stderr)`；`input` 写入标准输入 |

- **执行模型**：Lua 运行在编辑器线程上，同一时间只运行一个请求（一段代码、一次钩子或命令调用、一个进程的回调）。请求运行时 `soda` 的函数直接作用于编辑器。请求中引发的 Lua（例如 `soda.command` 触发的钩子、执行的 `lua` 命令）排队，等当前请求返回后运行。
- **作用对象**：每个请求在它产生时所在的视图上运行，就像钩子一样。所以 `soda.spawn` 的回调作用于调用 `spawn` 时的文档，即使用户已经切换到别的文档；焦点不因此改变。
- **错误**：Lua 错误以 `lua: ` 开头显示在消息行并写入 `*messages*`，不影响编辑器继续运行。
- **钩子和命令**：`soda.hook` 和 `soda.define_command` 保存 Lua 函数本身，在命令表和钩子中表现为 `lua-call ID`。钩子的事件参数也可以在命令行钩子中用 `%val{hook}` 读取。

示例：`lua/git-flags.lua` 在打开和保存时运行 `git diff -U0`，用行标记标出新增、修改和删除的行，约 40 行。`lua/clang-format.lua` 用 clang-format 格式化文档或 Visual 选中的行，只替换有变化的行。`lua/comment.lua` 切换行注释，`lua/surround.lua` 在 Visual 选区两侧加上成对的文本。`lua/git-changes.lua` 把 `git diff` 的每个改动块列入 `*changes*`。

### 文档

`soda.buffer()` 返回当前文档的句柄。句柄只记住文档编号，可以保存到以后的请求中使用；文档关闭后，它的方法报错。

| 方法 | 作用 |
| --- | --- |
| `buf:text()`、`buf:text(from, to)` | 全文或一段范围的文本 |
| `buf:line(n)` | 第 n 行的文本，不含换行 |
| `buf:line_count()` | 行数；最后一个换行之后的空行不算，与 Vim 相同 |
| `buf:revision()` | 文本修订号，文本每次改变都变化 |
| `buf:selection()` | 返回 anchor 和 head 两个位置 |
| `buf:set_selection(anchor, head?)` | 设置选区；省略 head 时为 caret |
| `buf:edit(changes, revision?)` | 应用编辑，返回新的修订号 |
| `buf:indent(n)` | 语言给第 n 行的缩进字符串；语言不给出时为 nil |
| `buf:line_comment()` | 该语言的行注释标记，来自语言配置；C++ 为 `//`；没有行注释时为 nil |
| `buf:offset(position)`、`buf:point(offset)` | 位置与字节偏移互相转换 |

- **坐标**：位置是 `{line, column}`，都从 1 开始，列按字节计，与 `string.sub` 一致。范围由两个位置组成，不包含第二个位置。行尾文本之后的列合法，`{line_count() + 1, 1}` 在文本以换行结束时也合法。字节偏移同样从 1 开始。位置严格校验：超出文档或落在字符内部都会报错，不做 clipping。
- **编辑**：`changes` 是 `{ {from, to, text}, ... }`，所有位置都相对同一份修订，范围不能重叠。传入 `revision` 时，文档已经变化就报错；`soda.spawn` 的回调应该这样做，因为进程运行期间用户可能继续编辑。
- **撤销**：一次请求对一个文档的全部编辑合并成一个撤销步。钩子是单独的请求，所以它的编辑自成一步，不并入 Insert 模式的输入。
- **作用视图**：选区属于视图。请求所在的视图显示该文档时用它，否则用屏幕上的视图，再否则用任一视图。
- **选区与模式**：选区是半开区间，Visual 模式下读到的范围就是选中的文本。按行选中时范围的终点在下一行行首，把选区换算成行号要去掉这一行。Normal 模式只有 caret，设置范围选区后会收缩到范围起点。Visual 模式下设置与之不符的选区、或编辑当前文档，会回到 Normal。

## 实施顺序

1. **选项**：选项表与作用域、`set`/`set-local`/`unset-local`；把现有写死的值改为选项（纯文本缩进、行号、滚轮行数、鼠标、系统剪贴板）。（已完成）
2. **展开**：`%opt{}`、`%val{}`，用户命令改为逐条展开。（已完成）
3. **钩子**：通知、`hook`/`unhook`，配置文件中可用。（已完成）
4. **脚本语言**：Lua 5.4（mlua），`soda` 表、函数钩子与命令、后台进程。（已完成）
