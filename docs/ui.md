# 终端界面

画面分两层。`screen` 与绘制方式无关：按前端提供的 `Measure` 布局每个窗口的文本，给出各段文字的位置、宽度和样式、光标和行号栏，以及标签栏、窗口标题、状态栏和消息行的内容（`screen/content.rs`）。`tui` 是终端前端：每帧先应用视口跟随，再按单元格划分区域绘制，由 ratatui（crossterm 后端）只输出变化的单元格。[图形前端](gui.md)复用 `screen`，外观自定。

## 布局

```
 main.cpp ●  util.h  [untitled 3]                       标签栏
   1 │ #include <cstdio>                                  行号栏 + 文本
  12 │ int main() {                                       当前行高亮
 COMMAND  src/main.cpp [+]          C-x    C++  12:5   40%    状态栏
:open src/                              open PATH · 1/2   消息行 / 输入行
▌ sub/                                                         候选（命令行打开时）
  main.cpp
```

| 区域 | 内容 |
| --- | --- |
| 标签栏 | 每个窗口顶部一行，同 Emacs 的 `tab-line-mode`（默认的 `tab-line-tabs-fixed-window-buffers`）：标签属于窗口，列出这个窗口显示过的文档，按第一次显示的顺序，新的接在末尾；换一个视图显示在这个窗口里时标签不变，分屏出的新窗口只有它显示的那一项。这个窗口显示的文档高亮，当前窗口里的加粗；侧窗只有它自己的一项。分屏与否样子相同。点标签在这个窗口里显示那个文档，回到这个窗口上次离开它时的光标和滚动位置（同 `window-prev-buffers` 按窗口记的位置，重新启动后也是），别的窗口正显示它时另开一个视图；中键点标签或 `close-tab` 把它从这个窗口的标签里去掉，文档不关（同 `tab-line-close-tab` 的 `bury-buffer`），关的是正显示的就换成右边一项，没有就左边一项，只剩一项时不关。关闭文档时它从所有窗口的标签里去掉。没有窗口时编辑区顶部一行只有启动画面一项，后面是所有已加载的文档；`●` 标记未保存；放不下时从左侧省略，放不下整个的标签不画。选项 `tab-bar`（默认开）关闭。窗口不足 2 行时省略。 |
| 行号栏 | 第一格是行标记（`flag-lines`），行号右对齐、至少 3 位。选项 `line-numbers`：`absolute`（默认）、`relative`、`off`；`off` 时有标记的文档仍留标记列。窗口过窄时省略。最后一个换行之后的空行也是一行（同 Emacs），`a\n` 显示两行。 |
| 状态栏 | 左：模式（模态编辑时为 NORMAL、INSERT、BEACON，否则不显示；交互层打开时为 COMMAND、SEARCH、REPLACE、SAVING、HELP、JUMP、RESIZE）、相对项目根的路径、`[+]` 与保存中标记、光标的行:列。右：`recording`、未完成的按键、`searching…`/`run…`/`running…`、扩展用 `soda.status` 设置的段落、错误和警告数（`E3 W1`）、服务当前文档的语言服务器名（`soda.lsp.server` 的 `name`，暗色）、语言名。 |
| 消息行 | 输入层（搜索、替换、保存等）的输入；否则依次是 `soda.hint` 的文字、光标处注记的第一行、最近的消息。新消息盖过注记，下一个键后注记回来。不带文件启动时不建文档，关掉最后一个文档后也一样：编辑区是启动页，列出打开文件、找项目文件、新建、运行命令和帮助，每项写当时生效的按键（像 Emacs 的 `where-is`，被前面键位表遮住的不算）；没有按键的写成运行命令的键加命令名，如 `M-x new`。 |

光标后是开括号、或光标前是闭括号时，它和配对的那个用 `paren-match` 标出（同 Emacs 的 `show-paren-mode`，先看光标后），只在当前窗口。配对用语言的结构，所以 C++ 字符串和注释里的括号不算；文本改了还没重新找时不画。选项 `show-paren` 关闭。

行尾显示这一行最严重的注记（诊断等 `soda.note` 写下的）的第一行，同行还有别的时加 `(+N)`，颜色是 `note-error`、`note-warning`、`note-info`；开了 `wrap` 时在折行的最后一段。选项 `inline-notes` 关闭。

文本按语法着色，见[语法高亮](syntax.md)；状态栏的语言名来自高亮所用的语言，未识别时为 text。

## 窗口

编辑区由 Application 的窗口树划分（`application/windows.rs`）：
- 叶子是窗口，各显示一个视图；不在树中的视图仍然打开，只是隐藏。
- 分支按行或按列、按权重分配空间。同方向再分屏增加兄弟而不嵌套，所以连续分屏大小相同；调整过大小后，新窗口分走原窗口的一半。左右相邻的窗口间留一列分隔线。
- `resize-window` 在沿该方向最近的一层分支上移动边：加大时先从后面的兄弟取格子，再从前面的，就近优先；缩小时给后一个兄弟（最后一个则给前一个）。窗口至少 2 行或 8 列；这一层动不了时由外层同方向的分支移动整组。调整后权重记为当时的格数，终端缩放时按比例变化。逐步调整模式见[交互](interaction.md)。
- 每个窗口的标签行属于这个窗口，分屏时各自一行；终端里上下相邻时，在下面窗口标签行的空白处按下可以拖动两者的交界。当前行高亮和终端光标只在当前窗口。
- 视口跟随只作用于当前窗口；其他窗口保持各自的视口，随编辑映射。

焦点：
- 聚焦已在窗口中的视图，切到那个窗口。
- 聚焦隐藏的视图（`buffer`、打开文件、新建文档），在当前窗口替换原视图，原视图隐藏。
- 关闭视图或文档后，失去视图的窗口改显示最近用过的隐藏视图；没有时窗口关闭。

方向切换在一个虚拟的正方形区域里算位置：在该方向上与当前窗口有重叠的窗口中取最近的，距离相同时取上边或左边对齐最近的。

鼠标点击窗口先聚焦它，滚轮滚动指针下的窗口（不移动其光标）。拖动左右窗口间的分隔列或下方窗口的标题行可以移动那条边：只动边另一侧的窗口，先从紧挨的取格子，都到最小尺寸时停下；最外侧的边另一侧是侧窗时改变侧窗大小。关掉标签栏时，不在最上面的窗口让出第一行画一条 `─`（Emacs 在这里是上面窗口的 mode line），上下窗口照样分得清，拖动这一行同样移动交界。

**侧窗。** 窗口树之外有底部和右侧两个侧窗，参照 Emacs 的 side window：底部侧窗占满宽度，右侧侧窗占它以上的高度；按给定行列数显示，最多占一半，只剩侧窗时占满。侧窗不能再分屏，`only` 会关掉它们，方向切换照常进出；失去视图时直接关闭。

**显示规则。** 参照 Emacs 的 `display-buffer-alist`，只做声明式的一小部分（`application/display.rs`）：按文档种类匹配（普通文档是 `file`，scratch 文档按名字去掉星号，如 `*grep*` 是 `grep`）；只在文档还没显示时起作用，已显示的直接切过去。写法 `display KIND PLACEMENT`，`init.lua` 里是 `soda.command("display …")`。

| 位置 | 行为 |
| --- | --- |
| `same` | 当前窗口；当前窗口是别的种类的侧窗时按 `other`。默认规则 |
| `other` | 最近用过的另一个分屏窗口；没有时把当前窗口上下分开 |
| `auto` | 已有侧窗时替换它的视图。否则看最大的分屏窗口：宽不少于 150 列且大于高的 2 倍时用右侧侧窗（占一半宽），否则用底部侧窗。显示时决定，之后不随终端大小移动。`grep`、`run`、`messages` 和 `soda.results` 的结果文档默认用它 |
| `bottom [ROWS]` | 底部侧窗，默认 12 行 |
| `right [COLUMNS]` | 右侧侧窗，默认 60 列 |

所以在底部结果列表里按回车，文件出现在上面的分屏窗口，列表不动。

编辑区高度是终端高度减去标签栏、状态栏和消息行。翻页按当前窗口的文本行数；帮助与命令行候选按整个编辑区。

## 浮层

浮层画在编辑区之上，圆角边框，不改变编辑区布局。没有打开的文档时编辑区居中显示常用入口。

**命令行**在状态栏正下方输入。有候选来源的参数位（命令名、路径、文件、缓冲区、选项、选择项）在输入行下列出候选，并把状态栏和输入行一起推上去，覆盖编辑区底部而不改变其高度，视口不跳。候选区最多 10 行（至少留一行文本），不足时留空；自由文字（KEYS、shell 命令）没有候选。选中项带左侧标记和背景，匹配字符用 `matched`，次要文字用 `detail`。输入行右侧依次是命令和参数说明（`open PATH`）、命令行的问句、加载状态和选中项序号，放不下时先省略参数说明；有错误时只显示错误。

**按键的显示**用 Emacs 记法（`C-x C-s`、`M-f`、`SPC`、`RET`、`<left>`），状态栏、按键提示和未定义按键的消息（`C-x z is undefined`）都是。未完成的前缀写作按过的键：`x` 之后是 `C-x`，`m g` 之后是 `M-g`；只有 keypad 确定要加修饰键时才写出来，`m` 之后是 `M-`，`g` 之后是 `C-M-`。省掉 Emacs 回显末尾的 `-`。配置写的也是同一种记法，见[按键记法](interaction.md#按键记法)。

**按键提示**在多键前缀之后出现于编辑区右下角（盖住光标时终端光标不显示，同图形界面把光标画在浮层下面），按列列出下一个键和说明，继续更长序列的键显示为 `+键`。keypad 中列出去掉修饰键后要按的键：`x` 之后 Ctrl 绑定优先于同键的普通绑定，带 Meta 的不列；`m`/`g` 之后列出键位栈中带 Meta/Ctrl-Meta 的键。绑定带参数时说明后加上参数（`surround (` 显示为 `Put a pair around the selection: (`）。说明来自命令：内置命令的文档、Lua 命令的 `doc`（省略时为命令名）、`define-command` 的命令体。提示读同一张键位表，用户绑定立刻反映。

**帮助**占满编辑区，可滚动。

## 空白与列宽

| 选项 | 默认 | 作用 |
| --- | --- | --- |
| `wrap` | 关 | 长行折行，不再水平滚动 |
| `show-tabs` | 关 | 制表符第一格显示 `»`，暗色 |
| `show-trailing-whitespace` | 关 | 行尾空格显示 `·`，暗色（同 Emacs 的同名变量） |
| `ruler` | 0 | 给第 `ruler` 列之后的一列加底色（同 Emacs `display-fill-column-indicator`），0 不显示 |

`%val{column-limit}` 是 clang-format 的 `ColumnLimit`（没有配置时为 0），例如 `hook open .*\.(cpp|h) set-local ruler %val{column-limit}`。

折行的断点在最后一个放得下的空格之后，空格留在上一行；词比整行宽时在行尾断开，宽字符不跨行；续行的行号栏留空。视口锚点可以落在长行中间的屏幕行，所以比整屏高的行也能跟随光标；滚轮、点击和跳转标签按屏幕行，`j`/`k` 和翻页仍按逻辑行。超过 4096 字节的行不折行（逐字形量太慢），视口顶部或光标附近 256 行内有这样的行时整个窗口暂按不折行显示。

## 键盘

启动时查询 kitty 键盘协议，支持时开启 disambiguate 模式，退出（包括 panic）时恢复，这样 `C-RET`、`C - DEL`、`C-i` 与 Tab、`C-[` 与 Esc 都能区分。不支持的终端里这些组合收不到或与基本键合并。协议报告的小写加 Shift 规范成大写字母。

空闲时等待输入、唤醒或 Runtime 的下一个期限，不轮询。绘制前先读完已到达的输入，最多读 30 ms，所以按住键时按键不会排队等逐个绘制。

## 鼠标

启用鼠标捕获，选项 `mouse` 关闭后用终端自己的选择。`tui/mouse.rs` 用当帧的区域解析事件：标签栏按位置找文档；编辑区的点击和拖动由 `layout::offset_at` 换算成字节偏移（行号栏取行首）；滚轮由 `layout::scroll` 计算新视口。行为见[交互](interaction.md#鼠标)。

## 主题

主题都是真彩的。选项 `theme` 取主题名：内置的，或 `soda.theme` 定义的，默认 `tokyonight`。深浅不是单独的设置，也不跟随终端背景；想要浅色就选一个浅色主题。

内置主题：

- Tokyo Night：`tokyonight`、`tokyonight-day`、`tokyonight-storm`
- Modus（取自 modus-themes 的调色板）：`modus-operandi`、`modus-vivendi`，及其 `-tinted`、`-deuteranopia`、`-tritanopia` 变体
- JetBrains：`islands-dark`、`islands-light`（取自 IntelliJ Platform 的 Islands 主题与配色方案；调用用正文色，声明用函数色，内建类型和常量用关键字色，同 CLion），`fleet-dark`、`fleet-dark-purple`、`fleet-light`（取自 zed-fleet-themes，半透明颜色已按背景混合）
- 其他：`catppuccin-mocha`、`catppuccin-latte`、`gruvbox-dark`、`gruvbox-light`、`dracula`、`nord`、`nord-light`（取自 doom-themes 的 doom-nord-light）、`one-dark`、`one-light`、`solarized-dark`、`solarized-light`、`rose-pine`、`rose-pine-dawn`、`kanagawa`、`everforest-dark`、`everforest-light`、`github-dark`、`github-light`、`monokai`

每个主题是一份调色板加少量语法 face：界面部分都由调色板推出，语法 face 保留该主题原本的关键字、字符串、函数等配色。围绕正文的部分按 Zed 主题的层次由 `bg` 向 `fg` 混合得到，深色主题比正文亮、浅色主题比正文暗：标签栏和窗口标题 6%，状态栏 13%，它们和正文之间、窗口之间的分隔线（`border`）20%。命令行候选和补全列表铺 `bg-dark`，选中项（`candidate-selected`）不直接取调色板的 `bg-highlight`（有的主题里它和 `bg-dark` 一样，或比它还浅），而是从列表底色往 `selection` 混合，还不够再往 `blue` 推，直到和底色的对比度（WCAG）达到 1.5。分屏时焦点以外的窗口用调色板的 `bg-dark` 作底色（face `inactive-window`，同 Emacs 的 `auto-dim-other-buffers`），只换底色不动文字颜色；选项 `dim-other-windows`（默认开）关掉。图形前端的标签行照 Zed 画：标签并排，每个后面一条竖线，底边一条横线，只在当前标签下断开，当前标签用正文底色，像是通向下面的正文；当前窗口的当前标签顶上是一条强调色细线。定义在 `src/application/themes.rs`。主题设置整屏背景，不依赖终端配色。终端前端在 `COLORTERM` 为 `truecolor` 或 `24bit` 时输出 24 位颜色，否则换算为最接近的 xterm 256 色。

命令 `theme NAME` 随时切换主题，等同 `set theme NAME`，补全列出所有主题并标出当前的。名字未定义时报错，选项不变。补全时实时预览：用方向键移到某一行，或输入文字选出一行后，整屏立即按该主题绘制；Enter 采用，Esc 回到原来的主题。刚打开、还没有选择时不预览。预览只是前端按命令行的选中行绘制，不改选项，所以取消时没有要恢复的状态。

`soda.theme(name, spec)` 定义主题，再次调用替换同名的定义；内置主题的名字不能被占用。spec 的三部分都可省略：

```lua
soda.theme("paper", {
  base = "one-light",             -- 底下的内置主题，默认 tokyonight
  palette = { bg = "#fafafa", fg = "#383a42", blue = "#4078f2" },
  faces = {
    ["syntax.keyword"] = { fg = "#a626a4", bold = true },
    status = "fg:#383a42 bg:#e5e5e6",
  },
})
soda.set("theme", "paper")
```

叠放顺序是：内置主题的调色板 → `palette` 替换其中的颜色，界面和语法的颜色都由调色板推出 → 内置主题自己的语法 face → `faces` 覆盖个别部分 → 用户的 `face` 覆盖最后生效。所以切换主题时 `face` 的设置保留。调色板的颜色名：`bg`、`bg-dark`、`bg-highlight`、`selection`、`fg`、`fg-dark`、`comment`、`gutter`、`gutter-current`、`blue`、`green`、`magenta`、`orange`、`yellow`、`red`、`cyan`、`teal`、`on-accent`（徽标上的文字）。`faces` 的值与 `soda.face` 相同。`soda.themes()` 返回所有主题名，内置的在前。`theme` 选项指向的定义主题若不再存在，用 `tokyonight`。重新定义正在使用的主题，下一帧生效。

`face NAME [SPEC]`（Lua：`soda.face(name, spec)`）覆盖一个具名部分的颜色和属性。SPEC 是若干词：`fg:#rrggbb`、`bg:#rrggbb`（`default` 为终端自己的颜色），属性 `bold`、`italic`、`underline`、`dim`、`reverse`、`strikethrough`。没写的颜色沿用主题；写了任何属性就替换主题的属性，`plain` 表示无属性。不带 SPEC 时恢复。Lua 的 spec 也可以是表 `{ fg = "#ff0000", bold = true }`，`nil` 恢复。随时执行，下一帧生效。

名字有界面部分（`text`、`selection`、`cursor-line`、`gutter`、`gutter-current`、`status`、`mode-normal`、`mode-insert`、`mode-beacon`、`mode-prompt`、`secondary-selection`、`beacon-selection`、`beacon-cursor`、`title`、`border`、`paren-match`、`inactive-window`、`float`、`float-border`、`label`、`todo`、`note-error`、`note-warning`、`note-info`、`reference`、`reference-write`、`snippet`、`unnecessary`、`deprecated`、`mark1`…`mark8` 等，完整列表和说明见 `src/application/faces.rs`，命令行可补全）和语法分类 `syntax.comment`、`syntax.keyword`、`syntax.function.definition` 等。带点的语法 face 继承点前面的那个（见[语法分类](syntax.md#分类)）：`face syntax.function bold` 也作用于没单独设置的 `syntax.function.call`。

光标形状跟随模式：Normal 和 Beacon 为方块，Insert 和输入框为竖线。

## 测试

`screen::layout` 的单元测试覆盖裁剪、宽字符、选区、视口跟随、折行和输入行滚动，并用按像素计量的 `Measure` 检查 tab、inlay、光标和点击换算。`tui/view.rs` 的测试经 `Presenter` 把整屏画进单元格缓冲区，检查各区域的组成。
