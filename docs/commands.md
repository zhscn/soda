# 编辑命令与无 UI 工作流

命令采用 CodeMirror 的职责划分：文本位置原语独立于前端，命令根据状态生成选区或事务，历史策略根据输入事件组织操作，搜索查询和 cursor 独立于搜索界面。C++ 缩进通过语言建议接入，同样由事务入口提交。

## 位置与选区

所有公开文本位置使用 UTF-8 字节偏移。core 提供字符簇步进、逻辑列计算与列到位置转换。字符簇使用 unicode-segmentation，列宽使用 unicode-width，tab 前进到下一个 tab stop。LF 和 CRLF 各作为一次跨行移动与删除，原文件字节保留。

`Move` 分别表达 Backward、Forward、Up、Down、LineStart、LineEnd 和文档边界。`extend` 保持 anchor 并移动 head；不扩展的水平移动先将已有选区收拢到相应端点。上下移动在 EditorSession 中保留期望列，短行不会永久改变该列。目标列位于 tab 或宽字符内部时落在其前方。

文本变化、直接设置选区、非垂直移动及实际语言配置变化使期望列失效。各会话独立维护选区、期望列和搜索状态。

这些命令使用逻辑行与文本顺序。软换行、bidi 视觉顺序、屏幕行及像素位置属于前端适配；前端可以将其计算出的选区通过同一命令入口提交。

## 删除与空白

`Delete` 首先删除已有选区，否则按方向删除一个字符簇或行分隔符。外部定位落在字符簇或 CRLF 内部时，删除整个单元。空文档及文档边界上的删除为空操作。

Backward 的 `smart` 策略仅作用于光标前均为 tab/space 的行首区域，退到前一个缩进单位的列边界。当前 tab 跨越目标列时重新生成前缀，使结果列准确；代码和行边界仍采用字符簇删除。

`InsertTab` 在目标位置推进到下一个 tab stop；行首按 tab 策略生成 tab 或 space，代码内部仅 Always 使用 tab。`InsertLiteralTab` 明确插入一个 tab，不进行空白策略转换。`IndentSelection` 对当前行或选中的逻辑行按 IndentWidth 增减缩进，选区恰好结束于下一行行首时不包含该行。零缩进宽度为空操作。

空白设置和 materialize 位于共享 language 层。PlainText 默认使用宽度 4 和 space；C++ 从有效规则取得设置。结构、固定续行及对齐的计算仍属于 C++ 缩进服务，通用命令不访问 parser 节点。

## 历史策略

core 的 History 保存、组合和恢复修改。editor 的 InputHistory 只负责判断输入事件是否应与上一操作合并；事件类别通过 Transaction.user_event 与显式分组一起传递。

连续 TypeChar，或连续同方向 Delete，在同一会话、相同事件类别、当前修订和选区与上次结果一致、间隔不超过 500 ms 时合并。移动、选区命令、粘贴、换行、Tab、手动缩进、搜索操作、配置变化及历史恢复形成边界。文件保存请求和确认通过 checkpoint 形成边界。

`execute_at` 接收显式事件时间，用于确定性测试或宿主事件重放。普通 execute 使用控制器的单调时间。失败命令不更新分组策略。显式 Apply 使用调用方的 history_group，自动输入事件与显式组具有不同的历史键。

## 搜索与替换

SearchQuery 提供区分大小写的字面查询。SearchCursor 使用 memchr 匹配，逐 chunk 读取 rope，保留跨 chunk 的查询尾部，不请求全文字符串。cursor 返回非重叠的 UTF-8 字节范围，空查询没有匹配。

`SetSearchQuery` 更新当前会话的 SearchState。`Find` 选择前一个或后一个匹配，调用方决定是否环绕。搜索结果按当前快照重新计算，查询不依赖语法分析或 picker。

`ReplaceCurrent` 仅在当前选区仍完整匹配查询时替换；`ReplaceAll` 基于同一快照构造所有修改，一次提交与撤销。其他会话的选区通过精确变更映射。大小写折叠、正则表达式和项目搜索通过查询层继续扩展。

## 文件工作流

`Workspace::open_or_create` 打开已有文件或创建空的命名文档，并根据路径加载语言配置。新文件未写入磁盘时始终标记为未保存，包括空内容；文件服务不会隐式创建父目录。

`reload` 显式读取当前路径。存在本地未保存内容时要求 `discard=true`，保存请求执行期间拒绝重新加载。读取或配置失败保持原编辑状态。成功重新加载保留文档身份、更新 BOM 和磁盘基线，并通过一个文本事务替换内容；相同前后缀保持位置映射。返回 ReloadUpdate，同时包含编辑更新与文件更新。

重新加载的文本可通过历史恢复，当前磁盘基线保持最后读取内容。文件配置和编码元数据不属于文本撤销历史。

## 参考与验证

本地 CodeMirror 位于 `~/package/codemirror`。主要参考 `commands/src/commands.ts` 的状态命令与视觉移动边界、`commands/src/history.ts` 的事件分组、`state/src/transaction.ts` 的事务注解，以及 `search/src/cursor.ts` 和 `search/src/search.ts` 的查询与交互分离。

```sh
cargo test --test commands --test files --test mvp
cargo run --release --example cpp_input_trace -- PATH_TO_CPP_FILE 20
```

cpp_input_trace 对真实文件执行 Enter、闭合符输入和普通字符输入，每次撤销并验证原始文本。报告中位数、P95 和最大延迟，涵盖完整输入协调与语言分析。它不写入文件，时间不包含选区设置及撤销。不同文件、大小和编辑位置应分别测量，结构容错及具体缩进预期由编辑语料测试验证。
