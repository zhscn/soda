# C++ 语言内核

## 实现状态

| 能力 | 状态 |
|---|---|
| lossless lexer 与容错 CST | 已实现 |
| revision-scoped analysis session 与增量更新 | 已实现 |
| 结构查询、缩进决策和原子编辑机制 | 已实现 |
| C ABI 与独立生命周期 | 已实现 |

## 定位

C++ 语言内核从 `Text` 或 `DocumentSnapshot` 派生 lossless token、容错 CST、
结构查询与缩进结果。它不拥有 editor buffer、view、major mode 或终端状态。
编辑器通过 [09-language-modes.md](09-language-modes.md) 的 syntax provider
将这些能力接入某个 buffer。

## 分层

```text
DocumentSnapshot + normalized changes
              │
              ▼
       lossless token buffer
              │
              ▼
       tolerant green tree
              │
       ┌──────┴──────┐
       ▼             ▼
 structural query  indentation
```

每一层只消费下一层的不可变值。增量缓存由 analysis session 持有，文档正文仍由
`Document` 唯一拥有。

## Lossless lexer

token 流覆盖输入的每一个 UTF-8 byte。空白、换行、注释、预处理行、raw string
和无法识别的字节都保留在 token 中，因此任意 token 区间都能恢复原文。

`TokenBuffer` 按文本位置和 token 序号提供查询。应用 change set 时，从受影响
token 前的安全词法状态重新扫描，并在 token 内容与词法状态同时收敛后复用后缀。
预处理分支不要求先完成宏展开；条件分支与 directive 作为可导航的表面结构保留。

## 容错 CST

CST 使用不可变 green node。节点存 kind、子项和总 byte 长度；offset 由遍历路径
累加得到，因此复用子树不需要批量改写绝对坐标。token 和 trivia 均是树的叶子。

parser 在不完整输入上始终产生树：

- 缺失的闭合符号用零长度 missing 节点表示；
- 意外 token 被包装为 error 节点并继续同步；
- template、宏与声明歧义优先保留边界，不要求编辑路径上完成类型语义判定；
- brace、paren、bracket、statement、declaration 和 preprocessor group 保持
  可查询，即使其内部存在错误。

增量 reparse 选择能覆盖 change 的最小稳定祖先，重新解析对应 token slice，并在
边界不再匹配时逐级扩大。正确性不依赖增量路径；session 可以从同一 snapshot
完整重建。

## Analysis session

一个 analysis session 绑定一个 document identity 和 revision：

```text
open(snapshot) -> session@revision
apply(snapshot, normalized changes) -> session@new-revision
query(session, revision, range) -> result
```

调用方必须按 revision 顺序推进 session。revision 不匹配、change 不连续或缓存
校验失败时，provider 用目标 snapshot 重建 session。语法节点句柄仅在产生它的
session revision 内有效；跨 revision 持久位置使用 `DocumentAnchor`。

结构查询至少包括：

- offset 处最内层节点和祖先链；
- 覆盖 range 的语法节点；
- matching delimiter；
- token kind、范围和 trivia；
- S-expression 形式的调试投影。

查询返回值不暴露 green tree 内存布局。

## 缩进模型

缩进是对 snapshot、analysis revision、行位置和 style 的纯查询：

```text
indent(snapshot, syntax, line, style) -> IndentDecision
```

`IndentDecision` 包含目标列、主要规则和可选 trace。规则组合以下信息：

- 显式 block 的父层级；
- 未闭合 delimiter 的 continuation；
- statement、declaration 与 access label；
- `case`、label、preprocessor directive；
- comment 与 string 的局部约束；
- 当前行的 closing token 或 electric character。

style 是显式值，包含 tab width、indent width、continuation width、tab
物化策略以及 C++ 结构选项。配置发现属于 project/language policy，缩进内核不读
文件系统或全局设置。

编辑命令把缩进决策转成单个 `DocumentTransaction`。命令返回最终 caret 和
normalized change set，使 command loop 可以同步 syntax session 并刷新 view。

## ABI

`soda_cpp_analysis` 和 `soda_indentation` 使用 opaque handle：

- 创建与销毁必须成对；
- buffer、snapshot、session 和结果的所有权由函数签名区分；
- 字符串与范围使用 UTF-8 byte 坐标；
- 错误通过显式状态和可复制消息返回，不跨 C ABI 抛异常；
- 所有 handle 由创建它们的 editor thread 使用。

## 设计依据

lossless CST 适合编辑器的原因是：格式、注释和错误输入都是用户正在编辑的真实
状态，不能在 AST 边界被丢弃。green tree 使共享与增量替换成为值操作；revision
绑定则把缓存正确性从隐式时序变成可验证契约。C++ 专用分析保留语言深度，同时由
provider 边界限制其影响范围，其他语言可以使用 delimiter 或 Tree-sitter provider。
