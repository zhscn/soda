# Text 与 Document

## 实现状态

| 能力 | 状态 |
|---|---|
| 持久 Text、snapshot 与 UTF-8/UTF-16 坐标换算 | 已实现 |
| Document identity、revision 与原子 transaction | 已实现 |
| anchor、undo tree 与 redo branch | 已实现 |
| BufferState transaction 集成 | 已实现 |
| 文件资源绑定、保存点与重新读取 | 部分实现 |
| 外部冲突、自动保存与崩溃恢复 | 未实现 |

## 定位

`Text` 是不可变文本值，`Document` 是具有 identity、revision 和编辑历史的文本容器。
二者不依赖 Buffer、View、mode、parser、command loop 或前端。Buffer 的局部扩展和文本 UI
契约由 [03-buffer-ui.md](03-buffer-ui.md) 定义。

```text
native Text / Document
        │ snapshot + normalized change
        ▼
kernel BufferState transaction
        │
        ▼
host Buffer / package StateField
```

## Text

Text 使用持久化 chunk tree。叶节点保存有界 byte chunk，内部节点保存 byte size、line break
和 UTF-16 unit 摘要。编辑只复制受影响路径，snapshot 和未变化子树共享存储。

内部 canonical coordinate 是 UTF-8 byte offset。公开查询提供：

- byte offset 与 line/byte column 互换；
- byte offset 与 line/UTF-16 column 互换；
- code point 与 grapheme 前后边界；
- line start、content end 和子区间读取。

需要字符边界的 change 必须落在合法 UTF-8 boundary；LSP adapter 在边界处转换 UTF-16，
kernel、selection 和 RangeSet 不保存 UTF-16 offset。

## Snapshot 与 revision

每个 Document 有不复用的 identity 和单调递增 revision：

```text
DocumentSnapshot {
  document_id,
  revision,
  text
}
```

snapshot 固定其 Text，不随后续编辑变化。异步分析、渲染缓存和 I/O request 同时携带
document identity 与 revision；任一不匹配时结果失效。

snapshot 句柄显式关闭，Scheme wrapper 使用 guardian 回收不可达句柄。host Buffer 保留仍被
published BufferState 引用的 snapshot，不能把 native Text pointer 暴露给 package。

## Transaction 与 Change

Document transaction 以当前 revision 开始，在 pending text 坐标中接受 insert、replace 和
erase。commit 验证所有范围后一次发布，并返回 normalized `Change`：

```text
Change {
  old_revision,
  new_revision,
  edits: ordered non-overlapping old ranges + inserted Text
}
```

同一 Document 同时最多有一个 pending transaction。abort 丢弃 pending text 和 anchor 更新。
命令可以读取 pending snapshot，以便把输入、缩进和配对编辑组合为一次原子 change。

kernel 的 `ChangeSet` 是纯值表示，用于 transaction resolve、compose、invert、selection mapping
和 StateEffect mapping。native `Change` 进入 host 时转换或验证为同一 normalized 语义。

## Anchor

Anchor 是 Document identity 内的长期位置：

```text
DocumentAnchor {
  id,
  offset,
  affinity: before | after
}
```

插入恰好发生在 anchor 处时由 affinity 决定停留侧；删除覆盖 anchor 时位置收敛到删除边界。
Anchor 用于异步 request origin、bookmark 和资源位置。Selection 与 RangeSet 在 transaction 内
使用 ChangeDesc mapping，不为每个端点创建 native anchor。

跨 Document 位置必须附带 DocumentId 或资源 identity，不能只保存 byte offset。

## Undo tree

Document 历史是 snapshot tree。普通提交从当前 node 建立 child；从旧 node 继续编辑形成 branch。
undo、redo 和 undo-to 都发布新的 Document revision，因此 observer 始终只处理向前递增的
revision，即使正文回到旧 snapshot。

Buffer history package 决定哪些 command transaction 合并、哪些 annotation 形成边界，以及
save point 如何解释。Document 只提供历史机制，不判断用户操作语义。

## BufferState 集成

`BufferState` 保存当前 DocumentSnapshot 和 extension state。一次 editor transaction 原子产生：

- normalized document change；
- mapped Selection；
- Buffer scope StateField update；
- origin/all View scope effect；
- transaction annotation 与 scroll request。

host 只发布完整的新 BufferState 和相关 ViewState。直接调用 native Document mutation 后必须在
同一 host boundary 提交对应 normalized change；revision 不连续或重复采用的 change 被拒绝。

## 文件边界

文件是 package resource，不是 Document 字段。file package 负责：

```text
ResourceBinding {
  canonical resource,
  observed version,
  encoding,
  line ending,
  saved history position
}
```

读取把 bytes 解码并规范化为 Document 文本，再通过 ordinary transaction 或初始 BufferState
发布。保存冻结 DocumentId、revision 和 bytes；写入完成后只有匹配 request identity 的结果
可以推进保存点。undo 回到保存历史位置恢复 clean，revision 相等本身不定义 modified 状态。

文件读取、保存、另存为和外部 watch 通过 command effect/host message 返回，不能从 I/O callback
直接修改 Document 或 BufferState。

## Contract tests

Document contract tests 覆盖：

- UTF-8、line 和 UTF-16 坐标往返；
- transaction commit/abort 与 normalized edit 顺序；
- snapshot 在后续编辑后保持不变；
- anchor affinity、删除收敛和 undo/redo mapping；
- undo branch 与单调 revision；
- ChangeSet compose/invert/map；
- stale revision 和重复 change adoption 被拒绝。
