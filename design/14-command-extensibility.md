# Command 与扩展机制

Soda 把普通 Scheme 过程、可交互参数读取和编辑器命令调用分开。命令定义保留普通
过程，使库代码可以直接传入参数；command registry 持有交互元数据、文档、command
class、适用 mode 和 advice。

## Command definition

`define-command` 定义普通过程，并把 `CommandDefinition` 关联到该过程：

```scheme
(define-command (goto-line context line)
  "Move point to LINE."
  (interactive
    (interactive-number "Goto line: " 'goto-line))
  ...)
```

注册时必须显式构造并提交 definition。`make-interactive-context-command` 保留
`define-command` 关联的参数计划，同时允许注册名、文档和 command class 由安装点指定：

```scheme
(editor-register-command!
  editor
  (make-interactive-context-command
    'goto-line
    goto-line
    "Move point to LINE."))
```

普通 Scheme 调用直接执行 `(goto-line context 42)`，不读取交互参数。keymap、M-x 和
`editor-execute-interactive-command!` 使用 definition 的 `InteractivePlan`。
`editor-register-internal-command!` 注册 responder 和 runtime continuation；internal
command 使用 `make-internal-context-command` 构造，不属于 M-x 的候选集合。仅接收
`CommandContext` 的无参数命令也通过这两个构造器显式声明是否可交互。需要普通 Scheme
参数的命令使用 `define-command`，使过程调用和交互调用具有同一个参数契约。

## Interactive plan

Interactive plan 是有序的 `InteractiveReader` 列表。reader 接收最初的
`CommandContext`，并返回以下结果之一：

```text
InteractiveReady(values)
InteractiveSuspend(prompt-request, decoder)
```

ready values 直接追加到过程参数。suspend 保存当前 invocation 并打开 minibuffer；
prompt reply 通过 decoder 产生参数，然后恢复同一个 invocation。参数解析期间不进入
递归 command loop。

内置 reader 包括：

```scheme
interactive-prefix-count
interactive-prefix-raw
interactive-event
interactive-message-argument
interactive-point
interactive-region
(interactive-string prompt history-id default)
(interactive-number prompt history-id default)
(interactive-completing-read
  prompt source accept-policy history-id initial default result-decoder)
(interactive-file-name prompt initial)
```

`interactive-completing-read` 接受 `ChoiceSource`，或接收 `CommandContext` 并返回
`ChoiceSource` 的过程。后者用于构造依赖当前 editor、buffer 或 mode 的候选集合。
`accept-policy` 为 `free` 或 `must-match`。result decoder 接收原始
`CommandContext` 和已接受的 `PromptResult`，返回追加到命令参数中的列表；省略
decoder 时传入 `prompt-result-value`。因此 decoder 可以读取调用上下文和 candidate
payload，并为一个 reader 产生一个或多个类型化参数。

`make-interactive-reader` 是自定义 reader 的扩展点。同步 reader 返回
`make-interactive-ready`；需要 minibuffer 的 reader 返回
`make-interactive-suspend`。prompt 的 accept 和 abort responder 分别使用
`command.resume-interactive` 与 `command.abort-interactive`。

## 交互参数与命令目标

`CommandContext` 保存原始 prefix argument、event、message argument、Editor 和
View。`command-context-count` 把缺省 prefix 解释为 1；需要区分无 prefix、`C-u`、
显式数字和负参数的命令读取 `command-context-prefix`，或在 interactive plan 中使用
`interactive-prefix-raw`。`PrefixArgument` 保留 kind、sign 和 magnitude，因此命令
可以让同一个过程根据参数种类选择语义，而不把按键序列编码进命令体。

涉及文本范围的命令使用 `CommandTarget` 作为类型化参数：

```text
CommandTarget {
  source,
  buffer_id,
  document_id,
  revision,
  start,
  end,
  point,
  mark,
  direction,
  properties
}
```

`CommandTargetSelector` 声明 active region 的 policy 为 `prefer`、`require` 或
`ignore`，并提供没有 region 时的 mode-aware fallback。fallback 可以根据 raw
prefix、当前位置和 major-mode feature 选择 line、sexp、defun 或 buffer。
`make-command-target-reader` 在 interactive argument resolution 阶段冻结 target；
执行写操作前用 `command-target-current?` 验证 Buffer 与 revision，防止
minibuffer suspension 或异步状态变化后把范围应用到错误文本。

这种分层使 Scheme 过程接收已解析参数，而不是重复解释 editor 状态。例如结构缩进
命令的普通调用接收一个明确 target；交互调用优先使用 region，无 region 时选择下一
个 sexp，带 raw prefix 时选择包含 point 或紧随 point 的 defun。major mode 可以通过
具名 feature（例如 `forward-sexp-function`）替换结构动作，而命令和 key binding
保持不变。

连续调用语义读取 Editor 的 `last-command` 与 command class。`mark.sexp` 在首次调用
时建立 mark，连续调用时沿原方向扩展；minibuffer 内为外层 invocation 读取参数的
命令不覆盖这个 identity。

## Invocation 与 command loop

每次交互调用创建一个 `CommandInvocation`：

```text
CommandInvocation {
  id,
  definition,
  original context,
  remaining readers,
  collected arguments,
  suspension,
  state
}
```

状态依次为 `resolving`、`suspended`、`running` 和 `finished`；取消或 condition
进入 `aborted`。Editor 同时最多保存一个等待 minibuffer 的 invocation。minibuffer
导航和文本编辑命令可以正常运行，但另一个需要 suspend 的 command 不能覆盖当前
invocation。参数读取期间的 minibuffer 命令不改变外层 command identity，不进入
command history，也不触发外层 pre/post command hooks。

argument resolution 完成后，command loop：

1. 设置 `current-command`；
2. 运行 `pre-command` hooks；
3. 通过 advice chain 调用 command；
4. 运行 `post-command` hooks；
5. 更新 `last-command`、command class 和 command history。

history entry 是 `(command-name . arguments)`。interactive reader 应产生可写入和重新
读取的 Scheme 值；resource、位置等运行时对象应转换为稳定值。

## Hooks

Command registry 保存命名的 `pre-command` 和 `post-command` hooks：

```scheme
(add-command-hook!
  registry
  'pre-command
  'extension-name
  procedure)
```

同名 hook 的新注册替换旧注册，并位于有序列表末尾。`remove-command-hook!` 按名称移除。
pre hook 接收：

```scheme
(context definition arguments)
```

post hook 接收：

```scheme
(context definition arguments effects condition)
```

正常返回时 `condition` 为 `#f`；command 抛出 condition 时 `effects` 为 `#f`。
Hook 属于交互调用边界，普通 `editor-execute-command!` 不运行 command-loop hooks。

## Advice

Advice 附着在某个 editor registry 的具名 command 上，不修改原 Scheme 过程。
支持以下 placement：

```text
before
after
around
filter-args
filter-return
```

每个 advice 具有稳定名称和整数 depth。较小 depth 位于外层；同名注册替换旧 advice。
重新注册同名 command 会替换 definition 并保留已有 advice。advice 默认继承 command
的 interactive plan，因此处理的是已经解析完成的普通参数。

过程签名为：

```scheme
before:        (context arguments)
after:         (context arguments effects)
around:        (next context arguments) -> effects
filter-args:   (context arguments) -> arguments
filter-return: (context arguments effects) -> effects
```

command effect 列表在原 command、around 和 filter-return 边界统一验证。

## Minor mode

`MinorModeDefinition` 描述 buffer-local 或 global mode：

```text
name
documentation
scope
lighter
keymap layer
enable procedure
disable procedure
```

定义形式为：

```scheme
(define-minor-mode auto-fill-mode
  "Fill text while editing."
  (scope buffer)
  (lighter "Auto Fill")
  (keymap 'auto-fill-mode-map)
  (enable enable-auto-fill!)
  (disable disable-auto-fill!))
```

`editor-register-minor-mode!` 把 definition 加入 catalog，并注册同名 toggle command。
无 prefix 时 toggle；正 prefix 启用；零或负 prefix 禁用。enable/disable procedure
之后运行相应的命名 mode hooks。

active buffer mode 保存在 Buffer local `minor-modes`；global mode 保存在 Editor。
effective keymap 把 active minor-mode layers 放在 major-mode keymap 之前。modeline 从
同一个 catalog 读取 lighter；`modeline-prominent-minor-modes` 直接显示指定 mode，
其余 active mode 由 Minions 风格的 `≡` 折叠标记表示。
