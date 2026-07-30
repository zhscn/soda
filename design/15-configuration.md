# 配置状态与原子更新

Soda 的配置是 Editor 实例拥有的运行时状态。Scheme 代码通过公开的 Editor API 注册
setting、command、keymap、language、completion provider、minor mode 和 theme；
TUI renderer 只读取已经提交的状态。

## Setting

`SettingDefinition` 包含：

```text
name
default
validator
documentation
render impact
```

一个 Editor 持有一个 `SettingStore`，其 Buffer 共享该 store。值按以下优先级解析：

```text
buffer-local
→ editor-global explicit value
→ major-mode default
→ registered default
```

全局和 Buffer setter 验证值，并根据 definition 的 impact 发布 render invalidation。
替换 definition 时，已有显式全局值和所有 Buffer 的解析值都必须满足新验证器。

## Configuration snapshot

Editor configuration snapshot 捕获以下状态：

- setting definitions、显式全局值和 Buffer-local 值；
- command definitions、advice 和 command hooks；
- keymap catalog、父级关系、prefix map 和 bindings；
- language profiles 与 major modes；
- completion providers；
- minor-mode definitions、hooks 和 global active modes；
- theme catalog 与当前 theme；
- 每个 Buffer 的 major mode。

Keymap snapshot 保存原 keymap 对象的状态。恢复时原位写回 entries 和 parent，使持有
keymap 引用的 mode、扩展和测试继续观察同一个对象。Language catalog 恢复后重新安装
每个 Buffer 的 major mode，从恢复后的 profile 创建一致的 language runtime。

## Configuration transaction

`call-with-editor-configuration-transaction` 在调用配置过程前创建 snapshot。过程正常
返回时提交所有修改，并保留多返回值；condition 离开过程时恢复完整 snapshot，然后
重新抛出原 condition。

配置事务覆盖 catalog、setting、theme 和 mode runtime，不覆盖文档内容、窗口、
interaction session 或文件状态。事务期间 Buffer 的创建、移除和 Editor 关闭会被
拒绝，从而保证 snapshot 可以恢复到同一组 Buffer。

较窄的 `call-with-editor-setting-transaction` 只覆盖 setting store 和 Buffer-local
值，适合不修改扩展 catalog 的批量设置。

## Extension owner

Editor 保存有序的 extension owner：

```text
Extension {
  name,
  loader
}
```

首次加载 extension 时，Editor 捕获不含扩展贡献的 baseline。加载新 owner、替换同名
owner、卸载任意 owner 或显式 reload 时，Editor 恢复 baseline，并按 owner 顺序重新
执行全部 loader。同名替换保持原顺序，新名称追加到末尾。

整个重建运行在 configuration transaction 中。任一 loader 抛出 condition 时，当前
已提交的扩展集合和配置状态保持不变；只有全部 loader 成功后才发布新的 owner 列表。
卸载最后一个 owner 后 baseline 重新成为普通 Editor 配置，下一次首次加载会从当时
的配置创建新 baseline。

Loader 接收 Editor，并通过配置 API 注册其贡献。Loader 应具有可重复执行语义，且其
副作用必须落在 configuration snapshot 覆盖的 Editor 状态中。文件写入、进程启动和
其他外部副作用不属于扩展事务。

Baseline 建立后创建的 Buffer 不属于旧 snapshot 的局部状态。扩展重建保留这些 Buffer；
恢复 language catalog 时，仍存在的 major mode 会重新创建 runtime，已经移除的
extension mode 回退到 `fundamental-mode`。
