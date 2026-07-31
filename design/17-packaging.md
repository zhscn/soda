# 打包与分发

## 定位

Soda 内嵌完整的 Chez 编译器：`soda-chez.boot` 由 petite.boot 与 scheme.boot
拼接而成（[cmake/build-chez-runtime-boot.ss](../cmake/build-chez-runtime-boot.ss)），
因此运行中的 soda 进程可以直接调用 `compile-program`、`compile-whole-program`
和 `make-boot-file`，不依赖外部 Scheme 安装或 C 工具链。

打包把这条编译流水线暴露为构建器：把一个 Scheme program 编译为 boot file，
再与一个 stub 可执行文件按字节拼接，产出独立可分发的二进制。拼接与启动分派
承担传统 linker 的角色；系统 linker 不参与。

产物分两层，按运行时内容划分：

- **层 A：纯 Chez runtime。** 产物只含 Chez kernel 与用户程序，不含任何
  soda Scheme 库和 soda native 代码。面向通用 Scheme 程序与脚本分发。
- **层 B：soda runtime。** 产物是 soda 自身的运行时（native ABI、libuv、
  terminal host、全部 `(soda ...)` 库）加用户程序，面向 TUI application
  （[16-tui-applications.md](16-tui-applications.md)）和需要 soda native
  面的程序。

两层共享同一条编译流水线和同一个 trailer 容器格式，区别只在 stub 的选择
与 boot 链的组成。

## 编译流水线

与 [cmake/build-soda-boot.ss](../cmake/build-soda-boot.ss) 相同的三步，运行
在 soda 进程内：

```text
BuildRequest =
  { program_path, output_path, runtime = chez | soda,
    library_directories, optimize_level = 2 }

compile-program（generate-wpo-files 开启）
  -> compile-whole-program
  -> make-boot-file（基座依所选层而定）
```

`compile-whole-program` 返回的 remaining runtime libraries 必须为空；残留
即构建错误，报告缺失的库名。`generate-inspector-information` 默认开启，
`--strip` 关闭以缩小产物。

## Trailer 容器格式

产物文件布局：

```text
PackagedExecutable = StubImage BootEntry* Toc Footer

BootEntry = 原始 boot file 字节
Toc       = { entry_count, { name, offset, length, crc32 }* }
Footer    = 定长，位于文件末尾：
            { magic "SODABOOT", format_version, toc_offset }
```

launcher 启动时读取自身文件（`argv[0]` 解析，Linux 优先
`/proc/self/exe`）的末尾定长区：

- 无 magic：按现状启动编辑器（内嵌的 `soda-chez.boot` 与
  `soda-editor.boot`）；
- 有 magic：校验 `format_version` 与各 entry 的 crc32，按 TOC 顺序对每个
  entry 调用 `Sregister_boot_file_bytes`，随后 `Sbuild_heap` 与
  `Sscheme_start`。TOC 顺序即 boot 依赖顺序，入口 program 位于最后一个
  boot。

向 ELF/Mach-O/PE 文件尾部追加字节不影响既有段与签名前的加载行为；crc32
用于捕获截断或损坏的拷贝。boot file 与 Chez kernel 版本严格绑定；因为
app boot 总是由产出它的同一二进制编译，版本恒等由构造保证，launcher 仍在
启动时断言 `Skernel_version` 一致。

## 层 A：纯 Chez runtime

stub 是一个最小 launcher：静态链接的 Chez kernel 加 trailer loader，不注册
任何 soda foreign symbol，不内嵌任何 soda boot。该 stub 在 soda 构建期编译，
其字节作为资产内嵌进 soda 二进制，打包时直接写出。

产物 boot 链：

```text
soda-chez.boot（petite + scheme，取自 soda 内嵌字节）
app.boot（whole-program 编译的用户程序，基座 "soda-chez"）
```

约束：

- 应用可用的能力 = Chez 标准库 + 自身携带的纯 Scheme 依赖；stub 未注册
  任何 foreign symbol，`foreign-procedure` 在运行时不可解析。需要 native
  能力的程序属于层 B。
- 初版总是携带完整编译器（scheme.boot），应用因此保有运行时 `eval` 与
  自举能力；以 petite 为基座的 `--minimal` 变体留作后续演进。

## 层 B：soda runtime

stub 是 soda 自身：打包时拷贝正在运行的可执行文件。trailer 只含
`app.boot`；`soda-chez.boot` 使用 stub 内嵌的版本注册；trailer 存在时
launcher 跳过 `soda_editor_boot`，编辑器代码不进入 heap。

- 用户程序以 whole-program 方式编译，携带其 import 的 `(soda ...)` 库副本；
  与内嵌 editor boot 无共存问题，因为二者不同时注册。
- native 面 = launcher 已注册的 `Sforeign_symbol` 集合
  （document、runtime、terminal、indentation、syntax、tree-sitter）。这是
  稳定 ABI 边界：打包的应用不能引入新 native 符号；ABI 演进走
  [08-scheme-first.md](08-scheme-first.md) 的既有流程。
- 编译期需要 `(soda ...)` 库源码可见。发行版随二进制携带 `scheme/` 目录，
  查找顺序：`--libdirs` 显式指定 → 可执行文件旁的 `scheme/` → 源码树。
  经 VFS 把库源码内嵌进二进制留作后续演进。
- TUI application 产物以 sole host 模式启动
  （[16-tui-applications.md](16-tui-applications.md) 的 Host 模式一节）：
  terminal session 归应用所有，没有编辑器 chrome。

## CLI

```text
soda build app.ss -o app          # 层 B（默认）
soda build --chez app.ss -o app   # 层 A
soda run app.ss                   # 开发模式：编辑器内 embedded host
```

入口约定与 `compile-program` 语义一致：program 顶层即入口。`soda run` 不
打包，直接在当前进程 load 程序并以 embedded host 挂载，配合 REPL、
`scheme.eval-buffer` 和 debugger 获得运行时演进能力。

## 实现分层

1. trailer 格式与 launcher 探测：纯 C，无 magic 时行为与现状完全一致，
   由 TUI smoke 测试保证；
2. `soda build --chez`：最小 stub 资产 + 进程内编译流水线 + 无 TUI 的
   hello-world 冒烟测试（编译、打包、执行、退出码与输出断言）；
3. `soda build`（层 B）：自拷贝 stub、editor boot 跳过、counter 样例打包
   为独立二进制；
4. `soda run` 与 sole host 启动分派；
5. 演进项：VFS 内嵌库源码、`--minimal` petite 基座、`--strip`。

层 1-2 与 [16-tui-applications.md](16-tui-applications.md) 的框架层完全
独立，可并行推进；层 3-4 依赖框架层 1-3 提供可打包的最小应用。
