# 渲染管线与 Theme

## 职责边界

渲染管线把一个 revision-scoped Document snapshot 和 View 状态投影为 terminal
frame：

```text
DocumentSnapshot
  -> SyntaxView
  -> HighlightCursor + AnnotationCursor + ViewDecorationCursor
  -> StyledChunkIterator
  -> DisplayMap
  -> Frame
  -> TerminalPresenter
```

各层拥有单一职责：

- `SyntaxView` 提供基础 lexical/syntax face，不拥有终端颜色；
- annotation channel 提供 diagnostics、semantic refinement 和其他外部事实；
- View decoration 提供 selection、search、caret 与瞬时反馈；
- `StyledChunkIterator` 合并有序区间并形成语义 face stack；
- `DisplayMap` 处理真实文本到视觉文本的结构变换；
- frame compositor 把 face stack 解析为 style 并生成 cells；
- presenter 比较 frame damage，只编码和排队 ANSI bytes。

renderer 是该管线的只读消费者。parse、lex、annotation 发布和 Document mutation
在 command loop 更新阶段完成。

## Render snapshot

一次 render 使用不可变的 `RenderSnapshot`：

```text
RenderSnapshot {
  editor_generation,
  theme_generation,
  layout_generation,
  views: [
    {
      view_id,
      document_snapshot,
      syntax_view?,
      annotation_generations,
      viewport,
      selection,
      display_state
    }
  ]
}
```

同一 View 的 Document、syntax 和 annotation 查询必须能说明各自 revision。
syntax view 与 Document revision 不一致时，该 View 使用可用的 lexical fallback
或无 syntax face；过期的 strict-source annotation 不进入 render snapshot。
renderer 不把不同 revision 的 syntax ranges 与正文组合。

## Face

producer 使用语义 face，不直接创建终端颜色：

```text
FaceId       // intern 后的小整数
FaceName     // Scheme-facing symbol 或 Tree-sitter capture name

FaceSpec {
  foreground: inherit | default | color,
  background: inherit | default | color,
  attributes_add,
  attributes_remove
}
```

base syntax 使用稳定的语义 face 词汇，包括 comment、doc-comment、string、
constant、number、keyword、builtin、type、function、function-call、variable、
property、label、operator、bracket、delimiter、preprocessor 与 invalid。producer
选择能够可靠判断的最具体 face；无法区分声明和引用的 identifier 保持 default，
由 semantic refinement layer 在具备 symbol 信息时继续细化。

C++ provider 先从增量 token snapshot 生成词法分类，再用同 revision 的 syntax tree
识别类型声明、函数与变量 declarator、class property、枚举常量、goto label 和宏
参数。分类结果按 buffer revision 缓存为 DecorationIndex，viewport 查询不重新运行
语言分析。

face name 使用从一般到具体的层级名称：

```text
comment
comment.documentation
string
keyword
function
function.method
type
variable
variable.parameter
constant
number
punctuation
punctuation.bracket
```

查找具体 face 时按名称层级回退，最终回退到 `default`。例如
`function.method.special` 可以依次查找 `function.method`、`function` 和
`default`。语言 profile 可以为语言专用 capture 声明通用 fallback，而无需 theme
认识每个 grammar 的全部 capture。

一个 chunk 的 face stack 按 decoration layer 和 priority 排序。最终属性按字段
合成：高优先级 face 提供的非 inherit 前景色、背景色覆盖低优先级值；attributes
通过显式 add/remove 组合。该规则允许 selection 改变背景色而保留 syntax 前景色，
也允许 diagnostic 只增加 underline。

## Theme

Theme 同时覆盖编辑器 chrome 和文档语义：

```text
Theme {
  name,
  appearance: dark | light,
  ui_roles,
  syntax_faces,
  diagnostic_roles,
  generation
}
```

`ui_roles` 至少包含：

```text
editor.background
editor.foreground
cursor
selection
line-number
line-number.active
modeline.active
modeline.inactive
minibuffer.prompt
popup
popup.selected
status.info
status.warning
status.error
```

chrome component 通过 role 请求 face。syntax provider、annotation producer 和
View decoration 也只发布 face identity。默认 theme 为每个内建 role 和通用 syntax
face 定义 terminal style。

Editor 持有按 name 索引的 `ThemeCatalog`。Scheme 配置可以向 catalog 注册 theme；
`theme.select` 使用 minibuffer completion 读取 catalog 中的名字并切换 active
theme。内建 catalog 提供 Catppuccin Latte、Frappé、Macchiato 和 Mocha，
默认使用 Mocha；每个 flavor 使用对应的 light/dark appearance 和官方 RGB
palette。

theme resolver 维护：

```text
(theme_generation, ordered_face_ids) -> ResolvedStyle
```

Tree-sitter grammar 额外维护：

```text
query_capture_index -> FaceId
```

该映射随 grammar/query set 建立并保留具体 capture identity。切换 active theme
会推进 theme generation、重建 `FaceId -> FaceSpec` 解析缓存、清空 composed style
cache，并使所有可见 View 失效。Document、syntax tree、capture mapping、
AnnotationSet 和 DisplayMap 的结构状态保持有效。

## Modeline

每个 Window leaf 拥有一行 modeline。modeline 从 Buffer、View、interaction
session 和 Editor chrome 状态构造语义 segment，再由纯布局器投影为 cell span：

```text
ModelineSegment {
  id,
  text,
  faces,
  priority,
  minimum_width,
  truncation: end | middle
}

ModelineSpan {
  id,
  column,
  text,
  faces
}
```

默认格式沿用 Emacs 的信息层次，并以 `right-align` 分隔左右区域：

```scheme
(state
 buffer
 position
 major-mode
 minor-modes
 process
 right-align
 message
 end)
```

Buffer local `modeline-format` 可以重排、隐藏这些 segment 或移动
`right-align`。`state` 显示字符编码、modified、read-only 和 pending-save
状态；`buffer` 使用 buffer identification 而不是完整资源路径；`position`
显示 Top、Bot、All 或百分比以及一基行号、零基列号；mode 区域显示 major mode、
minor modes 和 interaction process；focused View 的 Editor message 位于右侧。

布局器按 display cell width 计算 Unicode 文本。宽度不足时依次收缩低优先级
segment；buffer identification 保留最小宽度并从中间省略，使同名文件的前后信息
都可辨认。状态字段和 buffer identification 的优先级高于 position、mode、message
与终止标记。左右区域在同一约束求解中分配，不会相互覆盖。

Minor mode 使用 Minions 风格的默认呈现。Buffer local `minor-modes` 保存有序的
active mode 名称，`modeline-prominent-minor-modes` 指定仍在 mode 区域直接显示的
子集；其余 active minor modes 折叠为 `≡`。segment 的 chrome source 保留
`minor-modes` identity，供 TUI picker、鼠标前端和 describe 工具解析，而无需从
绘制文本反推状态。

modeline 使用分层 chrome face：

```text
modeline.active
modeline.inactive
modeline.buffer-id
modeline.status
modeline.position
modeline.mode
modeline.minor-modes
modeline.process
modeline.message
```

具体 role 找不到时按 `modeline.* -> modeline -> default` 回退。active 与 inactive
Window 使用不同 base face，segment face 只覆盖自身需要强调的属性。

## Highlight 与 annotation sweep

每种输入通道为 viewport range 提供有序 cursor。`StyledChunkIterator` 保存所有
cursor 的当前 run，并选择最近的 start/end 作为下一处边界：

```text
StyledChunk {
  source_range,
  text,
  faces,
  sources
}
```

在相邻边界之间，活动 face stack 和 sources 不变。iterator 一次生成整个 chunk，
frame compositor 再按 UTF-8 code point、tab width 和 terminal cell width 展开。
合并成本与可见文本和可见 decoration boundaries 成正比，不依赖整个 buffer 中的
annotation 数量。

base syntax、semantic refinement、diagnostic、search、selection 和 transient
feedback 使用 [07-decoration.md](07-decoration.md) 的稳定 layer 顺序。每个 source
保留 owner、namespace 和 identity，`describe-char` 因而可以从最终 cell 追溯参与
样式合成的 producer。

## DisplayMap

DisplayMap 把带语义样式的 document chunks 转换为 display chunks：

```text
Styled document chunks
  -> Virtual/Replacement
  -> Fold
  -> Tab expansion
  -> Soft wrap
  -> Display chunks
```

每个 transform 同时维护正向和反向位置映射。display cell 可以映射到 Document byte
position，也可以使用锚点和 before/after affinity 映射虚拟内容。replacement 和
fold placeholder 保留被替换的 source range。

没有 fold、virtual text 或 soft wrap 的 View 使用 identity transform；tab 展开
仍在 cell 生成阶段按显示列处理。新增 display feature 通过独立 transform 接入，
不会在 renderer 中增加按 feature 类型分派的绘制路径。

## Frame 与 presenter

frame cell 保留：

```text
Cell {
  text,
  width,
  continuation,
  faces,
  style,
  document_position?,
  sources
}
```

`faces` 和 `sources` 用于 inspection；`style` 是 presenter 唯一使用的视觉值。
presenter 比较前后 frame 的 cell 内容与 style，按连续行区间生成 damage spans。
光标移动单独比较，不要求正文重绘。

terminal output queue 保存尚未写出的最新提交序列。发生 partial write 时保留未写
suffix；尚未开始写出的旧 frame diff 可以被更新的目标 frame 合并替代。任何 ANSI
序列一旦开始写出就保持顺序和完整性。

## Invalidation

editor 使用 generation 和 damage range 表达失效，不从 renderer 反推变化：

```text
text damage       Document commit/undo/redo
syntax damage     syntax provider changed ranges
annotation damage AnnotationSet generation replacement
view damage       cursor/selection/viewport/display state
layout damage     resize/window tree/component extent
theme damage      active theme generation
```

text、syntax、annotation 和 View damage 尽量限制到受影响的 document/display
range。layout 改变使受影响 component subtree 失效；theme 改变使全部可见 cells
失效。command loop 只在存在 dirty View、layout、cursor 或待提交 terminal state
时建立新 frame。

syntax parse 和 highlight query 的工作预算属于 language runtime。frame 构建预算
属于 renderer。任何分步工作都携带 Document revision、View generation 和 theme
generation；发布前重新校验这些标识，避免过期结果进入 frame。
