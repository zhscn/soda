# Soda

Soda 是用 Rust 实现的终端编辑器，核心体验是 CLion 式的 C++ 即时缩进：回车时根据增量维护的语法结构和项目的 `.clang-format` 计算新行缩进，并正确处理 tab 与 space 混排。编辑采用 meow 式的选择优先模型，Insert 和输入框支持 readline 键。

```sh
cargo run --release -- [--no-config] [FILE]
cargo run -- --help        # 默认键位与命令
```

编辑区按 `F1` 查看当前键位与命令，`<space>:` 打开命令面板，`:` 打开命令行。启动时读取 `~/.config/soda/init`（或 `$XDG_CONFIG_HOME/soda/init`），每行一条 `map`、`unmap` 或 `define-command`：

```
map normal <space>w write
define-command fmt pipe clang-format --assume-filename="$SODA_FILE"
map normal <space>= fmt
```

## 文档

- [架构概览](docs/architecture.md)
- [编辑内核与接口](docs/core.md)、[坐标与逻辑列](docs/coordinates.md)、[边界契约](docs/contracts.md)
- [编辑命令](docs/commands.md)、[文件服务](docs/files.md)
- [交互缩进设计与契约](docs/indentation.md)、[clang-format 配置](docs/clang-format.md)
- [交互层：键位、命令与配置](docs/interaction.md)、[扩展模型：选项、展开与钩子](docs/extension.md)
- [终端界面](docs/ui.md)
- [语法高亮与导航](docs/syntax.md)

## 构建与验证

```sh
cargo test
cargo fmt --check
cargo clippy --all-targets -- -D warnings
```

检查一个文件中指定行的缩进决策和配置来源，行号从 1 开始：

```sh
cargo run --example inspect_indent -- path/to/file.cpp 20
```

对 clang-format 格式化过的源码逐行重算缩进，统计一致率：

```sh
cargo run --release --example indent_accuracy -- [--show N] <file-or-dir>...
```
