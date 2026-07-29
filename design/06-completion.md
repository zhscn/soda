# 补全管线

## 定位

补全是一个多 provider、异步、revision-aware 的会话。provider 生产候选与补充
编辑；管线负责世代、合并、过滤、呈现和原子应用。language mode 选择 provider
组合与触发 policy。

## Provider

provider 接口：

```text
start(request) -> immediate response messages
cancel(request)
```

provider 可以是 LSP session、path、buffer words、snippet、Scheme 静态语义索引
或 InteractionSession runtime catalog。每个结果携带 provider identity、request
generation、document identity 与 revision。Scheme provider 的 DefinitionId 和
静态/运行时合并规则见 [11-scheme-semantics.md](11-scheme-semantics.md)。

请求向全部有效 provider 扇出。首个结果即可显示；迟到结果按 provider 整组替换，
不会冻结或重建其他 provider 的条目。新输入推进 generation，旧 response 和旧
resolve 在落地前自然失效。

异步 provider 通过 command loop message 返回结果：

```text
CompletionResponse {
  session_id,
  generation,
  provider,
  target_id,          // DocumentId 或 PromptSessionId
  target_revision?,   // Document target 必填
  items,
  complete
}
```

provider 和 worker 只构造 response，不持有或修改 Editor、View、Buffer 与
DocumentTransaction。command loop 接收 response 后验证会话、generation、target
identity 和 revision，再以 provider 为单位替换结果集。这个边界使 native worker、
libuv callback 和 Scheme provider 使用同一种回传方式，同时保持 Editor state
由单线程拥有。

Editor 的 completion provider catalog 以稳定 symbol 注册 provider。Buffer 或
language mode 的 `completion-providers` setting 选择参与当前 Document session 的
provider：

```text
CompletionProvider {
  name,
  start(request) -> immediate response messages,
  cancel(request)
}
```

query generation 改变时，command loop 依次产生旧 request 的
`completion.cancel` effect 和新 generation 的 `completion.request` effect。
effect handler 调用 catalog 中的 provider。同步 provider 可以直接返回 response；
异步 provider 返回空列表，并在 libuv 或 worker 完成后投递同样的 response message。
`cancel` 按 request identity 设计为幂等操作。provider 异常被隔离为该 provider 的
空完成结果，不终止 editor command loop。

每个 generation 显式持有尚未完成的 provider request。response 只接受该集合中的
provider；`complete` response 退休对应 request，之后来自该 provider 的同世代
response 不再生效。只要仍有 request，completion session 就保持活动，即使 choice
source 暂时没有同步候选。全部 request 完成且 Document session 没有候选时，会话
关闭并释放 transient input state。

## CompletionItem

```text
CompletionItem {
  id,
  provider,
  filter_text,
  label,
  insert_text,
  kind,
  detail,
  edit: CompletionEdit?,
  sort_text,
  annotation?,
  group?,
  is_snippet,
  resolved,
  documentation?,
  provider_data
}

CompletionEdit {
  insert: {
    insert_range,
    new_text
  },
  replace: {
    replace_range,
    new_text
  },
  additional_edits
}
```

`id` 在一个 generation 内稳定，UI、resolve 和 apply 都按 id 寻址，不用 label
反查。菜单需要的轻字段随初始响应归一化；documentation 和其他重字段只对选中项
及可视范围懒 resolve。

范围绑定请求 snapshot。provider 未指定 edit 时使用 session 的通用 insert/replace
范围；LSP 的 insert/replace 双范围原样保留到 apply policy。additional edit 与主
edit 不得重叠。

## Composition session

Document completion 是 editor 拥有的 text rewrite session。正文、caret、selection
和 anchor 始终由 editor command loop 管理；provider 只读取带 revision 的 snapshot
并返回候选。用户在菜单存续期间输入的文本已经属于正文，不是临时 preedit。

session 跟踪三个逻辑边界：

```text
query range:    [query_start, caret)
insert range:   [query_start, caret)
replace range:  [query_start, replacement_end)
```

`query_start` 和 `replacement_end` 是 Document anchor。起点使用
before-insertion affinity，替换终点使用 after-insertion affinity。普通事务、
undo 和 redo 自动映射这两个边界，session 不保存易失的绝对起点。

caret 可以在 `[query_start, replacement_end]` 内移动。向左移动缩短 query；向右
移动把已有正文纳入 query。移动越过任一边界、切换 View/Buffer、产生不兼容
selection，或者使 anchor 无法解释的编辑会关闭 session。

completion controller 观察命令执行后的 Document transaction 和 selection
状态。普通字符、Backspace、Left、Right 继续执行标准 editor command；controller
根据提交后的正文和 caret 刷新 query。候选导航、接受和取消才是 completion
专用命令。由此，宏、undo、kill 命令和语言命令不需要在 key handling 层分别适配
completion。

## Refilter 与排序

每个 provider 记录 `is_incomplete`。query 变化时：

- complete 结果在本地 refilter；
- incomplete provider 重新请求并替换自己的 item set；
- query 退回触发点之前时关闭会话。

匹配文本优先使用 `filter_text`，否则使用 `label`。choice source metadata 选择按
顺序尝试的 `prefix`、`substring`、`flex` style 和大小写策略。匹配产出
`CompletionMatch(score, ranges, exact)`，其中 ranges 使用 `filter_text` 字符索引，
供 presenter 高亮命中片段。

所有 provider 进入同一个排序：style 层级、exact、匹配紧凑度、起始位置、
`sort_text` 和 label。provider priority 只作为明确的 tie-break policy，不用短路
方式隐藏较晚来源。异步合并和 refilter 通过 `(provider, item-id)` 恢复选择，不把
旧的列表索引解释成候选身份。

语义重复可按最终 `new_text`、range 和 kind 去重；原 item identity 仍保留在
provider side table 中供 resolve。

## 触发

触发事件包括手动命令、标识符输入和 provider trigger character。language profile
使用 syntax view 做门控：

- comment/string context 可限制普通 identifier provider；
- include/import context 可以只启用 path provider；
- member access 触发语义 provider；
- provider capability 决定有效 trigger character。

触发节奏是 policy，可根据事件类别和 provider RTT 选择 debounce。generation 与
revision 校验是固定机制，不能由 debounce 代替。

## 应用

接受 item 有 `insert` 与 `replace` 两种 mode。没有显式 CompletionEdit 时，
`insert` 替换 query range，`replace` 替换到 `replacement_end`。显式
CompletionEdit 为两个 mode 分别提供 snapshot range 与 replacement text。

接受 item 时重新验证 document identity、revision 和 edit range。当前正文保持
不变，直到候选被解析成完整 commit。主 text edit、`additionalTextEdits` 和
snippet 初始展开合并为一个 `DocumentTransaction`；跨资源 additional edits 使用
[05-jump.md](05-jump.md) 的 workspace edit。

```text
resolve candidate if required
        │
        ▼
CompletionCommit
        │  map ranges and validate revision/context
        ▼
one DocumentTransaction
        │
        ▼
caret/selection result
```

command loop 在执行命令前验证活动 Document target。命令通过该 loop 修改 query
range 后，session 才把 target 推进到新 revision；来自其他 view 或后台提交的
revision 变化会关闭旧 session，不能由一次普通 refresh 追认。

需要 resolve 才能获得完整 additional edits 的 item，在 resolve 成功且 generation
仍有效后再提交。provider 不获得可变 Buffer，也不在 commit 前删除 query。应用
结果只产生一个 undo 单元，不通过“先插入、再删除、再修正”模拟。

## UI 与输入

completion menu 是 caret-relative TUI overlay，不进入 WindowLayout。它持有
generation、item ids、selected id 和 scroll range。documentation 可显示为相邻
overlay。

菜单可见时注入 transient keymap layer；导航、接受和取消是普通 command。未消费
的文本输入继续走 buffer 插入，然后推进补全 query。UI 关闭只释放会话视图，不取消
可复用的 provider cache。

presenter 对可见候选统一计算 annotation 列，使用 match ranges 高亮 label，并显示
候选总数和当前选择位置。空结果区分 provider 尚未完成与已完成但没有匹配。
Document completion 默认预选首项；minibuffer completion 的选择策略由 choice
source metadata 声明。

合并时选中项按 `(provider, item-id)` 保持身份。某个 provider 的迟到响应只替换
该 provider 的结果；其他 provider 的候选、完成状态和选中项保持不变。

补全应用目标显式区分普通 Document range 与 minibuffer Prompt range。两者共享
候选、generation、过滤排序和 presenter；Document target 校验 document revision
与 edit range，Prompt target 校验 prompt session id，并保存当前 field 的 start、
point 和 replacement end。Prompt query 只覆盖 `[start, point)`，选择候选原子替换
整个 `[start, replacement-end)` field。命令、Buffer、路径和其他离散集合通过
choice source 进入同一管线，读取生命周期见
[12-minibuffer.md](12-minibuffer.md)。

`completion.at-point` 是 Document completion 的统一手动入口。choice source 的
boundary procedure 根据 caret 上下文返回 query range；language mode 可以通过
buffer setting 提供 reader-aware boundary policy。相同 lexical policy 从 caret
向右计算默认 `replacement_end`。没有语言 policy 时使用字母、数字和下划线。

Document 的 editable start 是补全可读取和替换的下界。普通源码 Buffer 的下界为
零；comint transcript 把它推进到当前 prompt 之后。因此通用 completion 只处理
当前可编辑输入，不需要知道 InteractionSession、prompt 或 transcript 格式。
buffer-word source 从该区域收集去重词项，再与 mode 选择的异步 provider 进入同一
session。默认 `M-/` 启动该命令；菜单提供 insert accept、replace accept、遍历和
取消命令。Enter 或 `C-j` 执行 insert accept，`M-Enter` 执行 replace accept，
Tab、Shift-Tab 和 Up/Down 遍历候选。Left、Right 与 Backspace 保持普通编辑语义
并动态改变 query。

## 设计依据

同步 completion table 把“产生候选”和“菜单已完整”绑定，会迫使异步 provider
阻塞或从旁路注入。Helix 与 Zed 的实践表明，世代取消、per-provider replacement、
`isIncomplete` 和懒 resolve 能形成稳定的异步骨架。Soda 进一步把候选身份、范围
校验与 Document revision 绑定，使迟到结果和 additional edits 使用同一正确性
规则。
