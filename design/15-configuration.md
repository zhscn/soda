# 配置状态与原子更新

## 实现状态

| 能力 | 状态 |
|---|---|
| typed setting、作用域与 catalog | 已实现 |
| configuration snapshot 与原子 transaction | 已实现 |
| extension owner、撤销与热替换 | 已实现 |
| 用户 init、生命周期 hook 与错误隔离 | 已实现 |

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
- language profiles、major modes 与 auto-mode rules；
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
配置副作用应落在 configuration snapshot 覆盖的 Editor 状态中。

Loader 可以在取得 watcher、timer、进程或 language session 等外部资源后立即调用
`editor-register-extension-cleanup!` 登记无参数 cleanup。登记只在当前 loader 的
动态 scope 内有效。一个 owner 内按登记的逆序运行 cleanup，多个 owner 按加载的逆序
释放，保证依赖资源先于被依赖资源关闭。

Reload、同名替换、unload 和 Editor close 都会释放 owner resources。新 loader 失败
时，已成功的新 owner 和失败 loader 已登记的部分资源都会释放；原 configuration
snapshot 恢复后，拥有 cleanup 的旧 owner 重新执行 loader 以取得新资源句柄。资源
恢复期间产生的配置写入会被丢弃，因此旧 evaluator、catalog 对象和 setting 值保持
失败前的精确身份。

Cleanup 应可重复调用并在有限时间内返回。Cleanup condition 不阻止后续 cleanup，
Editor 通过 `extension-cleanup-failed` hook 报告 condition。文件写入和其他不可逆
操作不属于 cleanup scope，loader 仍应避免执行这类操作。

Baseline 建立后创建的 Buffer 不属于旧 snapshot 的局部状态。扩展重建保留这些 Buffer；
恢复 language catalog 时，仍存在的 major mode 会重新创建 runtime，已经移除的
extension mode 回退到 `fundamental-mode`。

## User init 与 Scheme 环境

启动时按以下顺序查找 init：

```text
SODA_INIT_FILE
→ $XDG_CONFIG_HOME/soda/init.ss
→ $HOME/.config/soda/init.ss
```

`SODA_INIT_FILE` 设为空字符串时禁用自动加载。不存在默认文件时直接进入 Editor。

User init 作为 `user-init` extension owner 加载。文件在一个新的 Chez evaluator 中
完整求值，环境预先提供 `*editor*`；配置文件可以导入 `(soda editor core)` 并调用
Editor API。只有求值和扩展重建全部成功后，新 evaluator 才成为 Editor 环境。失败时
保留原 init 贡献和原 evaluator。

Editor 内的 Scheme REPL 使用同一个 evaluator。成功 reload 后，已有 REPL session
切换到新环境；失败 reload 继续使用旧环境。`configuration.reload-init` 从 M-x
重新执行当前 user-init loader；尚未加载 init 时重新执行默认路径发现。

## Lifecycle hooks

Editor hook registry 按 phase 保存有序的命名过程。同 phase、同名称的注册替换旧过程；
remove 按名称删除。Hook registry 属于 configuration snapshot，因此 owner reload 和
unload 同时恢复其 hooks。

Hook 可以注册为 Editor-global，也可以绑定到一个 Buffer。Buffer lifecycle 执行时先按
注册顺序运行 global hooks，再运行该 Buffer 的 local hooks。Buffer-local hook 随
configuration snapshot 恢复，并在 Buffer 从 Editor 移除时清理。

核心 phase 为：

```text
after-init(editor)
theme-changed(editor, old-theme, new-theme)
configuration-committed(editor)
configuration-rolled-back(editor, condition)
extension-cleanup-failed(editor, extension-name, condition)
buffer-created(editor, buffer)
before-buffer-removed(editor, buffer)
major-mode-changed(editor, buffer, old-mode, new-mode)
find-file(editor, buffer, path, new-file?)
before-save(editor, buffer, path, adopt-path?)
after-save(editor, buffer, path, saved-revision)
before-revert(editor, buffer, path, force?)
after-revert(editor, buffer, path)
```

`after-init` 在 user init 和启动文件 mode 选择完成后运行。它自身位于 configuration
transaction 中，hook condition 会恢复 hook 产生的配置修改并显示启动状态。

外层 configuration transaction 正常提交后运行 `configuration-committed`。Commit
hook 的 condition 仍会回滚该事务；恢复完成后运行 `configuration-rolled-back`。
Rollback hook 用于记录和诊断，hook condition 不替换原 condition。

Theme setter 在 configuration transaction 中运行 `theme-changed`，因此 hook 可以
原子更新配套 face 或 setting；hook 失败时 theme 和其他配置修改一起恢复。

`before-save` 和 `before-revert` 是同步 barrier。Hook condition 会在 save snapshot
或异步 reload request 建立之前取消操作。Hook 在 barrier 中对 Document 所做的编辑
仍是普通 Document change。

`buffer-created`、`before-buffer-removed`、`major-mode-changed`、`find-file`、
`after-save` 和 `after-revert` 是 notification。它们不承担 kill query 或事务 veto；
Editor 保留已提交状态、报告 hook condition，并继续 command loop。文件写入和 reload
完成后同样无法通过 hook condition 回滚。
`find-file` 在文件 metadata、line ending、observed state、resource identity 和 View
激活完成后运行。`after-save` 观察实际写入的 snapshot revision，即使 Buffer 同时已有
更新的 revision。

## 热替换契约

注册同名对象表示替换现有定义。需要刷新派生运行时的注册 API 自身使用 configuration
transaction：

- language profile 与 major mode 替换会刷新全部 Buffer；任一 runtime 无法建立时，
  catalog 和所有 Buffer runtime 恢复到替换前的版本；
- 当前 theme 被同名 theme 替换时，新对象立即成为当前 theme，并运行
  `theme-changed`；
- 活动 minor mode 被同名 definition 替换时，旧 definition 的 disable lifecycle
  先运行，新 definition 注册后再运行 enable lifecycle。失败会恢复旧 definition、
  command、活动状态和 lifecycle；
- completion request 在进入 effect queue 时绑定 provider 实例。替换同名 provider
  只影响之后创建的 request，已排队的 request 与 cancel 始终发送给原实例。

扩展 loader 位于外层 configuration transaction 中，因此这些 API 的内层事务合并为
一次提交。直接从 REPL 调用同样具有原子替换语义。
