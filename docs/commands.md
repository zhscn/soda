# 编辑命令与无 UI 工作流

命令按 CodeMirror 的方式分工：位置原语独立于前端，命令根据状态生成选区或事务，历史策略根据输入事件分组，搜索查询与 cursor 独立于搜索界面。语言缩进以建议的形式接入，同样经事务提交（见[编辑内核与接口](core.md)）。

## 命令一览

| 类别 | `editor::Command` |
| --- | --- |
| 输入 | `InsertText`（粘贴）、`TypeChar`、`Enter`、`Reindent(line)`、`InsertTab`、`InsertLiteralTab`、`IndentSelection { outdent }` |
| 删除 | `Delete { direction, smart }`、`DeleteWord(direction)` |
| 选区 | `SetSelection`、`Move { motion, extend }`、`SelectAll`、`Goto { line, column }` |
| 搜索 | `SetSearchQuery`、`Find { backward, wrap }`、`ReplaceCurrent`、`ReplaceAll` |
| 历史 | `Undo`、`Redo`、`BeginUndoGroup`、`EndUndoGroup`、`SquashHistory(depth)` |
| 配置 | `SetLanguage`、`SetWhitespace`（C++ 忽略）、`SetAutoPairs` |
| 其他 | `Apply(Transaction)`、`ReloadText`（工作区重新加载使用） |

## 位置与选区

公开位置是 UTF-8 字节偏移；字符簇、逻辑列和 clipping 规则见[坐标契约](coordinates.md)。LF 和 CRLF 各算一次跨行移动与删除。

| Motion | 目标 |
| --- | --- |
| Backward、Forward | 相邻字符簇边界 |
| WordBackward、WordForward | Unicode 词边界（标点与空白分隔），可跨行 |
| Up、Down、Lines { backward, count } | 目标行上的期望列 |
| LineStart、LineEnd | 行首、行内容末尾 |
| DocumentStart、DocumentEnd | 文档两端 |

`extend` 保持 anchor、移动 head；不扩展的 Backward/Forward 先把已有选区收拢到对应端点。`Goto` 的列是逻辑列，行号越界时落在最后一行。

垂直移动在会话中保留期望列，短行不会改变它；目标列落在 tab 或宽字符内部时取其前方。文本变化、直接设置选区、非垂直移动和实际的语言切换使期望列失效。选区、期望列和搜索状态按会话独立。

命令只使用逻辑行和文本顺序。软换行、bidi 视觉顺序和屏幕位置由前端换算后，通过同一入口提交。

## 删除与空白

`Delete` 先删除选区，否则按方向删除一个字符簇或行分隔符；外部定位落在字符簇或 CRLF 内部时删除整个单元，文档边界上为空操作。`DeleteWord` 无选区时删除到词边界，范围向外扩展到完整字符簇。

`smart` 的 Backward 只作用于光标前全是 tab/space 的行首区域：把这段空白重写为前一个缩进单位所在列的空白。缩进宽度为零时按普通删除。

`InsertTab` 有选区时等同 `IndentSelection`；否则推进到下一个 tab stop，行首按 tab 策略生成 tab 或 space，代码内部只有 `Always` 使用 tab。`InsertLiteralTab` 总是插入一个 tab。`IndentSelection` 对当前行或选中的逻辑行按 IndentWidth 增减缩进，选区恰好结束于下一行行首时不含该行；缩进宽度为零时为空操作。

空白策略与 `materialize` 在共享的 `language` 层。PlainText 与 TextMate 语言默认宽度 4、空格，由 `SetWhitespace` 修改，在这两类语言之间切换时保留；C++ 使用有效规则。通用命令不访问 parser。

插入、粘贴和删除后的光标向后归一到字符簇边界，包括删除分隔符后字符簇合并的情况；显式事务和 core 选区只要求 UTF-8 边界。

## 自动配对

`SetAutoPairs(true)` 开启，默认关闭，行为同 Emacs 的 electric-pair-mode：

- 开括号或引号后面只有空白、闭合符、`;` 或 `,` 时补上闭合符，光标在中间；
- 输入的闭合符与下一个字符相同时跳过它（引号只在字面量内部跳过）；
- 有选区时用这一对符号包围选区；
- Backspace 位于空的一对之间时删除两侧。

引号只在 profile 声明的语言中配对，紧跟单词或引号的引号不配对，注释和字面量内部不配对。

## 历史策略

core 的 `History` 保存、组合和恢复修改；editor 的 `InputHistory` 只决定输入事件是否与上一操作合并，事件类别经 `Transaction.user_event` 与分组一起传给 core。

连续的 `TypeChar`（换行除外）或连续同方向的 `Delete`，在同一会话、同一事件类别、修订和选区等于上次结果、间隔不超过 500 ms 时合并。其他命令都形成边界；保存请求、保存确认和重新加载也会结束分组。

`execute_at` 接收显式事件时间，用于确定性测试或事件重放；`execute` 使用控制器的单调时钟。输入历史只在命令成功后更新。`Apply` 使用调用方的 `history_group`，自动输入事件带有事件类别，二者的分组键不会相同。

`BeginUndoGroup`/`EndUndoGroup` 把一次交互中的连续修改合成一个撤销单位，分别携带撤销与重做时恢复的选区，分组属于发起会话；其他会话的命令、选区命令、撤销重做和配置变化结束分组，失败事务不消耗分组状态。`SquashHistory(depth)` 把 `Document::history_depth()` 记录的深度之后的全部条目合成一项，用于宏和多光标重放。

## 搜索与替换

`SearchQuery` 是 regex crate 语法的正则，smart case：模式中没有大写字母时忽略大小写，`\S`、`\W` 等转义里的大写不算。`SearchQuery::word` 与 `symbol` 是整词精确查询：word 以下划线为界（`add` 匹配 `add_executable`），symbol 不以下划线为界（`add` 不匹配 `add_x`）。

`SearchCursor` 逐行匹配，匹配不跨行，`^`/`$` 是行首行尾；只读取正在扫描的行，不请求全文。cursor 返回非重叠、非空的字节范围；空查询和无法编译的模式没有匹配，后者由 `error()` 报告。3 万行文件全文扫描约 13 ms。

`SetSearchQuery` 设置当前会话的查询。`Find` 选中前一个或后一个匹配，`wrap` 决定是否环绕，结果按当前快照重新计算。`ReplaceCurrent` 只在当前选区恰好是一处匹配时替换；`ReplaceAll` 在同一快照上构造全部修改，一次提交、一次撤销。替换文本中 `$1`、`${name}` 是分组，`$0` 是整个匹配，`$$` 是 `$`。其他会话的选区按精确变更映射。

文件的打开、保存与重新加载见[文件服务与文档生命周期](files.md)。

## 验证

```sh
cargo test --test commands --test files --test mvp
cargo run --release --example cpp_input_trace -- PATH_TO_CPP_FILE 20
```

`cpp_input_trace` 在真实文件上执行 Enter、闭合符和普通字符输入，每次撤销并校验原文，报告中位数、P95 和最大延迟；计时含输入协调与语言分析，不含选区设置和撤销，不写文件。
