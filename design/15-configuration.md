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
