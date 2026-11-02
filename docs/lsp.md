# 语言服务器

Rust 只负责协议：启动进程、JSON-RPC、让服务器手里的文档保持最新（`src/runtime/lsp.rs`）。问服务器什么、怎么用它的回答，都在 Lua 里（`lua/lsp.lua`），和其他扩展走同一套接口。

## 默认行为

C++ 文档打开时启动 clangd，带 `--header-insertion=never` 和 `--function-arg-placeholders=1`，工作目录是文档的项目根目录。其他语言要自己指定：

```lua
soda.lsp.server("rust", { "rust-analyzer" })
soda.lsp.server("cpp", nil)  -- 不用 clangd
```

rust-analyzer 默认不开，因为它会运行项目的构建脚本，打开一个文件不应该做这件事。clangd 打开项目时可能在项目里写 `.cache/clangd`。

| 键 | 命令 | 作用 |
| --- | --- | --- |
| `<a-.>` | `lsp-definition` | 到定义，有多处时列出；`<a-,>` 回来 |
| | `lsp-declaration` / `lsp-type-definition` | 到声明 / 到类型的定义 |
| `<a-?>` | `lsp-references` | 列出引用 |
| `<space>h` | `lsp-switch` | 在头文件和源文件之间切换，clangd 的扩展 |
| `<space>s` | `lsp-symbols` | 从当前文档的符号大纲里选一个跳过去 |
| `<space>S` | `lsp-workspace-symbols [QUERY]` | 在项目里按名字找符号并列出 |
| `K` | `lsp-hover` | 在光标旁的浮窗里显示光标处的信息，上面列出这一行的诊断；PageUp/PageDown 或 `<a-v>`/`<c-v>` 翻页，其他按键关闭 |
| `<space>c` / `<space>C` | `lsp-callers` / `lsp-callees` | 列出调用者 / 被调用者，只有一层 |
| `<space>R` | `lsp-rename [NAME]` | 重命名光标处的符号；没给名字时打开命令行，预填光标处的词 |
| `<space>a` | `lsp-code-action` | 列出光标或选区处的代码动作，选一个执行 |
| | `lsp-format` | 让服务器格式化整个文档，clangd 读 `.clang-format` |
| | `lsp-diagnostics` | 列出所有诊断 |
| | `lsp-restart` | 重启当前语言的服务器，失败后也用它重试 |

列表是普通的结果文档，`]q` / `[q` 和回车都能用。诊断在行号栏按级别显示：错误 `E`、警告 `W`、其余 `I`，一行有多条时显示最严重的，范围加彩色下划线，光标所在行的诊断自动显示在消息行（有其他消息时让位），状态栏显示文档的错误和警告数。补全不需要配置，服务器在就是一个来源，`.`、`->`、`::` 触发。

输入 `(` 或 `,` 时，正在调用的函数签名显示在消息行，当前参数加方括号，输入 `)` 或离开 Insert 时消失。没有其他消息时才显示，优先于光标处的诊断。光标用方向键移出括号时不会消失，到下一次 `)` 或离开 Insert 为止。

保存时发 `didSave`，clangd 因此重新检查依赖这个头文件的已打开文档。

## 编辑

重命名和代码动作的编辑可以跨文件。已打开的文档直接在缓冲区里改，一次一步撤销，改完不保存；没打开的文件直接写到磁盘，不能撤销，只能靠版本库恢复。消息行报告改了几个文件、其中几个写到了磁盘。

应用之前先检查：等服务器回答期间当前文档变了，或者有文件读不出来，整个编辑都不应用。写磁盘时失败则显示 `Partly applied`，这时已打开的文档和前面的文件已经改了。

clangd 的重构类动作是命令：执行后由服务器发来 `workspace/applyEdit`，走同一段代码。Rust 先回答 `applied: true`，再交给 Lua，所以失败时服务器不知道，但消息行会显示。

## 同步

第一个该语言的文件文档触发启动，无头 Runtime 除非调用 `enable_lsp`，否则不启动服务器。文档每次都发全文：停止输入 150 ms 后发送，发请求之前也先发，所以服务器不会回答旧文本。JSON 在写线程上生成，大文档不影响按键；clangd 收到增量也要重新解析，全量同步的代价只在序列化。

服务器发来的请求一律回答空值（`workspace/configuration` 回答等长的空数组）。启动失败或者进程退出时报告一次，不自动重启。编辑器退出时结束服务器；被 SIGKILL 时服务器读到 stdin 结束，自己退出。

列位置优先协商 UTF-8，服务器不支持时用 UTF-16，转换在 `lua/lsp.lua` 里。

## Lua 接口

```lua
soda.lsp.server(language, command)            -- nil 表示去掉
soda.lsp.request(method, params, function(result, error) end)  -- 没有服务器时返回 false
soda.lsp.notify(method, params)
soda.lsp.on(method, function(params) end)     -- 服务器的通知
soda.lsp.uri()                                -- 当前文档的 URI
soda.lsp.info()                               -- encoding、capabilities；没有服务器时为 nil
soda.lsp.restart()
soda.lsp.array(t)                             -- 标记 t 是数组
```

诊断和浮窗走通用接口，别的扩展也能用：

```lua
soda.note(group, {
  { from = { 2, 5 }, to = { 2, 9 }, severity = "warning", text = "..." },  -- 行、字节列，从 1 起
})                  -- 替换这一组；空表清除。severity 是 error、warning 或 info
soda.hint(text)     -- 消息行没有消息时显示，直到换掉；nil 清除
soda.prompt(text)   -- 打开命令行，预填 text
soda.choose(title, items, function(index) end)  -- 从 items 里选一项，取消时不调用
soda.popup(text)    -- 光标旁的浮窗，放不下时滚轮或翻页键滚动，边框上显示位置，其他按键关闭
```

作用对象是当前文档的语言的服务器。JSON 的 `null` 在 Lua 里是 `nil`。Lua 的空表发出去是对象 `{}`，协议要空数组的地方用 `soda.lsp.array({})`；从服务器收到的数组不需要标记。

## 项目与服务器

每个 `(语言, 根目录)` 一个服务器，所以同时开多个项目互不影响。文档的服务器按下面的顺序决定，详见[文档的位置](interaction.md#文档的位置)：

1. 通过跳转第一次打开的文档，用跳转来源的服务器，即使它在另一个 git 仓库里：只有那个服务器有编译参数。这同样适用于从那里继续跳转。
2. 否则用文档的项目根目录；没有项目时用文件所在目录，所以 `/tmp` 下的单个文件也有服务器。

跳到已经打开的文档时不改变它的服务器，除非它不属于任何项目。历史回跳（`<a-,>`）不算跳转。

## 限制

- 项目根目录由版本库标记决定，不按 `compile_commands.json` 找；clangd 自己会按文件找。服务器的根目录标记还不能按语言配置。
- 不取消请求。
- 不做 inlay hint 和语义高亮。
- 调用层级只有一层，不是 ccls 那样可以展开的树。
- 诊断显示在消息行和 `K` 的浮窗里，不在行尾内联显示。
- 编辑直接写到磁盘的文件不通知服务器，它要到下次读这些文件时才知道。
- 不支持创建、改名、删除文件的编辑；遇到时整个编辑都不应用。
