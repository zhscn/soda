# 补全

补全按输入法的方式设计：正在写的词是文档里真实的文字，候选在确认之前不进入文档。来源有缓冲区单词、路径、Lua 注册的来源（包括 snippet 和[语言服务器](lsp.md)）。

## 会话

会话只保存一个随编辑映射的起点 `anchor`，前缀永远是 `text[anchor..caret]`。每次输入之后只看一条规则：光标不早于起点，且起点到光标之间全是单词字符，列表就保持并按新前缀过滤；否则会话结束。离开 Insert、有选区、打开输入框或切换视图时也结束。

所以左右移动不需要专门处理：`Left`、`C-b`、Backspace 缩短前缀、列表变宽，`Right`、`M-f` 延长前缀，走出单词就关闭。这和 IntelliJ 的 `LookupActionHandler` 效果相同。

候选不写进文档（Helix 的预览要靠 savepoint 才能和语言服务同步），文档、语言分析和撤销里只有真实输入的字。确认时一个事务替换文字；撤销先退回确认，再退回输入。

## 键

列表显示时先查 `completion` 键位表，没有绑定的键落回 Insert，自动配对和缩进不受影响。

| 键 | 命令 | 作用 |
| --- | --- | --- |
| `Tab` | `completion-replace` | 取选中项，没有选中时取第一项，替换到词尾 |
| `Enter` | `completion-accept` | 取选中项，保留光标后的文字；**没有选中时照常换行** |
| `C-n`、`Down` / `C-p`、`Up` | `completion-next` / `completion-previous` | 移动选中项 |
| `C-g` | `completion-dismiss` | 关闭列表，留在 Insert；这个词结束前不再弹出 |
| `Esc` | | 关闭列表并回到 Normal |

Insert 中 `M-/`（`completion-trigger`）不受最小长度和 `completion` 选项限制，直接列出候选。

Enter 只在动过选中项之后才接受，对应 IntelliJ 的 `LookupFocusDegree.UNFOCUSED`：自动弹出的列表不能抢走回车，回车缩进是首要体验。

动过选中项之后，它比已输入文字多出的部分以灰色斜体画在光标处（snippet 画展开后的第一行）。这只是绘制，不进文档和撤销；候选不以已输入的文字开头时不画。

| 选项 | 默认 | 作用 |
| --- | --- | --- |
| `completion` | true | 输入时自动弹出 |
| `completion-min-prefix` | 2 | 自动弹出需要的字符数（1–16） |
| `completion-preview` | true | 选中项在光标处灰字预览 |

## 来源

来源在后台线程读快照，每个会话只请求一次，之后的按键在本地过滤；请求带代数，过期的结果丢弃。过滤用 nucleo（smart case），前缀匹配排在前面，同分保持来源给出的顺序；延长前缀时只过滤上一次的结果。

- **单词**：当前文档的词按离光标的距离排序，然后是其他打开的文档，最多 10,000 个；至少两个字符，不以数字开头。
- **路径**：光标前的词含 `/` 时列出那个目录，目录在前；相对路径以文档所在目录为基准，`~/` 是 HOME，`//` 开头的不算。替换范围可以比当前单词长（如 `a.t` 里的 `.`）。

列表只有一项且等于已输入的文字时不显示。宏重放时不启动补全：录下的是“删掉前缀、写入文字”，选择列表的键不录，所以重放结果确定。

## Lua 来源

```lua
soda.completion.register({
  triggers = { "." },              -- 可选：输入这些字符时也询问
  complete = function(context, sink)
    -- context: prefix、language、line、column、trigger（由字符触发时）
    sink:add({ { label = "name", detail = "field" } })  -- 可多次调用，可以晚些调用
    sink:done({ incomplete = true })                    -- 前缀变化时再问这个来源
  end,
  resolve = function(key, done) end,  -- 可选：选中带 key 的候选时补充 detail 和 doc
})
```

`complete` 在编辑器线程上运行，慢的事交给 `soda.spawn`，在回调里继续写 `sink`；会话结束后到的结果丢弃。

| 字段 | 作用 |
| --- | --- |
| `label` | 必需，列表里显示的文字 |
| `detail` | 列表里 label 旁的说明 |
| `filter` | 匹配用的文字，默认是 `label` |
| `text` | 插入的文字，默认是 `label` |
| `snippet` | 插入一段 snippet，优先于 `text` |
| `back` | 比当前单词多替换的字节数 |
| `insert`、`replace` | Enter 和 Tab 替换到光标后多少字节（按来源回答时的光标计），对应语言服务器的两个范围；缺省时 Enter 不替换光标后的文字，Tab 替换到词尾 |
| `edits` | 同时做的其他修改，`{ {行, 列}, {行, 列}, 文字 }`，行从 1 开始、列按字节（如名字需要的 `#include`）；与替换在同一撤销步，任何一处超出文档或碰到被替换的范围时全部不做 |
| `commit` | commit 字符组成的字符串：动过选中项后输入其中的字符，先确认候选再输入它；`completion` 键位表绑定了这个键时以绑定为准 |
| `doc` | 选中时显示在列表旁边，哪边地方大放哪边 |
| `key` | 整数。来源有 `resolve` 时，候选第一次被选中就调用 `resolve(key, done)`，`done({ detail = ..., doc = ... })` 可以晚些调用，给出的字段替换原来的 |

没有字符触发时询问所有来源和内置来源；由字符触发时只询问声明了这个字符的来源。相同匹配度下 Lua 来源排在内置来源之前。

## Snippet

`snippet BODY` 在选区处展开，候选带 `snippet` 字段时确认后展开。在 Normal 里执行时先进入 Insert，选中的文字是 `$TM_SELECTED_TEXT`，可以写把选区包起来的 snippet。语法是 LSP 的，与 VSCode 一致：

- `$1`、`${1:默认文字}`（可嵌套）、`$0`（结束位置，缺省为末尾）；`\$`、`\}`、`\\` 转义。
- 同一序号出现多次时，第一个带默认文字的是要填的位置，其余是**镜像**，随位置里的输入变化，与输入在同一撤销步。
- `${1|a,b,c|}` 是选项：先放第一项，进入位置时列出所有选项，上下键选、回车确认、打字过滤；`Tab` 不确认，直接去下一个位置。
- `${1/正则/格式/选项}` 是变换后的镜像，`${TM_FILENAME/正则/格式/}` 是变换后的变量。格式里有 `$1`、`${1:/upcase}`（还有 `downcase`、`capitalize`、`camelcase`、`pascalcase`）、`${1:+有匹配时}`、`${1:?有:无}`、`${1:-无匹配时}`；选项 `g` 替换所有匹配，`i`、`m`、`s` 同正则。正则是 Rust `regex` 的语法，没有环视。
- 变量：`TM_SELECTED_TEXT`、`TM_CURRENT_LINE`、`TM_CURRENT_WORD`、`TM_LINE_INDEX`、`TM_LINE_NUMBER`、`TM_FILENAME`、`TM_FILENAME_BASE`、`TM_DIRECTORY`、`TM_FILEPATH`、`RELATIVE_FILEPATH`、`WORKSPACE_NAME`、`WORKSPACE_FOLDER`、`CLIPBOARD`、`CURSOR_INDEX`、`CURSOR_NUMBER`、`CURRENT_YEAR` 等日期时间（本地时间）、`RANDOM`、`RANDOM_HEX`、`UUID`、`LINE_COMMENT`、`BLOCK_COMMENT_START`、`BLOCK_COMMENT_END`。值为空时取 `${NAME:默认}` 的默认值；不认识的变量变成写着变量名的位置，排在有序号的位置之后。补全展开时 `TM_SELECTED_TEXT` 为空。

展开是一个撤销步。多行时，后面的行先加上当前行的缩进（行首制表符算一层），再逐行走语言的 Reindent，C++ 得到 CST 算出的缩进。

会话独立于补全：

- 正在填的位置吃掉两边的输入，其他位置和镜像不吃，所以紧挨着的两个位置不会互相吞字；空位置留在它在 snippet 里的那一侧。一次编辑把某个位置连同周围一起替换掉时，这个位置作废，`Tab` 跳过它。
- Insert 中第一个位置选中，打字替换它。`Tab` / `Shift-Tab`（`snippet-next` / `snippet-previous`，键位表 `snippet`）在位置间移动，不算光标移动，所以从 Normal 展开到填完回到 Normal 是一个撤销步。列表显示时 `Tab` 先给列表（选项列表除外），字段里可以继续补全。
- 其余位置和镜像用 face `snippet` 标出，当前位置靠选区显示。到达最后一个位置、光标离开 snippet、回到 Normal 或切换视图时结束。
- 在位置里再展开 snippet 时，新的叠在旧的上面：内层结束后外层接着走，外层的镜像也跟着内层的输入变。

宏录制时，补全展开的 snippet 记成 snippet 本身，之后的输入和 `Tab` 照常记录，重放时一样经过各个位置。候选的 `edits` 不重放：它们是按原位置算出的绝对位置，重放只会重复插入。

内置模块 `snippets` 把 snippet 变成候选，本身不带任何 snippet：

```lua
local snippets = require("snippets")
snippets.add("cpp", {
  fori = "for (int ${1:i} = 0; $1 < ${2:n}; ++$1) {\n\t$0\n}",
  main = { body = "int main() {\n\t$0\n}", description = "入口" },
})
-- VSCode 格式的文件，或带 package.json 的目录（比如 friendly-snippets）
snippets.load("~/.config/soda/snippets/cpp.json", "cpp")
snippets.load("~/src/friendly-snippets")
```

`add` 的语言写 `"*"` 时对所有语言生效。`load(path, [language])` 读 VSCode 格式：每项有 `prefix`（字符串或数组，每个是一个候选）、`body`（字符串或行的数组）、`description`（选中时显示的说明），可以有 `scope`（逗号分隔的语言，缺省为所有语言）。给了 `language` 时全部归到这个语言；目录按 `package.json` 的 `contributes.snippets` 找文件，给了 `language` 时只读这个语言的。文件可以有注释和尾随逗号；VSCode 的 `plaintext` 对应 `text`。返回加入的条数。

## 与 capf 的区别

Emacs 的 `completion-at-point-functions` 取第一个有结果的函数，要求同步且便宜，候选基本是字符串，范围只有一组，匹配归 UI 或 completion style，没有会话协议。这里来源并行且异步，范围按候选给，匹配统一在框架里，重新请求的时机由 `incomplete` 决定。
