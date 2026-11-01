# 补全

补全按输入法的方式设计：正在写的词是文档里真实的文字，候选在确认之前不进入文档。第一阶段（本文“当前实现”）已经完成；snippet、Lua 来源和 LSP 来源是后续阶段。

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

## 后续阶段

1. **Lua 来源**：`soda.completion.register{ name, triggers, complete(ctx, sink) }`，`sink:add` 可多次调用，`sink:done{ incomplete = ... }` 声明前缀变化时是否重新请求这个来源。候选增加 `sort_text`、`extra_edits`、`commit_chars`、延迟解析用的 `data`，以及 insert/replace 两个范围。
2. **`SnippetSession`**：确认带占位符的候选时启动，独立于补全，复用标记的位置映射。字段里可以继续补全，优先级为 `completion > snippet > insert`。占位符在 Insert 中选中即可，打字替换，不需要 Select 模式。换行走语言缩进。光标离开 snippet 范围、走到最后一个 tabstop 或回到 Normal 时结束。第一版不做 mirror、变量和 choice。
3. **LSP 来源**：clangd，`M-.` 和 call hierarchy 共用这一层。
4. **灰字预览**：选中项在光标处用绘制层显示，不写入文档。

## 与 capf 的区别

Emacs 的 `completion-at-point-functions` 取第一个有结果的函数，要求同步且便宜，候选基本是字符串，范围只有一组，匹配归 UI 或 completion style，没有会话协议。这里来源并行且异步，范围按候选给，匹配统一在框架里，重新请求的时机由 `incomplete` 决定。
