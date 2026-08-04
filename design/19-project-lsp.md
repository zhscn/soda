# Project、Resource 与 LSP Workspace

## 总体状态

未实现。

## 目标

Project 为语言工具、任务和资源枚举提供稳定边界。它不定义全局工作目录，不拥有
Buffer、View 或 Window，也不以当前焦点作为资源归属的唯一依据。

LSP session 以不可变 workspace 描述启动和路由。不同 Project 可以使用相同 server
definition，但不会共享协议状态、诊断集合或 request identity。

```text
Buffer resource binding ──> ResourceContext ──> Project resolution
                                                    │
                                                    ▼
                                           ProjectWorkspace snapshot
                                                    │
                                                    ▼
                                      LanguageSession / LSP transport
```

## Resource binding

file package 为 file-backed Buffer 注册不可变资源绑定：

```text
ResourceBinding {
  resource: canonical path or URI,
  base_directory,
  version,
  provenance
}
```

binding 是 Buffer extension state，不是 Buffer host object 的字段。保存、重载、rename
和外部文件变化通过 transaction effect 更新 binding。generated Buffer、result Buffer 和
REPL Buffer 可以没有 resource，或持有显式 provenance。

`ResourceContext` 是一次操作冻结的输入：

```text
ResourceContext {
  base_directory,
  resource?,
  origin_view_id?,
  project_hint?
}
```

find-file、process、search、LSP request 和异步 VFS 请求在创建时解析并携带该值。回调不得
重新读取 active View、启动目录或 focus Project。

## Project catalog

Project package 维护可变 catalog；其中的 descriptor 是不可变值：

```text
Project {
  id,
  roots,
  kind,
  settings,
  discovery_provenance
}
```

catalog 提供有序 finder registry、known-project registry 和 descriptor revision。finder 从
给定 resource 的祖先目录发现 root；显式 marker 的优先级高于 build 与 VCS marker。每个
Project id 的 descriptor 更新递增 revision，而旧 descriptor 仍可被已启动请求安全引用。

catalog 只管理 Project identity。Workbench 可保存 focus Project 作为 workspace 命令的
选择状态；它不修改 process cwd、View placement 或 Buffer resource binding。

## Workspace resolution

语言服务和其他 workspace 工具只接收 `ProjectWorkspace`：

```text
ProjectWorkspace {
  project_id,
  revision,
  folders: [{name, resource}],
  settings
}
```

它是 Project descriptor 的深拷贝投影。`project_id + revision` 是 LSP session、资源索引和
异步结果去重的稳定键。

资源解析按以下顺序进行：

1. 请求提供的 Project hint，且其 root 覆盖 resource；
2. resource binding 的 home Project；
3. catalog discovery；
4. 所有 known Project 中覆盖 resource 的最长 root；
5. workspace command 的显式或 Workbench focus Project。

多 root Project 将全部 roots 转换为 workspace folders。一个 resource 可匹配多个
workspace；LSP request 选择覆盖路径最长的 workspace，并把选择结果冻结在 request 中。

## LSP integration

LSP package 声明 server definition：

```text
ServerDefinition {
  name,
  command,
  language_selector,
  initialization_options,
  workspace_configuration
}
```

启动命令显式接收 `ProjectWorkspace` 与 ServerDefinition，创建 session key：

```text
(server-definition-name, project-id, revision)
```

session 维护 transport、pending request、open document versions、diagnostics 和 capability
snapshot。Buffer 通过 resource binding 关联 session；同一 workspace 的多个 Buffer 复用
同一个 session。跳转到 workspace 外文件时，客户端先对目标 resource 重新解析 workspace，
再路由到对应 session，不假定源 Project 仍适用。

diagnostics、completion、xref 和 workspace edit 都通过冻结的 session key、Buffer identity
和 Buffer generation 校验。失配结果被丢弃，不影响当前 View 或其他 Project。

## 命令路由

命令分为两类：

- resource command：优先使用 origin View 的 ResourceContext；
- workspace command：接受显式 Project，缺省时使用 Workbench focus。

交互式选择只产生 Project id 或 resource；command runtime 在 invocation 开始时将其解析为
冻结的 ProjectWorkspace。minibuffer、dashboard 和 LSP callback 不保存可变的 active-project
引用。

## 生命周期

Project catalog、LSP session registry 和 process transport 都由各自 package owner 持有。关闭
owner 时先停止新的 request，再关闭 transport 和 watcher，最后解除 command/effect
registration。Buffer、View 和 Workbench 的关闭只解除各自 binding；不会隐式销毁仍被其他
Buffer 使用的 workspace session。
