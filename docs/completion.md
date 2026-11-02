# 补全

补全按输入法的方式设计：正在写的词是文档里真实的文字，候选在确认之前不进入文档。缓冲区单词、路径、Lua 来源、snippet 和语言服务器都已实现，语言服务器见[语言服务器](lsp.md)。

## 会话

会话只保存一个随编辑映射的起点 `anchor`，前缀永远是 `text[anchor..caret]`。每次输入之后 `Layers::completion_sync` 只看一条规则：光标不早于起点，且起点到光标之间全是单词字符，列表就保持并按新的前缀过滤；否则会话结束。Insert 之外、打开模态层、切换视图或者有选区时也结束。

所以左右移动没有专门的处理，`Left`、`Right`、`C-b`、`M-f`、Backspace 都走 Insert 原有的路径：左移缩短前缀、列表变宽，右移延长前缀，走出单词后关闭。这和 IntelliJ 的 `LookupActionHandler` 效果相同。

候选不写进文档（Helix 的预览要靠 savepoint 保证和语言服务同步）：文档、语言分析和撤销里只有真实输入的字。确认时一个事务替换文字；撤销先退回确认前打的字，再退回输入。

## 键

列表显示时先查 `completion` 上下文，只接受单键，没有绑定的键落回 Insert，所以自动配对和缩进不受影响。

| 键 | 命令 | 作用 |
| --- | --- | --- |
| `Tab` | `completion-replace` | 取选中项，没有选中时取第一项，替换到词尾 |
| `Enter` | `completion-accept` | 取选中项，保留光标后的文字；**没有选中时照常换行** |
| `C-n`、`Down` / `C-p`、`Up` | `completion-next` / `completion-previous` | 移动选中项 |
| `C-g` | `completion-dismiss` | 关闭列表，留在 Insert；这个词结束前不再弹出 |
| `Esc` | | 关闭列表并回到 Normal |

Insert 中 `M-/`（`completion-trigger`）不受最小长度和 `completion` 选项限制，直接列出候选。

Enter 只在动过选中项之后才接受，这对应 IntelliJ 的 `LookupFocusDegree.UNFOCUSED`：自动弹出的列表不能抢走回车，回车缩进是首要体验。

| 选项 | 默认 | 作用 |
| --- | --- | --- |
| `completion` | true | 输入时自动弹出 |
| `completion-min-prefix` | 2 | 自动弹出需要的字符数 |

## 来源

来源在后台线程读快照，每个会话只请求一次，之后的按键都是本地过滤；请求带代数，过期结果丢弃。过滤用 nucleo（smart case），前缀匹配排在前面，同分保持来源给出的顺序。延长前缀时只过滤上一次的结果。

- **单词**：当前文档的词按离光标的距离排序，然后是其他打开的文档，最多 10,000 个。至少两个字符，不以数字开头。
- **路径**：光标前的词含 `/` 时列出那个目录，目录排在前面；相对路径以文档所在目录为基准，`~/` 使用 HOME，`//` 开头的不算。候选自带 `back`，替换范围可以比当前单词长，比如 `a.t` 里的 `.`。

列表只有一项且等于已输入的文字时不显示。

`.` 和宏重放时不启动补全；确认时录下来的是“删掉前缀、写入文字”，选择列表的键不录，所以重放结果确定。

## Lua 来源

```lua
soda.completion.register({
  triggers = { "." },              -- 可选：输入这些字符时也询问
  complete = function(context, sink)
    -- context: prefix、language、line、column、trigger（由字符触发时）
    sink:add({ { label = "name", detail = "field" } })  -- 可多次调用，可以晚些调用
    sink:done({ incomplete = true })                    -- 前缀变化时再问这个来源
  end,
})
```

`complete` 在编辑线程上运行，要做慢的事就交给 `soda.spawn`，在回调里继续写 `sink`；会话结束后才到的结果被丢弃。候选的字段：`label`（必需）、`detail`、`filter`（匹配用的文字，默认是 `label`）、`text`（插入的文字，默认是 `label`）、`snippet`（插入一段 snippet，优先于 `text`）、`back`（比当前单词多替换的字节数）、`edits`（同时做的其他修改，格式同 `buffer:edit`：`{ {行, 列}, {行, 列}, 文字 }`，从 1 开始的行号和字节列，比如名字需要的 `#include`）。`edits` 和替换在同一个撤销步里；其中任何一处超出文档或碰到被替换的范围时，全部不做。

没有字符触发时询问所有来源和内置来源；由字符触发时只询问声明了这个字符的来源，单词没有意义。相同匹配度下 Lua 来源排在内置来源之前。

## Snippet

`snippet BODY` 在光标处展开，候选带 `snippet` 字段时确认后展开。语法是 LSP 的：`$1`、`${1:默认文字}`（可以嵌套）、`$0`（结束位置，缺省为末尾），`\$`、`\}`、`\\` 转义。`${1|a,b|}` 取第一项，变量为空或取默认值。同一个序号第二次出现时复制第一处当时的文字，**之后的输入不同步**，也就是没有 mirror。

展开是一个撤销步。多行时，后面的行先加上当前行的缩进，行首的制表符算一层；然后每行走语言的 Reindent，C++ 得到 CST 算出的缩进。

会话独立于补全：每个位置是一对随编辑映射的位置，起点靠前、终点靠后，在里面打字时范围跟着变大。Insert 中第一个位置选中，打字替换它。`Tab` / `Shift-Tab`（`snippet-next` / `snippet-previous`，上下文 `snippet`）在位置之间移动，列表显示时 `Tab` 先给列表，所以字段里可以继续补全。到达最后一个位置、光标离开 snippet 范围、回到 Normal 或切换视图时结束。

内置模块 `snippets` 把 snippet 变成候选，默认不带任何 snippet：

```lua
require("snippets").add("cpp", {
  fori = "for (int ${1:i} = 0; $1 < ${2:n}; ++$1) {\n\t$0\n}",
})
```

限制：`.` 和宏重放时写入 snippet 展开的文字（候选的 `edits` 不重放），之后在位置里打的字和 `Tab` 不按 snippet 重放；snippet 里再展开 snippet 时，新的会话替换旧的；位置没有高亮，只有当前位置靠选区显示；紧挨着的两个位置，在前一个末尾打字会落进后一个。

## 后续

- 候选还缺 `commit_chars`、延迟解析和 insert/replace 两个范围。
- 灰字预览：选中项在光标处用绘制层显示，不写入文档。

## 与 capf 的区别

Emacs 的 `completion-at-point-functions` 取第一个有结果的函数，要求同步且便宜，候选基本是字符串，范围只有一组，匹配归 UI 或 completion style，没有会话协议。这里来源并行且异步，范围按候选给，匹配统一在框架里，重新请求的时机由 `incomplete` 决定。
