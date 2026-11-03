# 文本坐标与逻辑列

文本位置以 UTF-8 字节为基础，行内字节坐标与 tab 展开后的逻辑列分开表示。字体布局、软换行和屏幕位置由显示层按前端的 `Measure` 换算（见[终端界面](ui.md)）。Ropey 的字符索引只在存储层使用。

## 表示与所有权

| 表示 | 含义与有效范围 |
| --- | --- |
| ByteOffset | 相对一个快照的文档字节偏移，使用前仍需校验 |
| TextPoint | 零起始 row 与行内 byte_column |
| LogicalColumn | 从行首计算的逻辑格数，依赖 tab width |
| Selection、Change、parser 范围中的 usize | UTF-8 字节坐标；parser 节点与 token 下标另有作用域 |
| DocumentPosition | DocumentId、文本修订、ByteOffset 与 Association，用于跨命令保留位置 |

`Snapshot::text_point` 与 `byte_offset` 是严格转换。合法边界包括 CRLF 内部；行结束之后的位置属于下一行，所以每个位置只有一个 TextPoint。非法边界、越界和非标准行列组合返回错误。

ByteOffset 与 TextPoint 不绑定文档或版本。跨命令保留位置使用 DocumentPosition（`Document::position` 创建）：`resolve` 要求同一文档的当前修订；`map` 只接受同一文档、`before_revision` 与之相等的 DocumentUpdate，`track_deletion` 时替换范围内部的位置失效。位置存活不代表诊断、补全等语义结果仍然有效。

## 严格校验与 clipping

事务拒绝非法范围，不用 clipping 修复调用者的编辑。导航和外部定位显式调用：

| 函数 | 行为 |
| --- | --- |
| `clip_byte_offset` | 限制到文档长度，按 Association 选 UTF-8 标量边界 |
| `clip_text_point` | 限制到该行内容范围，不进入 CRLF 内部；越界 row 落在 EOF |
| `clip_grapheme_offset` | 先校正标量边界，再按 Association 选扩展字符簇边界 |

导航把 CRLF 当作一个单元。LF、CRLF 和单独 CR 的原字节保留，单独 CR 属于行内容。

## 逻辑列规则

逻辑列按扩展字符簇累加 unicode-width 格宽；ASCII 控制字符宽度为零，tab 前进到下一个 tab stop。跨字符簇的字体连字不合并，例如 `لا` 占两格；字形塑形属于前端。

`column_width` 作用于连续文本，`logical_column_at` 与 `offset_at_logical_column` 作用于快照，规则相同。行分隔符内部的列等于行内容末尾的列，字符簇内部取簇前位置。反向查询落在 tab 或宽字符内部时返回簇前；同列的零宽字符向后消费，因此反向转换不对每个字节位置一一对应。

C++ 缩进、空白命令、Tab、`Goto` 和垂直移动共用这套规则。会话期望列以 LogicalColumn 保存，失效条件见[编辑命令与无 UI 工作流](commands.md)。

## 实现与性能

- 文本点转换使用 Ropey 的字节和行索引；编辑前先校验字节范围，再在存储层转换为字符索引。`byte_slice` 复用 Ropey 的可失败切片。
- 字符簇导航使用 unicode-segmentation 的 `GraphemeCursor`，只提供当前 chunk、相邻 chunk 和 segmenter 请求的前置上下文。普通移动不扫描行首、不复制整行；超长组合序列、区域旗帜等可能读取更大范围。
- 逻辑列查询扫描行前缀，ASCII 段批量计数；跨 chunk 的字符簇只为该簇生成临时字符串。
- `leading_whitespace` 借用前导空白。坐标查询不初始化快照的连续全文缓存。

```sh
cargo test --test coordinates
cargo run --release --example text_coordinate_trace -- 1000000 100
```

测试以连续字符串的字符簇分段为独立基线，检查所有标量边界上的移动与删除、跨 chunk 上下文、clipping、列转换和修订映射。性能工具测量长行尾部的移动、删除和逻辑列查询，前缀扫描与局部导航分开报告。

语言服务器的 UTF-16 列在 `lua/lsp.lua` 中转换，见[语言服务器](lsp.md)。
