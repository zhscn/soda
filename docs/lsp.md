# 语言服务器

Rust 只管协议：启动进程、JSON-RPC、让服务器手里的文档保持最新（`src/runtime/lsp.rs`）。问什么、怎么用回答都在 Lua 里（`lua/lsp.lua`），和其他扩展走同一套接口。

## 配置

没有内置的服务器，C++ 也一样：在 `init.lua` 里指定，或由模块指定（如 `require("ccls").setup({})`）。

```lua
soda.lsp.server("cpp", { "clangd", "--function-arg-placeholders=1" })
soda.lsp.server("cpp", nil)  -- 去掉
soda.lsp.server("go", { "gopls" }, { roots = { "go.mod" } })
-- cargo workspace 的根不是最近的 Cargo.toml，问 cargo
soda.lsp.server("rust", { "rust-analyzer" }, {
  roots = function(path, done)
    local dir = path:match("^(.*)/[^/]*$")
    soda.spawn({ "cargo", "metadata", "--no-deps", "--format-version", "1" }, function(code, out)
      done(code == 0 and out:match('"workspace_root":"([^"]*)"') or false)
    end, { cwd = dir })
  end,
})
```

| 第三个参数的字段 | 作用 |
| --- | --- |
| `init` | `initialize` 的 `initializationOptions` |
| `settings` | 回答 `workspace/configuration`：按 `section` 的点分路径取，没有的回答 null，不带 `section` 时给整张表；启动后也用 `workspace/didChangeConfiguration` 发一次 |
| `roots` | 根目录标记：从文档所在目录往上，最近的含有其中任一文件或目录的目录；`"git"` 指 git 工作树顶层（`.git` 是文件的 submodule、linked worktree 也算）。也可以是函数 `function(path, done)`：返回目录，返回 `false` 表示没有，或返回 nil 之后调用 `done(目录或 false)`；回答之前这个文档不启动服务器。只影响服务器，`grep` 等仍按项目 |
| `name` | 服务器的名字，默认是程序的文件名；`soda.keymap(..., { server = NAME })` 声明的键位表按它生效，所以经包装脚本启动时要写明 |
| `auto` | 打开文档时是否自动启动：`false`（默认）只由 `lsp-start` 启动；`"marked"` 在根目录是找到的（标记、函数或跳转来源）时；`true` 总是 |

默认和 eglot 一样，配置只说明用哪个服务器，打开文档不启动任何进程：在文档里执行 `lsp-start`（像 `M-x eglot`）才在它的根目录启动，之后这个根目录下这种语言的文档都归它，已经打开的和之后打开的都是。rust-analyzer 会运行构建脚本，clangd 可能写 `.cache/clangd`，ccls 写 `.ccls-cache`，所以要不要自动启动由配置决定：想打开即启动的（像 `eglot-ensure`）设 `auto`，按项目建索引的适合 `"marked"`。

## 命令

`M-.`、`M-?` 是 xref 的键，绑在 `lsp` 键位表里，只在有服务器服务的文档中生效（见[键位上下文](interaction.md#键位上下文)）；其他文档里按下它们是未定义的键，命令本身照样可以执行。其余命令和 Emacs 的 eglot 一样没有键（`C-c` 加字母留给用户），绑到同一张表里：`soda.map("lsp", "C-c k", "lsp-hover")`。下表标着“建议”的键是作者配置里的，供参考。

| 键 | 命令 | 作用 |
| --- | --- | --- |
| `M-.` | `lsp-definition` | 到定义，有多处时列出；`M-,` 回来 |
| | `lsp-declaration` / `lsp-type-definition` | 到声明 / 类型的定义 |
| 建议 `C-c .` | `lsp-implementation` | 到实现（虚函数的覆盖、派生类等） |
| `M-?` | `lsp-references` | 列出引用 |
| 建议 `C-c h` | `lsp-switch` | 头文件与源文件切换（clangd 扩展） |
| 建议 `C-c s` / `C-c S` | `lsp-symbols` / `lsp-workspace-symbols [QUERY]` | 当前文档的符号大纲 / 按名字在项目里找符号 |
| 建议 `C-c k` | `lsp-hover` | 光标旁的浮窗显示光标处的信息，上面列出这一行的诊断 |
| 建议 `C-c c` / `C-c C` | `lsp-callers` / `lsp-callees` | 调用者 / 被调用者的树；回车跳到调用处 |
| 建议 `C-c t` / `C-c T` | `lsp-supertypes` / `lsp-subtypes` | 基类 / 派生类的树；回车跳到声明 |
| 建议 `C-c R` | `lsp-rename [NAME]` | 重命名；没给名字时打开命令行，预填现在的名字（服务器支持 `prepareRename` 时问它，没有可改名的符号就直接说明） |
| 建议 `C-c a` | `lsp-code-action` | 列出光标或选区处的代码动作，选一个执行 |
| | `lsp-format` | 格式化选区，没有选区或服务器不支持范围格式化时格式化整个文档 |
| | `lsp-diagnostics` | 列出所有诊断 |
| | `lsp-restart` | 重启当前语言的服务器，失败后也用它重试 |
| | `lsp-start [DIR]` | 像 eglot：在 `DIR`（默认按规则得到的根目录）启动，之后这个目录下这种语言的文档都归它；也解除 `lsp-stop`；这种语言没有配置服务器时只说明没有 |
| | `lsp-stop` | 停掉当前文档的服务器，清掉它的诊断、语义高亮和 inlay hint；设了 `auto` 的在 `lsp-start` 之前也不再自动启动 |
| | `lsp-servers` | 在 `*servers*` 里列出服务器（语言、根目录、程序、状态）及各自的文档，回车打开 |

层级显示成[树](extension.md#树)：根是光标处的函数或类型，展开一个节点时才问那一层。列表是普通的结果文档，`]q` / `[q` 和回车都能用。服务器没有声明对应能力或回答方法不存在时，命令直接说明，不发请求；补全、签名提示这类自动请求静默跳过。

## 显示

- **诊断**：行号栏按级别标 `E`、`W`、`I`（一行取最严重的），范围加彩色下划线，消息第一行显示在行尾（`inline-notes`，见[界面](ui.md)），光标处的显示在消息行，状态栏显示错误和警告数。`relatedInformation` 以 `路径:行: 文字` 接在消息后。带 `Unnecessary` 标签的范围用 `unnecessary` 变暗，带 `Deprecated` 的用 `deprecated` 加删除线。
- **拉取诊断**：服务器声明 `diagnosticProvider` 时，停止输入 `idle-time` 毫秒后和切换到文档时发 `textDocument/diagnostic`，每个版本最多一次，带上次的 `resultId`；`workspace/diagnostic/refresh` 时重新拉取。
- **补全**：服务器在就是一个来源，`.`、`->`、`::` 触发。`additionalTextEdits` 随候选一起做（clangd 借此补上 `#include`，这类候选名字前有 `•`）。Enter 用 insert 范围，Tab 用 replace 范围；只有一个范围时它归 Enter，Tab 仍替换到词尾。`commitCharacters`（或列表默认值、`allCommitCharacters`）在选中候选后输入时先确认它。支持 `completionItem/resolve` 时，选中的候选再问一次 detail 和说明。
- **签名**：输入 `(` 或 `,` 时，签名显示在消息行，当前参数加方括号；输入 `)` 或离开 Insert 时消失。没有其他消息时才显示，优先于诊断。
- **同符号高亮**：空闲时 `textDocument/documentHighlight` 标出光标处符号的各处，读处 `reference`，写处 `reference-write`；选项 `lsp-highlight` 关闭。
- **语义高亮**：盖在词法高亮上，区分类型、函数、变量、成员、参数、命名空间、宏和枚举值；带 `declaration` 或 `definition` 修饰符的函数、变量、成员分别是 `function.definition`、`variable.definition`、`property.definition`，其余函数是 `function.call`，`defaultLibrary` 的是 `.builtin`（分类见[语法高亮](syntax.md#分类)）；clangd 和 ccls 的类型名都认（ccls 的 `field`、`staticMethod`、`typeAlias` 等）。不活跃的预处理分支（clangd）显示成注释；`readonly` 的变量显示成常量，`deprecated` 修饰符加删除线。支持 delta 时只取增量，在 Lua 里拼回。编辑时 token 随文本移动，直到新回答替换，不闪烁。
- **inlay hint**：斜体灰色显示在文字之间，不是文档内容：不能选中，光标、滚动和鼠标都按文字算。开了 `wrap` 时集中到行尾。选项 `inlay-hints` 关闭。
- 语义高亮和 inlay hint 在服务器发来诊断（即处理完一次修改）和切换文档时刷新。
- **进度与消息**：`$/progress` 显示在状态栏（标题、消息、百分比，多项时取最近开始的）。`window/showMessage` 进消息行，`window/logMessage` 只进日志（`messages`）。`window/showMessageRequest` 只显示，回答为没有选择。`window/showDocument` 打开文档并跳到所给的行，`external` 的不打开。
- 保存时发 `didSave`。

语义 token 的颜色由 `require("lsp").token_category(type, modifiers)` 决定：`modifiers` 是修饰符名字的集合，返回语法分类名（见[语法高亮](syntax.md#分类)），nil 保留词法高亮。可以整个换掉：

```lua
local lsp = require("lsp")
local default = lsp.token_category
lsp.token_category = function(type, modifiers)
  if modifiers.static and type == "method" then
    return "keyword"
  end
  return default(type, modifiers)
end
```

## 编辑

重命名和代码动作的编辑可以跨文件：已打开的文档在缓冲区里改，一次一步撤销，不保存；没打开的直接写磁盘，不能撤销。消息行报告改了几个文件、几个写到磁盘。

- `documentChanges` 的 `create`、`rename`、`delete` 按顺序做，后面的文字修改可以针对刚创建或改名的文件；`overwrite`、`ignoreIfExists`、`ignoreIfNotExists`、`recursive` 按协议处理。打开着的文档跟着改名（服务器收到旧 URI 的 `didClose`、新 URI 的 `didOpen`）；被删除或覆盖的文档关闭，未保存的修改丢弃。
- 应用前先推演一遍：等待期间当前文档变了、文件读不出、要改的不存在、要创建的已存在且不允许覆盖，都整个不应用并说明原因。动手后失败（如写磁盘失败）显示 `Partly applied`。
- 做完后通知碰过的磁盘文件，失败时已做的部分照样通知：注册了文件监视的，按 glob（`*`、`?`、`**`、`[...]`、`{a,b}`、带 `baseUri` 的相对模式）和种类发 `workspace/didChangeWatchedFiles`，改名算旧名删除、新名创建；声明了 `workspace.fileOperations` 的，按过滤条件（区分文件和目录，支持 `ignoreCase`）发 `didCreateFiles`、`didRenameFiles`、`didDeleteFiles`。
- 声明 `codeAction/resolve` 时，不带编辑的代码动作（如 rust-analyzer 的）选中后先问一次。命令式的动作（clangd 的重构）由服务器发回 `workspace/applyEdit`，走同一段代码，回答里的 `applied` 是是否真的应用了。

## 同步

- 服务器由 `lsp-start` 启动，设了 `auto` 的在文档第一次需要它时启动；无头 Runtime 不调用 `enable_lsp` 就不启动。文档的 `(语言, 根目录)` 已有服务器在跑时，文档直接交给它，不看 `auto`。
- 文档总是发全文：停止输入 150 ms 后发，发请求之前也先发，所以服务器不会回答旧文本。JSON 在写线程上生成，大文档不影响按键。
- 同一用途的新请求发出时取消旧的（发 `$/cancelRequest`，迟到的回答丢弃）：同一命令再执行、补全会话换了、文档改了以后的语义高亮和 inlay hint。
- 启动失败时报告一次，不再尝试。运行中退出时报告并重启，重新打开它的文档；3 分钟内第 4 次退出后等 `lsp-restart`。编辑器退出时结束服务器；被 SIGKILL 时服务器读到 stdin 结束自己退出。
- 列位置优先协商 UTF-8，否则 UTF-16，转换在 `lua/lsp.lua` 里。

## Lua 接口

```lua
soda.lsp.server(language, command, [options])  -- command 为 nil 表示去掉
soda.lsp.request(method, params, function(result, error) end, [buf], [raw])  -- 返回请求编号；没有服务器时 false
soda.lsp.cancel(id)                           -- 发 $/cancelRequest；回答已到时返回 false
soda.lsp.notify(method, params, [buf])
soda.lsp.on(method, function(params) end)     -- 服务器的通知和请求
soda.lsp.uri()                                -- 当前文档的 URI
soda.lsp.info([buf])                          -- language、root、encoding、capabilities、watchers；没有服务器时 nil
soda.lsp.restart()
soda.lsp.start([dir])                         -- 同 lsp-start，返回根目录
soda.lsp.stop()                               -- 同 lsp-stop，返回它管的文档的 URI
soda.lsp.servers()                            -- { {language, root, command, state, uris}, ... }
soda.lsp.set_root(buf_id, dir_or_false)       -- 指定文档的服务器根目录；roots 函数的 done 就是它
soda.lsp.array(t)                             -- 标记 t 是数组
```

作用对象是当前文档的语言的服务器；给了 `buf`（`soda.buffer()` 的句柄）时是那个文档的，比如展开树节点时问来源文档的服务器。

服务器发来的请求交给 `soda.lsp.on` 的函数，依次调用，第一个非 nil 的返回值作为回答；都是 nil 或出错时回答默认值：`workspace/applyEdit` 为 `{ applied = true }`，`workspace/configuration` 按 `settings`，其余 null。服务器在等，所以函数要立刻返回。

JSON 的 `null` 在 Lua 里是 `nil`。Lua 的空表发出去是对象 `{}`，要空数组时用 `soda.lsp.array({})`；收到的数组不需要标记。

LSP 模块用的显示原语是通用的（`soda.note`、`soda.hint`、`soda.popup`、`soda.choose`、`soda.prompt`，见[扩展](extension.md#lua)），另有两个专用的：

```lua
soda.tokens(data, names)  -- 语义高亮：扁平数组，每四项为行、起止字节（从 0 起）和 names 的下标（从 0 起）；names 是语法分类名，空串表示不着色
soda.inlays({ { line = 2, column = 5, text = "a: " } })  -- 替换 inlay hint，行和字节列从 1 起
```

整个文档的语义高亮和 inlay hint 很大：6.5 万行的 C++ 文件上，clangd 的回答是 2.8 MB 和 5.4 MB，转成 Lua 表再在 Lua 里逐个处理，主线程要停约 0.5 s。所以 `lua/lsp.lua` 对这两种请求传 `raw`：回答以 JSON 句柄交给 Lua，只取用得到的小部分，大块数据在 Rust 里解码，现在两者合计约 40 ms。

```lua
result:get(key)       -- 字段（或从 1 起的元素）转成 Lua 值
result:numbers(key)   -- 数字数组留在 Rust，得到 numbers 句柄；不是数字数组时 nil
result:decode()       -- 整个回答转成 Lua 值
numbers:edited(edits) -- semanticTokens/full/delta 的 edits 做在旧数据上，得到新句柄；#numbers、numbers[i] 可读
soda.lsp.tokens(data, encoding, function(type, bits) return category, struck end)  -- 解码并替换当前文档的语义高亮；每种 (type, bits) 只问一次，返回划掉的范围给 soda.paint
soda.lsp.inlays(result, encoding)  -- 替换当前文档的 inlay hint，result 是 inlayHint 的回答（句柄或表）
```

inlay hint 按偏移排序保存，编辑时和语义高亮一样一次映射；绘制只为排到的行放置 hint，不每帧走全文档的 hint。

`require("lsp")` 返回给针对某个服务器的模块用的辅助函数：`path_of`、`uri_of`、`relative`、`to_byte`、`to_character`、`here`、`send`（同一用途的新请求取消旧请求）、`supports`、`failed`、`show`、`location_entry`、`open_location`、`token_category`。

## 项目与服务器

每个 `(语言, 根目录)` 一个服务器，多个项目互不影响。文档的服务器按顺序决定（详见[文档的位置](interaction.md#文档的位置)）：

1. 通过跳转第一次打开的文档用来源的服务器，即使在另一个仓库里：只有它有编译参数。从那里继续跳转同样。
2. `lsp-start` 启动过的目录，包含文档的取最深的。
3. `roots` 函数选的目录。
4. `roots` 标记找到的目录。
5. 否则用项目根目录；没有项目时用文件所在目录（`auto = "marked"` 的服务器在这一步不自动启动）。

跳到已打开的文档不改变它的服务器，除非它不属于任何项目。历史回跳（`M-,`）不算跳转。

## ccls

```lua
require("ccls").setup({
  init = { cache = { directory = "/tmp/ccls" }, compilationDatabaseDirectory = "build" },
})
```

`setup` 让 C++ 使用 ccls：`command` 换程序，`languages` 默认 `{ "cpp" }`，`init`、`settings` 原样传给 `soda.lsp.server`，`roots` 默认 `.ccls-root`、`.ccls`、`compile_commands.json`，`auto` 原样传给 `soda.lsp.server`，所以默认由 `lsp-start` 启动；ccls 会给整个根目录建索引，要自动启动时适合 `"marked"`。标准功能走 `lsp` 模块；ccls 没有的（如 `lsp-switch`）直接说明。`setup` 声明 `ccls` 键位表，只在 ccls 服务的文档中生效，同一个键优先于 `lsp` 表。下表的命令没有键，绑到这张表（在 `setup` 之后）：`soda.map("ccls", "C-c v c", "ccls-callers")`。

| 键 | 命令 | 作用 |
| --- | --- | --- |
| 建议 `C-c vc` / `C-c vC` | `ccls-callers` / `ccls-callees` | 调用者 / 被调用者的树（`$ccls/call`），含经由基类和派生类的调用 |
| 建议 `C-c vb` / `C-c vd` | `ccls-base` / `ccls-derived` | 基类 / 派生类的树（`$ccls/inheritance`） |
| 建议 `C-c vm` / `C-c vM` | `ccls-members variables` / `functions` | 成员变量 / 成员函数的树（`$ccls/member`），还可以是 `types` |
| | `ccls-vars` | 列出光标处类型的变量（`$ccls/vars`） |
| | `ccls-navigate up/down/left/right` | 按语法树移到外层、第一个内层、前后相邻的声明（`$ccls/navigate`） |
| | `ccls-reload` | 重新索引项目 |

`$ccls/publishSkippedRanges`（没参与编译的预处理分支）用 `dim` 画出，随编辑移动。

## 限制

- 没有 `roots` 时根目录就是项目根目录（版本库标记），不按 `compile_commands.json` 找；clangd 自己会找。
- `lsp-stop`、`lsp-restart` 直接结束进程，不发 `shutdown`/`exit`。
- 不发 `willCreateFiles`、`willRenameFiles`、`willDeleteFiles`：文件操作本身就来自服务器的编辑。目录改名只报告目录本身。
- `completionItem/resolve` 只取说明和 detail；其他修改要在列表里就给出。
