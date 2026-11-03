# 语言服务器

Rust 只负责协议：启动进程、JSON-RPC、让服务器手里的文档保持最新（`src/runtime/lsp.rs`）。问服务器什么、怎么用它的回答，都在 Lua 里（`lua/lsp.lua`），和其他扩展走同一套接口。

## 默认行为

C++ 文档打开时启动 clangd，带 `--function-arg-placeholders=1`，工作目录是文档的项目根目录。其他语言要自己指定：

```lua
soda.lsp.server("rust", { "rust-analyzer" })
soda.lsp.server("cpp", nil)  -- 不用 clangd
soda.lsp.server("cpp", { "ccls" }, {
  init = { cache = { directory = "/tmp/ccls" }, compilationDatabaseDirectory = "build" },
  settings = { ... },
  roots = { ".ccls", "compile_commands.json" },
})
```

第三个参数可选：
- `init`：`initialize` 的 `initializationOptions`。
- `settings`：服务器用 `workspace/configuration` 要设置时，按 `section` 的点分路径从这里取，没有的部分回答 null，不带 `section` 时给整张表；服务器启动后也用 `workspace/didChangeConfiguration` 发一次。
- `roots`：根目录标记。文档所在目录往上，最近的含有其中任一文件或目录的目录就是服务器的根目录，没有找到时用项目根目录。只影响服务器，`grep` 等仍按项目；通过跳转打开的文档仍跟随来源的服务器。

rust-analyzer 默认不开，因为它会运行项目的构建脚本，打开一个文件不应该做这件事。clangd 打开项目时可能在项目里写 `.cache/clangd`。

| 键 | 命令 | 作用 |
| --- | --- | --- |
| `<a-.>` | `lsp-definition` | 到定义，有多处时列出；`<a-,>` 回来 |
| | `lsp-declaration` / `lsp-type-definition` | 到声明 / 到类型的定义 |
| `<a-?>` | `lsp-references` | 列出引用 |
| `SPC h` | `lsp-switch` | 在头文件和源文件之间切换，clangd 的扩展 |
| `SPC s` | `lsp-symbols` | 从当前文档的符号大纲里选一个跳过去 |
| `SPC S` | `lsp-workspace-symbols [QUERY]` | 在项目里按名字找符号并列出 |
| `SPC k` | `lsp-hover` | 在光标旁的浮窗里显示光标处的信息，上面列出这一行的诊断；PageUp/PageDown 或 `<a-v>`/`<c-v>` 翻页，其他按键关闭 |
| `SPC c` / `SPC C` | `lsp-callers` / `lsp-callees` | 列出调用者 / 被调用者，只有一层 |
| `SPC R` | `lsp-rename [NAME]` | 重命名光标处的符号；没给名字时打开命令行，预填光标处的词 |
| `SPC a` | `lsp-code-action` | 列出光标或选区处的代码动作，选一个执行 |
| | `lsp-format` | 让服务器格式化整个文档，clangd 读 `.clang-format` |
| | `lsp-diagnostics` | 列出所有诊断 |
| | `lsp-restart` | 重启当前语言的服务器，失败后也用它重试 |

列表是普通的结果文档，`]q` / `[q` 和回车都能用。诊断在行号栏按级别显示：错误 `E`、警告 `W`、其余 `I`，一行有多条时显示最严重的，范围加彩色下划线，消息的第一行显示在行尾（选项 `inline-notes`，见[界面](ui.md)），光标所在行的诊断完整显示在消息行（有其他消息时让位），状态栏显示文档的错误和警告数。

补全不需要配置，服务器在就是一个来源，`.`、`->`、`::` 触发。候选带的其他修改（`additionalTextEdits`）随它一起做，clangd 因此在补全一个没有 include 的名字时加上 `#include`，这类候选的名字前有 `•`。服务器给出的范围决定替换多少：Enter 用 insert 范围，Tab 用 replace 范围；只有一个范围时它是 Enter 的，Tab 仍替换到词尾。候选的 commit 字符（`commitCharacters`，或列表的默认值、服务器的 `allCommitCharacters`）在选中它之后输入时先确认它，再输入这个字符。服务器支持 `completionItem/resolve` 时，选中的候选再问一次，拿到的说明显示在列表旁边。

输入 `(` 或 `,` 时，正在调用的函数签名显示在消息行，当前参数加方括号，输入 `)` 或离开 Insert 时消失。没有其他消息时才显示，优先于光标处的诊断。光标用方向键移出括号时不会消失，到下一次 `)` 或离开 Insert 为止。

服务器支持时，语义高亮和 inlay hint 随诊断一起刷新：服务器处理完一次修改就发诊断，这时再问。切换到另一个文档时也问一次。服务器支持 delta 时，语义高亮第一次取全文，之后只取相对上一次的修改，在 Lua 里拼回完整的 token 数组。

语义高亮盖在词法高亮上，区分类型、函数、参数、命名空间、宏和枚举值，clangd 判定为不活跃的预处理分支显示成注释。普通变量和成员没有自己的颜色。编辑时 token 随文本移动，直到新的回答替换它，所以不闪烁。

inlay hint（参数名、`auto` 的类型）用斜体灰色显示在文字之间，不是文档内容：不能选中，不影响保存；光标、横向滚动和鼠标都按文字算，点在 hint 上等于点它后面的字符。开了 `wrap` 时 hint 集中显示在行尾，否则会把文字挤出屏幕。选项 `inlay-hints` 关闭显示。

保存时发 `didSave`，clangd 因此重新检查依赖这个头文件的已打开文档。

## 编辑

重命名和代码动作的编辑可以跨文件。已打开的文档直接在缓冲区里改，一次一步撤销，改完不保存；没打开的文件直接写到磁盘，不能撤销，只能靠版本库恢复。消息行报告改了几个文件、其中几个写到了磁盘。

编辑也可以创建、改名和删除文件或目录（`documentChanges` 里的 `create`、`rename`、`delete`），按给出的顺序做，后面的文字修改可以针对前面刚创建或改名的文件。打开着的文档跟着改名换路径，服务器收到旧 URI 的 `didClose` 和新 URI 的 `didOpen`；被删除或被改名覆盖的文档关闭，未保存的修改丢弃。`overwrite`、`ignoreIfExists`、`ignoreIfNotExists` 和 `recursive` 按协议处理。

编辑做完后告诉服务器碰过哪些磁盘上的文件（已打开文档的修改由 `didChange` 送达）：
- 服务器用 `client/registerCapability` 注册了文件监视时，写入、创建、删除的文件按监视的 glob 和种类发 `workspace/didChangeWatchedFiles`；改名算作旧名删除、新名创建。glob 支持 `*`、`?`、`**`、`[...]`、`{a,b}`，以及带 `baseUri` 的相对模式。
- 服务器声明了 `workspace.fileOperations` 时，按它的过滤条件发 `didCreateFiles`、`didRenameFiles`、`didDeleteFiles`，区分文件和目录（`matches`），支持 `ignoreCase`。

中途失败时，已经做了的部分照样通知。

应用之前先按顺序推演一遍：等服务器回答期间当前文档变了、有文件读不出来、要改的文件不存在、要创建的已经存在而没有允许覆盖，整个编辑都不应用，消息行说明原因。动手之后失败（比如写磁盘失败）则显示 `Partly applied`，这时前面的步骤已经做了。

clangd 的重构类动作是命令：执行后由服务器发来 `workspace/applyEdit`，走同一段代码，回答里的 `applied` 是编辑是否真的应用了。

## 同步

第一个该语言的文件文档触发启动，无头 Runtime 除非调用 `enable_lsp`，否则不启动服务器。文档每次都发全文：停止输入 150 ms 后发送，发请求之前也先发，所以服务器不会回答旧文本。JSON 在写线程上生成，大文档不影响按键；clangd 收到增量也要重新解析，全量同步的代价只在序列化。

同一用途的新请求发出时，取消还在等的旧请求：同一个命令再执行一次、补全会话换了、文档又改了以后的语义高亮和 inlay hint。取消发 `$/cancelRequest`，旧请求的回答到了也丢弃。

服务器发来的请求见下面的 Lua 接口。启动失败或者进程退出时报告一次，不自动重启。编辑器退出时结束服务器；被 SIGKILL 时服务器读到 stdin 结束，自己退出。

列位置优先协商 UTF-8，服务器不支持时用 UTF-16，转换在 `lua/lsp.lua` 里。

## Lua 接口

```lua
soda.lsp.server(language, command)            -- nil 表示去掉
soda.lsp.request(method, params, function(result, error) end, [buf])  -- 返回请求编号；没有服务器时返回 false
soda.lsp.cancel(id)                           -- 发 $/cancelRequest，之后到的回答丢弃；回答已经到了时返回 false
soda.lsp.notify(method, params, [buf])
soda.lsp.on(method, function(params) end)     -- 服务器的通知和请求；对请求返回的值就是回答
soda.lsp.uri()                                -- 当前文档的 URI
soda.lsp.info([buf])                          -- encoding、capabilities、watchers；没有服务器时为 nil
soda.lsp.restart()
soda.lsp.array(t)                             -- 标记 t 是数组
```

诊断和浮窗走通用接口，别的扩展也能用：

```lua
soda.note(group, {
  { from = { 2, 5 }, to = { 2, 9 }, severity = "warning", text = "..." },  -- 行、字节列，从 1 起
})                  -- 替换这一组；空表清除。severity 是 error、warning 或 info
soda.tokens(data, names)  -- 语义高亮：data 是扁平数组，每四项为行、起止字节（都从 0 起）和 names 的下标（从 0 起）
soda.inlays({ { line = 2, column = 5, text = "a: " } })  -- 替换 inlay hint，行和字节列从 1 起
soda.hint(text)     -- 消息行没有消息时显示，直到换掉；nil 清除
soda.prompt(text)   -- 打开命令行，预填 text
soda.choose(title, items, function(index) end)  -- 从 items 里选一项，取消时不调用
soda.popup(text)    -- 光标旁的浮窗，放不下时滚轮或翻页键滚动，边框上显示位置，其他按键关闭
```

作用对象是当前文档的语言的服务器；给了 `buf`（`soda.buffer()` 的句柄）时是那个文档的，比如树或结果文档本身没有服务器，展开节点时要问来源文档的服务器。

`require("lsp")` 返回 `lua/lsp.lua` 的辅助函数，给针对某个服务器扩展的模块用：`path_of`、`uri_of`、`relative`、`to_byte`、`to_character`、`here`、`send`（同一用途的新请求取消旧请求）、`supports`、`failed`、`show`、`location_entry`、`open_location`。

服务器发来的请求，有 `soda.lsp.on` 函数时交给它们，依次调用，第一个返回非 nil 的值作为回答；都返回 nil 或出错时回答默认值：`workspace/applyEdit` 为 `{ applied = true }`，`workspace/configuration` 按 `settings` 回答，其余为 null。服务器在拿到回答前等着，所以函数要立刻返回。没有函数的请求直接回答默认值。`workspace/applyEdit` 由 `lua/lsp.lua` 处理，回答编辑是否真的应用了。

服务器没有声明某项能力（如 `callHierarchyProvider`、`workspaceSymbolProvider`）时，对应的命令直接说明，不发请求；服务器回答方法不存在（clangd 的扩展 `switchSourceHeader` 在别的服务器上就是这样）时也一样。补全和签名提示这类自动的请求则静默跳过。JSON 的 `null` 在 Lua 里是 `nil`。Lua 的空表发出去是对象 `{}`，协议要空数组的地方用 `soda.lsp.array({})`；从服务器收到的数组不需要标记。

## 项目与服务器

每个 `(语言, 根目录)` 一个服务器，所以同时开多个项目互不影响。文档的服务器按下面的顺序决定，详见[文档的位置](interaction.md#文档的位置)：

1. 通过跳转第一次打开的文档，用跳转来源的服务器，即使它在另一个 git 仓库里：只有那个服务器有编译参数。这同样适用于从那里继续跳转。
2. 否则用文档的项目根目录；没有项目时用文件所在目录，所以 `/tmp` 下的单个文件也有服务器。

跳到已经打开的文档时不改变它的服务器，除非它不属于任何项目。历史回跳（`<a-,>`）不算跳转。

## ccls

```lua
require("ccls").setup({
  init = { cache = { directory = "/tmp/ccls" }, compilationDatabaseDirectory = "build" },
})
```

`setup` 让 C++ 改用 ccls（`command` 可以换程序，`languages` 默认 `{ "cpp" }`），`init`、`settings` 原样传给 `soda.lsp.server`，`roots` 默认 `.ccls-root`、`.ccls`、`compile_commands.json`，找不到时用项目根目录。标准功能和 clangd 一样走 `lsp` 模块；ccls 没有的（如 `SPC h` 头文件切换）会直接说明。

| 键 | 命令 | 作用 |
| --- | --- | --- |
| `SPC c` / `SPC C` | `ccls-callers` / `ccls-callees` | 调用者 / 被调用者的树（`$ccls/call`），替换 `lsp` 模块的一层列表 |
| `SPC t` / `SPC T` | `ccls-base` / `ccls-derived` | 基类 / 派生类的树（`$ccls/inheritance`） |
| `SPC m` / `SPC M` | `ccls-members variables` / `functions` | 成员变量 / 成员函数的树（`$ccls/member`），还可以是 `types` |
| | `ccls-vars` | 列出光标处类型的变量（`$ccls/vars`） |
| | `ccls-navigate up/down/left/right` | 按语法树移动到外层、第一个内层、前后相邻的声明（`$ccls/navigate`） |
| | `ccls-reload` | 让 ccls 重新索引项目 |

树每次只取一层：根节点是光标处的符号，展开一个节点时按它的 `id` 再问一层，键见[树](extension.md#树)。`setup({ keys = false })` 不绑定键。

ccls 发来的 `$ccls/publishSkippedRanges`（没有参与编译的预处理分支）用 `dim` 颜色画出，随编辑移动，下次通知时替换。

## 限制

- 没有 `roots` 时，服务器的根目录就是项目根目录，由版本库标记决定，不按 `compile_commands.json` 找；clangd 自己会按文件找。
- 内置的调用层级只有一层；可以展开的树要用 `soda.tree` 自己写。
- 不发 `willCreateFiles`、`willRenameFiles`、`willDeleteFiles`：这几个请求要等服务器回答一个编辑再动手，而文件操作本身就来自服务器的编辑。目录改名只报告目录本身，不展开成其中每个文件。
- `completionItem/resolve` 只取说明和 detail；候选的其他修改要在列表里就给出。
