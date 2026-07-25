# Text 与 Document

## 定位

`Text` 是不可变文本值，`Document` 是可编辑文档。二者不依赖 parser、language
mode、command loop 或前端。语言分析只消费 snapshot 和 normalized change set。

## Text

`Text` 使用持久化 chunked B+ tree。叶节点保存大小受限的 byte chunk，内部节点
保存子树摘要：

```text
Summary {
  bytes,
  line_breaks,
  utf16_units
}
```

编辑只复制从根到受影响叶的路径，其余节点共享。复制 `Text` 和创建 snapshot
因此是常数级句柄操作；遍历使用 chunk cursor，调用方不要求正文连续存储。

内部坐标统一为 UTF-8 byte offset。line/byte、line/UTF-16 column 和 byte
之间的换算沿摘要树进行。offset 必须落在 `[0, byte_length]`，需要字符边界的
操作还必须验证 UTF-8 code point 边界。

## Document identity 与 revision

每个 `Document` 有稳定 identity 和单调递增 revision。snapshot 固定以下值：

```text
DocumentSnapshot {
  document_id,
  revision,
  text
}
```

snapshot 不随后续编辑变化，可安全用于渲染、分析请求和结果校验。派生结果同时
携带 document identity 与 revision，避免把一个 buffer 的缓存应用到另一个 buffer。

## Transaction

一个 document 同时最多有一个 pending transaction。transaction 内的编辑使用
当前 pending text 坐标，提交时被规范化为旧 revision 上的有序、互不重叠 change：

```text
Change {
  old_range: [start, end),
  inserted_text
}
```

提交是唯一发布边界：

1. 验证全部范围与 UTF-8 边界；
2. 生成新 `Text`；
3. 结算 anchor；
4. 在 undo tree 中加入边；
5. 增加 revision；
6. 返回旧、新 snapshot 与 normalized changes。

命令可读取 pending snapshot，以便在一次原子编辑中先插入字符，再基于结果计算
缩进。取消 transaction 丢弃 pending text 和 pending anchor 变化。

## Anchor

anchor 是 document identity 内的持久位置：

```text
DocumentAnchor {
  id,
  offset,
  affinity: before | after
}
```

插入恰好发生在 anchor 处时，affinity 决定 anchor 留在插入文本之前还是之后；
删除覆盖 anchor 时，位置收敛到删除区间边界。anchor 同时支持 committed 与
pending 坐标解析，使 selection、诊断和跳转位置可以参与原子命令。

跨 document 的位置必须同时携带 resource 或 document identity，不能只保存裸
offset。

## Undo tree

undo 历史是 `Text` snapshot 组成的树，而不是逆向编辑数组。普通提交从当前节点
创建子节点；在历史节点上继续编辑自然形成分支。undo 和 redo 选择树边并把目标
`Text` 发布成 document 的新 revision，因此所有观察者仍按同一 revision 协议同步。

anchor 随历史边的 change set 正向或反向结算。对任意两个历史节点的跳转可通过
最低公共祖先分解为一段反向边和一段正向边。

## Buffer 边界

Scheme `Buffer` 组合：

```text
Buffer {
  id,
  document,
  resource,
  revision,
  file_path?,
  saved_revision,
  pending_save_revision?,
  language_catalog,
  major_mode_name,
  local_settings,
  language_runtime
}
```

`Document` 不知道 resource、dirty 状态、major mode 或 view。`resource` 是显示与
project identity，`file_path` 是可写入的本地路径；generated Buffer 可以有
resource 而没有 file path。Buffer 比较 `saved_revision` 与当前 revision 决定
modified 状态，并负责在 commit、undo、redo 后同步 language runtime。

Buffer 的 `revision` 是已经被 Buffer 及其 language runtime 接受的 Document
revision。Scheme 编辑命令通过 `call-with-buffer-transaction` 修改文本；该边界提交
transaction、推进 Buffer revision，并同步派生语言状态。

直接操作 Document 的 native 机制必须返回 normalized change。调用方随后用
`buffer-adopt-change!` 把 change 交给所属 Buffer。change 的 old revision 必须等于
Buffer revision，new revision 必须等于 Document 当前 revision；同一个 change
只能接受一次。存在未接受的 Document change 时，Buffer 拒绝新的编辑、undo、
redo 和 mode 切换。这一约束使 indentation 等 native 机制不需要依赖 Buffer，
同时避免绕过 language runtime 同步。

## 保存

`file.save` 在 update turn 中从当前 snapshot 构造不可变 request：

```text
SaveRequest {
  buffer_id,
  document_id,
  revision,
  path,
  bytes
}
```

Buffer 同时只有一个 pending save。runtime effect 异步写入 request 中的 bytes；
完成事件再进入 command loop。成功完成只把 `saved_revision` 推进到 request
revision，因此写入期间发生的新编辑仍保持 modified。失败清除 pending 状态但不
改变 `saved_revision`。

基础 file runtime 对已有 `file_path` 执行整文件 open、truncate、write、close。
同一 request 协议支持由 minibuffer/resource policy 选择目标 path 的另存为流程。
需要临时文件、权限保留、备份或原子 rename 的环境可以替换 file effect handler，
不改变 Buffer revision 语义。

## ABI 与线程归属

native ABI 使用 opaque handles 和显式 retain/close。返回的 byte span 只有在其
所属 handle 的契约期限内有效；跨 Scheme 调用保存数据时应复制为 bytevector。

Document 的 mutation、anchor 操作与 handle 释放都发生在创建它的 editor thread。
不可变 `Text` 的实现允许内部共享，但当前 editor 不以跨线程访问作为公开契约。

## 设计依据

piece table 与 rope 都能支持编辑；这里选择持久化摘要树，是因为同一个值同时服务
snapshot、undo、增量 parser、结构 diff 和坐标换算。undo 直接引用文本值，可以
保留分支且无需维护另一套逆操作语义。Document 将“值”与“可变发布点”分开，使
parser 和 UI 都能以 revision 检验自己的观察结果。
