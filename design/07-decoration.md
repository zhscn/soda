# Decoration 与文本区间元数据

## 三类数据

Decoration 按生命周期分为三条通道：

1. **从当前 snapshot 派生**：syntax highlight、selection、search match。
2. **外部事实**：diagnostic、semantic token、inlay hint、coverage。
3. **瞬时 View 状态**：completion preview、matching delimiter、输入提示。

三类数据不能共享同一种持久化规则。派生数据按需重算；外部事实跨 revision
重放；瞬时状态随 View 会话销毁。

## AnnotationSet

外部事实按 namespace 保存：

```text
AnnotationSet {
  namespace,
  document_id,
  source_revision,
  generation,
  annotations
}

Annotation {
  id,
  anchor_range,
  kind,
  severity?,
  payload_id?,
  stale
}
```

namespace 由 producer 拥有，例如一个 LSP session 的 diagnostics 或 semantic
tokens。发布新 generation 原子替换同 namespace 的旧集合。大 payload 放 side
table，区间树只保存排序和渲染需要的轻字段。

source range 在发布时解析到对应 snapshot，并转为 anchor range。Document commit
后 anchor 继续维护可回收的位置所有权。strict-source 集合只在 source revision
显示；Buffer revision 改变后整组进入 stale 状态，直到 producer 针对新 revision
发布更高 generation。新结果按 `(namespace, buffer, generation)` 校验并原子替换
旧集合；被替换、拒绝、清除或随 Buffer 销毁的集合同时释放全部 anchor。

stale policy 由 annotation channel 定义。diagnostic 使用 strict-source policy，
编辑后立即隐藏整组。需要跨 revision 保留的 producer 在发布前负责把结果映射到
目标 snapshot，并以新 generation 交给 Editor。

## 合并管线

renderer 对一个可见行收集各通道的 run，按显式 layer 和 priority 合并：

```text
base syntax
semantic refinement
diagnostic style
search
selection
caret/transient feedback
```

同一 layer 的稳定顺序由 namespace 与 annotation id 决定。合并只产生 frame run，
不修改 Text。frame compositor 把语义 face 栈解析为最终 style，同时把参与合并的
layer、owner 和 annotation identity 保存在 cell sources 中。terminal presenter
只消费最终 style；annotation 只表达语义 role。

`DecorationRun { start, end, face, layer, priority, owner, detail }` 是派生通道的
公共区间值。range 使用 Document byte offset，并且只属于生成它的 revision。
Scheme highlight provider 从共享 lexical token stream 生成 comment、string、
delimiter、definition、keyword、builtin、type 与 literal face。selection 作为更高
layer 追加到同一个 face 栈，因此高亮信息仍可由 `describe-char` 检查。

## 虚拟文本与替换

frame run 支持三种来源：

```text
TextRun        // 映射真实 document bytes
VirtualRun     // 锚定在 byte position，不占 document bytes
ReplacementRun // 视觉替换一个真实 range，仍保留源映射
```

inlay hint、completion ghost text 和 line-end diagnostic 使用 `VirtualRun`。
隐藏标记、不可见字符替代和 fold placeholder 使用 `ReplacementRun`。hit test
必须能从任一 cell 回到 document position；虚拟 cell 使用 before/after affinity
决定 caret 落点。字符检查、face 检查和渲染诊断读取同一 cell mapping 与 sources。

## Fold

fold 是 View 层的 range transform：

```text
Fold { anchor_range, placeholder, kind, collapsed }
```

语法 provider、outline 工具或用户命令产生 fold range，View 决定 collapsed 状态。
fold 不删除 Text，也不进入 Document undo。编辑触及 fold 时，policy 可以展开
对应 range；anchor 负责其余编辑下的位置结算。

## Generated buffer

工具界面可以提供生成式 buffer：

```text
GeneratedBuffer {
  model,
  render(model) -> Text/rows,
  action_at(position)
}
```

它适用于 location list、project picker、build output 和状态面板。model 是权威值，
显示文本是投影；command 通过 item identity 操作 model，不解析屏幕字符串。
需要编辑源文件的多资源界面使用 [05-jump.md](05-jump.md) 的 ComposedView，
而不是把 generated text 伪装成源 Document。

## Diagnostic 集成

diagnostic producer 将协议坐标解析到发布 snapshot，再创建 AnnotationSet。gutter、
下划线、行尾消息和 location list 都消费同一 annotation identity 与 payload。
location list 是呈现/导航投影，不复制诊断所有权。`diagnostics.list` 把活动 Buffer
的当前 diagnostics 按 byte range 排序并发布为通用 LocationList；后续导航复用
`xref.next-location` 与 `xref.previous-location`。替换或清除集合会同时废弃引用
旧 annotation identity 的 current diagnostics list。

## 设计依据

Emacs overlay 把元数据、显示替换、keymap 和生命周期放入同一对象，组合时容易形成
隐式优先级。Neovim extmark、Helix decoration 和 Zed anchor 的共同结论是：外部
事实需要稳定位置与明确 namespace，而 selection 和 popup 应留在 View。三通道
模型让更新频率和 stale policy 成为数据所有者的契约，renderer 只负责确定性合并。
