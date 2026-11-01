# 语言服务器

Rust 只负责协议：启动进程、JSON-RPC、让服务器手里的文档保持最新（`src/runtime/lsp.rs`）。问服务器什么、怎么用它的回答，都在 Lua 里（`lua/lsp.lua`），和其他扩展走同一套接口。

## 默认行为

C++ 文档打开时启动 clangd，带 `--header-insertion=never` 和 `--function-arg-placeholders=1`，工作目录是文件根目录。其他语言要自己指定：

```lua
soda.lsp.server("rust", { "rust-analyzer" })
soda.lsp.server("cpp", nil)  -- 不用 clangd
```

rust-analyzer 默认不开，因为它会运行项目的构建脚本，打开一个文件不应该做这件事。clangd 打开项目时可能在项目里写 `.cache/clangd`。

| 键 | 命令 | 作用 |
| --- | --- | --- |
| `<a-.>` | `lsp-definition` | 到定义，有多处时列出；`<a-,>` 回来 |
| `<a-?>` | `lsp-references` | 列出引用 |
| `K` | `lsp-hover` | 在消息行显示光标处的信息，压成一行 |
| `<space>c` / `<space>C` | `lsp-callers` / `lsp-callees` | 列出调用者 / 被调用者，只有一层 |
| | `lsp-diagnostics` | 列出所有诊断 |
| | `lsp-restart` | 重启当前语言的服务器，失败后也用它重试 |

列表是普通的结果文档，`]q` / `[q` 和回车都能用。诊断在行号栏显示：错误 `E`，其余 `W`。补全不需要配置，服务器在就是一个来源，`.`、`->`、`::` 触发。

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

作用对象是当前文档的语言的服务器。JSON 的 `null` 在 Lua 里是 `nil`。

## 限制

- 根目录固定是文件根目录，不按文件找 `compile_commands.json` 所在的项目；clangd 自己会按文件找。同一种语言只有一个服务器，也就是不支持同时开多个项目。
- 不发 `didSave`、不取消请求、不做重命名和代码动作。
- 调用层级只有一层，不是 ccls 那样可以展开的树。
- 诊断没有内联显示，看内容要用 `lsp-diagnostics`。
- hover 压成一行，长内容会被消息行截断。
