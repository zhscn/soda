# Resource Context、Project、Workbench 与 Window

## 实现状态

| 能力 | 状态 |
|---|---|
| Window tree、View 生命周期与基础 display 操作 | 已实现 |
| 显式 process working directory | 已实现 |
| 异步 file/display 请求的冻结 origin | 已实现 |
| 通用 `ResourceContext`、View origin 与文件选择上下文冻结 | 已实现 |
| Project identity、发现缓存与 known registry | 已实现 |
| Workbench Project focus 与命令解析 policy | 已实现 |
| ProjectTarget dispatch 值与 origin 冻结 | 已实现 |
| Project resource 流式枚举、snapshot 与 watch lifecycle | 已实现 |
| Project settings layer、task definition 与 comint runtime | 已实现 |
| Workbench lifecycle、scope、MRU、slot 与 pinned window | 已实现 |
| Workbench session 稳定资源持久化与恢复 | 已实现 |
| Workbench JumpGraph 与 location-list stack 持久化 | 已实现 |
| generated/tool Buffer 创建 provenance | 已实现 |
| intent 驱动的统一 display placement policy | 已实现 |
| LanguageSession registry、attachment 与 display provenance 路由 | 已实现 |
| LanguageProfile bootstrap hook 与 home attachment 选择 | 已实现 |
| TUI dashboard 与 Buffer registry 面板 | 部分实现 |

## 正交概念

- **Buffer** 是全局文本对象，可同时显示在多个 View。
- **ResourceContext** 是一次资源操作解析相对路径和工作目录的显式上下文。
- **Project** 是资源发现、配置、任务和构建入口的边界。
- **LanguageSession** 是某个语言服务实例及其语义环境。
- **Window layout** 是屏幕上的 View 排布，不属于某个 Project。
- **Workbench** 组合 Project scope、focused Project、layout 和一次工作会话的 recency。

Project、LanguageSession 和 Workbench 可以相互引用，但不拥有彼此。编辑器没有全局
`current-project`，进程启动目录也不定义当前 Project。

```text
launch directory ──> initial ResourceContext fallback

Buffer <──────────── shared text identity
  ▲
View ──> ResourceContext? ──> Project hint?
  │             │
  │             └──────────> explicit process/file request cwd
  └──> LanguageAttachment ──> LanguageSession

Workbench = Project scope + focused Project? + WindowLayout + MRU + placement slots
```

## ResourceContext

依赖目录的操作接收显式上下文：

```text
ResourceContext {
  base_directory,
  origin_view_id?,
  project_hint?,
  language_context?
}
```

`base_directory` 是相对资源解析和默认 working directory 的基础。context 按以下来源
建立：

1. 调用方显式提供的 resource 或 directory；
2. 发起 View 当前 Buffer 的 resource；
3. generated/tool Buffer 保存的创建 provenance；
4. Workbench scope 中唯一且适用的 Project；
5. editor 启动目录。

存在多个可用 Project 时，资源归属不从 Workbench focus 推断。workspace 命令可以使用
Workbench focus，resource 命令优先使用 Buffer 的 home Project。异步 file、directory、
process 和 language 请求在创建时冻结 context；
完成时不重新读取 active View，因此切换 Buffer、Window 或 Workbench 不会改变请求
落点和 working directory。

启动目录只用于第一个无资源 Buffer 的初始上下文和缺少其他 provenance 时的最终
fallback。Editor 不调用进程级 `chdir` 来切换 Project。`find-file` 从 origin context
选择初始目录；每个 process request 显式携带 working directory。

## Project

Project 是轻量、可缓存的 tooling 描述值：

```text
Project {
  id,
  roots,
  kind,
  discovery_provenance,
  resource_enumerator,
  settings_layer,
  task_definitions
}
```

发现器从给定 resource 向上查询 VCS marker、build manifest 或显式 marker。发现策略
是有序 registry，第一个有效结果建立 Project；成功和确定性的失败都按起始目录缓存。
远程或暂时不可访问的 resource 不缓存失败。显式 known-project registry 独立保存用户
选择过的 root，使 project switch 不依赖当前 Buffer 或启动目录。

project focus 是 Workbench 的命令路由状态。它不改变全局 cwd、WindowLayout、View 的
ResourceContext 或 Buffer 的 home Project。Project commands 可以从 active resource
发现 Project，也可以使用 Workbench focus 或直接从 known registry 选择。

Project 拥有：

- root/resource identity、枚举与忽略规则；
- Project settings layer；
- build、test、search 和其他 task definition；
- 启动 LanguageSession 时可使用的 workspace folder 和配置。

settings layer 是不可变的 symbol-to-value 映射，由使用该 Project 的 tooling 按显式
fallback 读取。task definition 使用稳定 symbol id，携带显示名、argv、相对或绝对
working directory 与可选 comint prompt。任务的相对 working directory 以 Project
primary root 解析，并通过 managed process/comint 执行。

`project.focus` 从 known-project registry 选择 Project 并更新 active Workbench 的
focus。`project.switch` 执行相同的 focus 更新，然后在目标 Project 中启动
`project.find-file`。`project.run-task` 选择 Project task 并在定义的 working directory
中启动 process interaction。这些命令都不修改进程 cwd 或 origin View 的 provenance。

Project 解析使用两种显式 policy：

```text
workspace: explicit -> Workbench focus -> View home -> unique scope
resource:  explicit -> View home -> Workbench focus -> unique scope
```

文件选择、搜索、构建和 shell 等 workspace 操作使用 `workspace`。other-file、test-file
以及面向当前资源的语义操作使用 `resource`。需要跨越异步边界的操作把解析结果冻结为：

```text
ProjectTarget {
  project,
  root,
  origin_workbench_id,
  origin_view_id,
  resource_context
}
```

ProjectTarget 为异步 project command 提供 dispatch 值；callback 可以从中读取目标与
origin，而不重新查询 active Workbench、active View 或 focus。只需要 Project identity
的内部请求可以直接携带不可变 Project 值。

Project 不拥有 Buffer、View、Window、Workbench、LanguageSession、Scheme semantic
index 或 process。一个 Buffer 可以通过路径发现 home Project，也可以只是 visitor；
同一 Project 可以出现在多个 Workbench scope 中。

## Dashboard projection

Dashboard 是 Workbench、Project 和 tooling 关系的显式 TUI projection，不是新的所有权
层。`dashboard.open` 打开一个普通 application Buffer；基础面板列出 Editor Buffer
registry，并允许选择、刷新和在 origin View 中访问 Buffer。dashboard session 可以像
其他 Buffer 一样放入 Window、切换、复用和参与 Workbench MRU。

Project dashboard 以 Project identity 为根节点，关联 Buffer、LanguageSession、Git、
诊断、搜索结果和 task。关联项保存其真实 identity 或冻结的 target，不依赖 active
View、启动目录或隐式 current Project。多个独立 Project 可以通过具名 relation 组成更
高层 workspace dashboard，例如前端、后端和部署 Project 以 `frontend`、`backend`、
`deployment` relation 归属于同一产品 workspace。relation 表达导航与展示关系，不把
子 Project 合并成新的 root，也不改变各自的 ResourceContext、settings 或 language
session 边界。

Dashboard Model 是 registry 与 session 状态的可见投影。刷新重新读取相应 registry，
选择和 viewport 属于 dashboard session/view state；访问条目仍调用普通 display、
project command 或 language command，因此 dashboard 不绕过既有路由 policy。

打开 file-backed Buffer 不创建 Project，不递归枚举目录，也不启动 language index。
显式 project command、adopt 或 language bootstrap 才解析 Project。Project 发现只产生
描述值，LanguageSession 是否启动由 language policy 决定。

resource enumerator 由 Project 操作按需启动，通过 libuv directory scan 逐层展开
目录。每个目录批次都发布同一 scan generation 的累计路径 snapshot；picker 立即用
已有候选响应输入，并在 snapshot 增长时按当前 query 重新过滤。候选更新按稳定
resource identity 保留 selection 和 viewport，不重启目录扫描。

枚举 session 属于 Editor 的 Project resource cache，不属于启动它的 minibuffer。
接受或取消 picker 只结束交互 session；枚举可以继续完成并服务下一次命令。重复命令
复用已有 snapshot 或在途 session，Project 切换后的批次只更新引用同一 Project id 的
picker。forget Project 和 Editor close 释放 scan source 与全部目录 watch。

需要内容的调用方通过异步 file read 单独读取资源。隐藏目录、VCS metadata、构建输出
和依赖目录由枚举 policy 排除。enumerator 不为后台索引创建 Buffer；用户访问资源时
才由普通文件打开流程建立 Buffer identity。目录 watch 只承担失效通知；文件系统变化
启动新 generation 的异步重扫，并以累计 snapshot 替换旧集合。

## Workbench

```text
Workbench {
  id,
  name,
  scope: ordered ProjectId set,
  focused_project: ProjectId?,
  layout: WindowLayout,
  active_window,
  mru: BufferId list,
  slots: intent -> WindowId,
  pinned_windows: WindowId set
}
```

编辑器始终有一个 active Workbench。只有一个 Workbench 时不要求额外操作或 UI。
Workbench 不提供自己的 cwd，也不把 scope 合成为单一 Project。

focused Project 必须属于 scope。adopt 第一个 Project 时它成为默认 focus；移除 focused
Project 时 focus 清空。focus 只影响 workspace 命令的默认目标，不参与 Buffer 归属、
LanguageAttachment 或 display placement。

某 Workbench 可见的 Buffer 集合是：

```text
buffers(project in scope) union buffers in workbench MRU
```

scope 是声明式搜索范围；MRU 是显示足迹。显示 scope 外的 Buffer 会把它作为 visitor
加入 MRU，但不会修改 Project、LanguageSession 或配置归属。显式 adopt Project 才会
扩大 scope。

切换 Workbench 会整体切换 layout、active Window 和 MRU。非 active Workbench 的
View 保留 caret、selection、viewport、InputState 和 LanguageAttachment。关闭
Workbench 释放其 Window/View，不关闭全局 Buffer、Project 或共享 LanguageSession。

## Display placement

所有“把 Buffer 显示出来”的操作经过同一个入口：

```text
display(buffer, intent, origin, target?, resource_context?) -> View
```

命令在调用点声明 intent，placement policy 不根据 Buffer 名称或窗口几何恢复意图：

| intent | 语义 | 默认 slot |
|---|---|---|
| `edit` | 用户主动编辑资源 | active Window |
| `jump` | definition、reference、location list 落点 | jump |
| `tools` | grep、build、terminal 等持久工具 | tools |
| `doc` | help 与文档 | doc |
| `pop` | 显式新窗格 | 新 slot |
| `explicit` | 调用方指定 Window | 指定 Window |

Window 可声明唯一 role，由此成为具名 slot；pinned Window 不被普通 placement 替换。
policy 返回完整 plan，layout mechanism 校验 Window 存活、role 唯一和 split 结构不变量。

display request 携带 origin View 和冻结的 ResourceContext。异步请求在其他 Workbench
active 时完成，结果仍写入 origin 所属 Workbench，不隐式切换用户当前工作台。origin
已销毁时才由显式 fallback policy 选择 active Workbench。

## 临时界面

持久工具使用 Window slot。completion、hover、which-key、picker 和 minibuffer 是
View 上的临时层：

- caret-relative popup 锚定到文档位置，不改变正文 viewport；
- minibuffer/picker 可占用保留的 TUI 行并参与 reflow；
- 临时层关闭后不留在 WindowLayout 或 Workbench MRU。

这一区分让 layout 只保存可恢复的工作状态。

## LanguageSession bootstrap

Project 可以为 LanguageSession 提供 workspace folders、server 配置和 toolchain 信息，
但 Project identity 不是 session identity。一个 Project 可以启动多个 session；支持
multi-root 的 session 也可以服务多个 Project。

```text
LanguageSessionKey {
  language,
  server_or_provider,
  workspace_folders,
  initialization_options,
  environment_fingerprint,
  client_capabilities
}
```

session 建立后，请求路由使用 [09-language-modes.md](09-language-modes.md) 定义的
LanguageAttachment，而不是每次从目标文件路径重新发现 Project。Project 只参与
bootstrap、配置和 task discovery。SchemeEnvironment 不从 Project root 推导，详见
[11-scheme-semantics.md](11-scheme-semantics.md)。

## 持久化

Workbench session 使用稳定 resource 与结构值序列化：

- name、scope roots、focused Project root 与 MRU resources；
- WindowLayout、role、pinned 与 active leaf；
- 每个 View 的 resource、selection fallback、viewport 与可恢复 context hint；
- 有界 jump walk 和 durable jump graph。

运行时 id、native pointer、LanguageSession、pending popup 和在途异步请求不进入持久
格式。恢复时重新发现 Project，并按 language policy 建立所需 session。

## 设计依据

Emacs Buffer 的 `default-directory` 和 Projectile 的 root finder 表明资源归属应从
当前 Buffer provenance 发现，known-project registry 与启动 cwd 保持独立。Soda 使用
Workbench focus 表达 workspace 命令目标，使用显式 ResourceContext 和 ProjectTarget
保证异步请求不受 active Buffer 或 focus 变化影响。

Emacs `display-buffer` 说明显示需要 policy，但在显示时按 Buffer 名和窗口几何恢复
调用意图会产生不可预测的 fallback。Kakoune 的具名 tools/jump client 表明意图可以
直接映射到位置。Workbench 显式组合 scope 与 layout，同时保留 Buffer 全局共享，
避免把 IDE 的单 Project 窗口所有权强加给编辑会话。
