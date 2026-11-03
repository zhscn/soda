# 编辑内核与接口

core 用不可变快照和原子事务表达编辑；语言会话只给出建议，editor 把输入和建议组合成事务提交。

## 状态与事务

`EditorState` 持有 `Snapshot` 和一个带方向的 `Selection`（anchor、head）。位置是 UTF-8 字节偏移，修改范围和选区必须落在字符边界；各种坐标单位见[坐标契约](coordinates.md)。`Snapshot` 保留 LF/CRLF 和原有 tab/space 字节。

`Transaction` 的全部修改指向同一基准版本。显式结果选区使用修改后坐标，未提供时由 `ChangeMap` 映射原选区。`EditorState::apply` 统一校验版本、范围、UTF-8 边界、重叠和结果选区，失败时保留原状态。相邻修改允许；起点相同的两个修改按重叠拒绝，同一位置的多次插入由发起者先合并。

`ChangeMap` 按 Before/After 关联决定插入点和被替换范围内部的位置落到哪一侧；`map_tracked` 对替换范围内部的位置返回 `None`。映射只更新位置，不证明语义结果仍然有效。

`compose_changes` 把两轮顺序修改组合回基准坐标，保留存活的原始文本区间，结果可以包含多个修改，因此行首缩进与行尾输入之间未变的代码仍能正确映射。`ValidatedChanges` 只排序、校验并建立映射，不编辑文本；输入协调直接在临时快照上组合已校验的修改。

`core::StandaloneEditor`（`dispatch`、`undo`、`redo`）是单会话适配入口，与 `editor::Document` 共用 `History<Owner>`。

## 历史

`History<Owner>` 是唯一的历史算法：记录精确的正向与逆向修改、所属 owner 和操作前后选区，实现组内组合、undo/redo 分支和分组压缩。文档以 `SessionId` 为 owner。

- 一个事务是一个撤销单位。owner、`history_group` 和 `user_event` 都相同的连续文本事务合并为一项。
- 选区命令、实际的语言切换、会话关闭、历史恢复、保存和重新加载结束当前分组；新文本事务清空 redo 分支。
- `squash(depth)` 把该深度之后的全部条目合成一项（`Command::SquashHistory`）。
- 撤销与重做恢复所属会话的选区，其他会话按变更映射；所属会话已关闭时全部按映射。
- 恢复在校验成功后才移动条目。净效果为空的恢复仍递增修订，过期事务不会因文本复原而重新生效。

按输入时间与事件类别合并的策略在 editor 的 `InputHistory`，见[编辑命令与无 UI 工作流](commands.md)；core 只接收分组与事件类别。

## 文档、会话与命令循环

| 类型 | 拥有 |
| --- | --- |
| `editor::Document` | 共享快照与文本修订、历史、语言会话、`config_generation`、Enter 使用的换行符（加载时取第一个行结束符，没有则 LF）、自动配对开关 |
| `EditorSession` | 独立选区、期望列、搜索状态；快照与文档共享 rope 和全文缓存 |
| `EditorModel` | 一个文档、默认会话和额外会话 |
| `editor::Editor` | 命令执行、输入历史策略与原子提交 |

文件绑定和配置来源由工作区的 `FileState` 维护，见[文件服务与文档生命周期](files.md)。

`DocumentId`、`SessionId` 在进程内不复用。默认会话随模型存在；`add_session`、`close_session` 管理额外会话，关闭后原标识不能再执行命令，历史保留。

`execute` 作用于默认会话，`execute_for` 指定会话，`execute_at` 另外接收事件时间；`run` 顺序执行命令流，每条之后调用观察者。失败的命令返回错误，文本、选区和历史不变，`run` 继续执行后续命令。控制器同步执行，不做文件 I/O，也不等待后台任务。`indentation`、`enclosing`、`item`、`in_literal` 是对语言会话的只读查询。

### 修订与更新

文本修订即快照版本，只由文本事务和历史恢复递增；事务的基准版本只校验它。选区命令只修改目标会话；语言配置实际变化时递增 `config_generation`。

`EditorUpdate` 给出文档、目标会话、文本修订和配置代次，列出选区发生变化的会话，文本变化时携带 `DocumentUpdate`：来源（`EditOrigin`）、前后修订、实际修改和位置映射。普通编辑与撤销、重做使用同一种记录；没有可恢复条目的 Undo/Redo 不发布文档更新。

提交后所有会话读取新快照：发起会话采用显式或映射后的选区，其他会话按精确变更映射，所有会话的期望列失效。

## 语言会话

`Language` 有 `PlainText`、`TextMate(Profile)` 和 `Cpp(CppRules)` 三种。文档的语言会话决定结构、字面量与缩进的来源：

| 会话 | 来源 |
| --- | --- |
| PlainText | 只有括号配对，没有字面量 |
| TextMate | TextMate 结果给出字面量与注释，括号配对 |
| TextMate（Rust） | 附加的 `rust::RustSession` 提供字面量、结构分组、Enter 建议和输入触发的缩进 |
| Cpp | `CppSession` 的语法树 |

没有 parser 的语言按括号缩进：以开括号结尾的行之后加一级，Enter 落在一对括号之间时展开。

`language` 定义公共建议类型。`IndentAdvice::Set` 给出实际的 tab/space 前缀和可选的局部空白修改；`Preserve` 指定保留或继承换行缩进；`Unavailable` 使用基础策略。`EnterAdvice` 给出是否展开括号、是否原样换行以及注释续写前缀。editor 校验建议的行、字符边界和空白内容后再组合修改。

`TypeChar` 和 `Enter` 在克隆的语言会话上规划，事务提交后才装回文档，失败时文档缓存不变。C++ 分析按文本内容复用；文本变化后的首次查询从上一份分析增量重建，只有 parser 配置改变才丢弃分析。缓存只保存结构，不保存缩进结果。

## 输入操作

- `Enter`：先删除选区，在换行后的临时快照上查询缩进，替换新行原有的前导空白。缩进为 `Set` 时清掉上一行只剩空白的内容。括号展开、注释续写、行首空白和光标位置属于同一事务；字符串内部换行保留右侧字节。
- `TypeChar`：语言声明的触发字符在提交后的临时快照上重算本行缩进；C++ 只在该字符实际形成相应标点 token 时调整，字符串、注释和组合标点内部按普通输入处理。访问标签、case 标签和闭合 token 的缩进变化与字符一起撤销。自动配对见[编辑命令与无 UI 工作流](commands.md)。
- `Reindent(line)`：只修改该行前导空白及必要的预处理关键字间距。
- `InsertText`：按原字节替换选区，用于粘贴。

`editor::enter`、`type_char`、`reindent` 是供自行管理状态的调用者使用的无状态版本。

## C++ 分析接口

目标契约见[交互缩进设计与契约](indentation.md)；以下返回字段不是稳定扩展协议。

- `parse_snapshot_with_options` 按 `CppRules::parser_options()` 建立完整词法与结构分析，`parse_snapshot` 使用默认 parser 配置。分析记录所用配置：改缩进宽度可继续用同一棵树，改宏分类必须重建。
- 结构节点只读，记录父子关系、半开 token 范围、缺失 token 与不完整状态；零宽缺失节点不拥有 token。节点和 token 下标只在所属分析内有效。递归深度有上限，过深或受损输入进入消耗 token 的恢复路径。
- `parser.rs` 管理扫描与容错状态；`syntax.rs` 提供只读结果和共享的格式事实（括号组、宏控制头、直接逗号、构造函数冒号），缩进与表达式重放共用。预处理分类限定在指令的逻辑行内。
- `compute_indent` 校验分析与快照文本、parser 配置一致，返回结构列、固定续行列、目标列、实际空白字节、结构角色和锚点。raw string、跨行注释和 whitespace-sensitive 的宏内容受保护，词法保护优先于 DisableFormat；AfterHash 策略可附带局部间距修改。`IndentWidth` 与非零 `TabWidth` 独立配置。
- 增量分析重新词法分析受影响的前后缀并修复受影响的容器节点，其余节点复用，与完整分析做差分测试（含逐字输入的语料轨迹）。release 构建中增量路径 panic 时退回完整分析，debug 构建直接报错。节点使用绝对 token 范围，每次编辑有 O(n) 的偏移更新（约 3 ms/MB）。表达式续行重放限制在 4096 个 token 内。

## 存储

文本存储是 Ropey 1.6（启用 SIMD），行分隔只认 LF/CRLF；单独的 CR 和 Unicode 行分隔符是普通文本，空文档和末尾换行后的空行都是行。事务按范围从后向前编辑，全部修改沿用基准坐标；字节到 Ropey 字符索引的转换只在存储层。

| 接口 | 说明 |
| --- | --- |
| `len_bytes`、`is_char_boundary`、`chunks`、`byte_slice` | 长度、边界、分块遍历、零复制切片 |
| `line` | `Cow<str>`，行跨 chunk 时只复制该行 |
| `text` | 连续全文兼容接口；首次访问生成 `Arc<str>`，同一快照的后续访问和 parser 输入共享，文本变化后生成新缓存 |

历史只保留 rope 和选区，不持有全文缓存。parser 和部分语言操作读连续文本，首次访问有全文复制成本；core 的事务和分块读取不依赖它。

## 验证

命令循环测试覆盖独立会话、跨会话映射、所属会话关闭后的恢复、配置代次和原子失败；变更组合用随机 UTF-8 编辑对照顺序执行。parser 测试检查词法流连续覆盖输入、子节点有序且属于父节点，并用全部字符前缀、随机 UTF-8 和深度嵌套检验容错与终止。

```sh
cargo build --release --example core_edit_trace
/usr/bin/time -v target/release/examples/core_edit_trace 256
```

该轨迹与 parser 无关：在约 1 MiB 文档的开头、中间和末尾插入，结束时全部撤销并校验内容。`edit_us` 只计事务提交；峰值内存包含初始文本、校验和撤销。C++ 输入延迟用 `cpp_input_trace` 测量。
