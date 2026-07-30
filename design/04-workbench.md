# Workbench、Project 与 Window

## 三个正交概念

- **Buffer** 是全局文本对象，可同时显示在多个 view。
- **Project** 是资源发现、配置和构建入口的边界。
- **Window layout** 是屏幕上的 view 排布，不属于某个 project。

Workbench 把 project scope、window layout 和一次工作会话的 recency 组合起来，
但不改变三者各自的身份：

```text
Workbench {
  id,
  name,
  scope: ordered ProjectId set,
  layout: WindowLayout,
  active_window,
  mru: BufferId list,
  slots: intent -> WindowId
}
```

编辑器始终有一个 active workbench。只有一个 workbench 时，工作台机制不要求额外
操作或 UI。

## Project

Project 由 resource root 和 project kind 标识。发现器可以使用 VCS root、
build manifest 或用户配置；一个 buffer 可以有 home project，也可以只是 visitor。

Project 拥有：

- resource 枚举与忽略规则；
- project settings layer；
- build 与 language session 可使用的 root 和配置。

Project 不拥有 Buffer、Window 或 layout。同一 project 可以出现在多个 workbench
scope 中；是否保持 scope 互斥由 Scheme policy 决定。

打开 file-backed Buffer 不创建 Project，也不启动 resource discovery 或 language
index。显式 load/adopt project 根据 manifest、VCS root 或用户给定 root 建立
Project；visitor Buffer 可以始终不属于任何 Project。

Language session 是独立于 Project 的显式运行对象。Scheme session 从 project
manifest 加载构建生成的 interface index，并按 artifact owner 标识其生命周期；
Project 的存在、root 识别和 resource 枚举本身不会创建 language session。一个
language session 可以使用 Project 提供的 root 与设置，也可以只服务于 visitor
Buffer。关闭 session 会撤销其 interface surface 和运行时资源。

resource enumerator 由 Project 操作按需启动，通过 libuv directory scan 逐层展开
目录，并通过异步 file read 产生请求方需要的 resource snapshot。隐藏目录、VCS
metadata、构建输出和依赖目录由枚举 policy 排除。
enumerator 只发布 resource 与内容，不为后台索引创建 Buffer；用户访问资源时才由
普通文件打开流程建立 Buffer identity。每个已发现目录持有一个 libuv path watch；
变更通知使对应目录失效并触发合并后的异步重扫。重扫更新 resource 集合、递归接入
新增子目录，并撤销已删除目录子树的 watch。文件通知只承担失效职责，目录扫描结果
定义该 enumerator session 当前的 resource 集合。关闭请求该 enumerator 的 Project
operation 会释放全部 watch。

## Workbench 成员语义

某 workbench 可见的 buffer 集合是：

```text
buffers(project in scope) union buffers in workbench MRU
```

scope 是声明式成员；MRU 是显示足迹。显示 scope 外的 buffer 会把它加入 MRU，
但不会修改 project 归属。显式 adopt project 才会扩大 scope。

切换 workbench 会整体切换 layout、active window 和 MRU。非 active workbench 的
View 保留 caret、selection、viewport 与 input state。关闭 workbench 释放其
Window/View，不关闭全局 Buffer。

## Display placement

所有“把 buffer 显示出来”的操作经过同一个入口：

```text
display(buffer, intent, origin, target?) -> Window
```

命令在调用点声明 intent，placement policy 不根据 buffer 名称或窗口几何猜测：

| intent | 语义 | 默认 slot |
|---|---|---|
| `edit` | 用户主动编辑资源 | active window |
| `jump` | definition、reference、location list 落点 | jump |
| `tools` | grep、build、terminal 等持久工具 | tools |
| `doc` | help 与文档 | doc |
| `pop` | 显式新窗格 | 新 slot |
| `explicit` | 调用方指定 window | 指定 window |

Window 可声明唯一 role，由此成为具名 slot；pinned window 不被普通 placement
替换。policy 返回完整 plan，layout mechanism 校验 window 存活、role 唯一和
split 结构不变量。

display request 携带 origin。异步请求在其他 workbench active 时完成，结果仍写入
origin 所属 workbench，不隐式切换用户当前工作台。origin 已销毁时才使用 active
workbench。

## 临时界面

持久工具使用 Window slot。completion、hover、which-key、picker 和 minibuffer
是 view 上的临时层：

- caret-relative popup 锚定到文档位置，不改变正文 viewport；
- minibuffer/picker 可占用保留的 TUI 行并参与 reflow；
- 临时层关闭后不留在 WindowLayout 或 workbench MRU。

这一区分让 layout 只保存可恢复的工作状态。

## Language session provenance

language session 的键至少包含 project/root、language、server/provider 配置。
session 可跨 workbench 共享。Project membership 只提供可选 root 和配置，不自动
创建 language session；`load-project`、build/compile workflow 或显式 language
命令负责启动 session。关闭最后一个引用者会停止其后台任务。

导航到不属于任何 home project 的资源时，display request 的 origin session
成为该 buffer 的 guest provenance。后续 definition、completion 和 hover 可以
沿 guest binding 继续使用来源 session。若 buffer 获得 home session，home
优先；同一 resource 在不同 view/context 下可以有不同 guest provenance。

## 持久化

workbench session 使用稳定 resource 与结构值序列化：

- name、scope roots 与 MRU resources；
- WindowLayout、role、pinned 与 active leaf；
- 每个 View 的 resource、selection fallback 与 viewport；
- 有界 jump walk 和 durable jump graph。

运行时 id、native pointer、pending popup 和在途异步请求不进入持久格式。

## 设计依据

Emacs `display-buffer` 说明显示需要 policy，但在显示时按 buffer 名与窗口几何恢复
调用意图会产生不可预测的 fallback。Kakoune 的具名 tools/jump client 表明意图
可以直接映射到位置。Emacs project.el 与 Helix workspace 则说明 project 适合
保持为轻量 tooling root。Workbench 显式组合 scope 与 layout，同时保留 buffer
全局共享，避免把 IDE 的单 project 窗口所有权强加给编辑会话。
