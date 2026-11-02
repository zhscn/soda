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
| `<a-?>` | `lsp-references` | 列出引用 |
| `K` | `lsp-hover` | 在光标旁的浮窗里显示光标处的信息，上面列出这一行的诊断；下一个按键关闭 |
| `<space>c` / `<space>C` | `lsp-callers` / `lsp-callees` | 列出调用者 / 被调用者，只有一层 |
| | `lsp-diagnostics` | 列出所有诊断 |
| | `lsp-restart` | 重启当前语言的服务器，失败后也用它重试 |

列表是普通的结果文档，`]q` / `[q` 和回车都能用。诊断在行号栏显示错误 `E`、其余 `W`，范围加彩色下划线，光标所在行的诊断自动显示在消息行（有其他消息时让位），状态栏显示文档的错误和警告数。补全不需要配置，服务器在就是一个来源，`.`、`->`、`::` 触发。

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
```

诊断和浮窗走通用接口，别的扩展也能用：

```lua
soda.note(group, {
  { from = { 2, 5 }, to = { 2, 9 }, severity = "warning", text = "..." },  -- 行、字节列，从 1 起
})                  -- 替换这一组；空表清除。severity 是 error、warning 或 info
soda.popup(text)    -- 光标旁的浮窗，下一个按键关闭，放不下的部分截断
```

作用对象是当前文档的语言的服务器。JSON 的 `null` 在 Lua 里是 `nil`。

## 项目与服务器

每个 `(语言, 根目录)` 一个服务器，所以同时开多个项目互不影响。文档的服务器按下面的顺序决定，详见[文档的位置](interaction.md#文档的位置)：

1. 通过跳转第一次打开的文档，用跳转来源的服务器，即使它在另一个 git 仓库里：只有那个服务器有编译参数。这同样适用于从那里继续跳转。
2. 否则用文档的项目根目录；没有项目时用文件所在目录，所以 `/tmp` 下的单个文件也有服务器。

跳到已经打开的文档时不改变它的服务器，除非它不属于任何项目。历史回跳（`<a-,>`）不算跳转。

## 限制

- 项目根目录由版本库标记决定，不按 `compile_commands.json` 找；clangd 自己会按文件找。服务器的根目录标记还不能按语言配置。
- 不发 `didSave`、不取消请求、不做重命名和代码动作。
- 调用层级只有一层，不是 ccls 那样可以展开的树。
- 诊断没有内联显示，看内容要用 `lsp-diagnostics`。
- hover 压成一行，长内容会被消息行截断。
