# 文本坐标与逻辑列

坐标按单位与作用域区分。文本位置以 UTF-8 字节为基础，行内字节坐标与 tab 展开后的逻辑列分别表示；字体布局、软换行和屏幕位置由前端转换。Ropey 的字符索引只用于存储适配，不作为编辑接口的统一坐标。

## 表示与所有权

| 表示 | 含义与有效范围 |
| --- | --- |
| ByteOffset | 相对一个快照的文档字节偏移；构造值后仍需校验 |
| TextPoint | 零起始 row 与行内 byte_column |
| LogicalColumn | 从行首计算的逻辑格数，依赖 tab width |
| Selection、Change、parser 范围中的 usize | 明确的 UTF-8 字节坐标；parser 节点与 token 下标具有独立作用域 |
| DocumentPosition | DocumentId、文本修订、ByteOffset 和 Association，供跨命令保留位置 |

`Snapshot::text_point` 与 `byte_offset` 是严格转换。合法 UTF-8 边界包括 CRLF 内部的字节位置；行结束后的坐标使用下一行 row，因此 TextPoint 具有唯一的标准表示。非法字节边界、越界和非标准行列组合返回错误。

ByteOffset 与 TextPoint 不自动绑定文档或版本。保留位置时使用 DocumentPosition：resolve 要求同一文档与当前修订，map 要求来自同一文档、起始修订一致的 DocumentUpdate。映射可以选择让替换范围内部的位置失效。位置仍然存活不证明诊断、补全或其他语义结果仍然有效。

## 严格校验与 clipping

事务严格拒绝非法范围，不通过 clipping 修复调用者的编辑。导航或外部定位可以显式调用：

- `clip_byte_offset`：限制文档范围，并按 Association 选择 UTF-8 标量边界。
- `clip_text_point`：限制到指定行的内容范围，越界 row 落在 EOF。
- `clip_grapheme_offset`：先校正标量边界，再按 Association 选择扩展字符簇边界。

导航把 CRLF 作为一个单元。原文件的 LF、CRLF 和单独 CR 字节保留；单独 CR 在文本行索引中仍属于普通行内容。

## 逻辑列规则

逻辑列按扩展字符簇逐个累加 unicode-width 的格宽。ASCII 控制字符宽度为零，tab 前进到下一个 tab stop。跨字符簇的字体连字不合并逻辑列，例如 `لا` 使用两个逻辑格。GUI 字体塑形与前端显示位置独立处理。

`column_width` 用于连续文本；`logical_column_at` 与 `offset_at_logical_column` 用于快照，采用相同规则。行分隔符内部的逻辑列等于行内容末尾列，字符簇内部的查询取簇前位置。反向查询落在 tab 或宽字符内部时返回该簇前方；同列的零宽字符向后消费，因此反向转换不承诺为每个字节位置建立一一对应。

C++ 缩进、手动空白命令、Tab 和垂直移动共用逻辑列规则。EditorSession 的期望列使用 LogicalColumn，连续垂直移动复用已有值；实际文本或度量策略变化时使其失效。

## Ropey 与性能边界

文本点转换使用 Ropey 的字节和行索引；编辑前校验字节范围，再在存储层转换为字符索引。`byte_slice` 复用 Ropey 的可失败切片接口，避免重复边界检查。

字符簇导航使用 unicode-segmentation 的 GraphemeCursor。适配器提供当前 chunk、相邻 chunk，以及 segmenter 请求的前置上下文。普通移动不扫描行首，也不复制整行；极长组合字符、区域旗帜等上下文相关序列可能要求更大范围的读取。

逻辑列查询按需要扫描行前缀，ASCII 连续段批量计数。字符簇跨 chunk 时，仅为该簇的宽度计算生成临时字符串。`leading_whitespace` 借用前导空白，输入、继承缩进和手动缩进不会仅为取得前缀复制整行。坐标查询不初始化快照的连续全文缓存。

```sh
cargo test --test coordinates
cargo run --release --example text_coordinate_trace -- 1000000 100
```

测试使用连续字符串的字符簇分段作独立基线，检查全部标量边界上的移动与删除、跨 chunk 上下文、clipping、列转换和修订映射。性能工具测量长行尾部的移动、删除和逻辑列查询；逻辑列前缀扫描与局部导航分别报告。

## 设计参考

Zed 位于 `~/project/zed`。参考 `crates/rope/src/point.rs`、`point_utf16.rs` 与 `rope.rs` 的坐标单位与索引转换，`crates/editor/src/display_map.rs` 的显示坐标分层，以及 `crates/text/src/anchor.rs` 的身份与 bias 契约。UTF-16 坐标在语言协议适配层接入时独立表示。
