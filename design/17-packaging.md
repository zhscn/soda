# 构建、打包与分发

## 实现状态

| 能力 | 状态 |
|---|---|
| 静态 native core、Chez kernel 与 C launcher | 已实现 |
| 嵌入 Chez runtime boot 和编译后的 Soda core boot | 部分实现 |
| 单一编辑器可执行文件与 runtime grammar/query 安装 | 已实现 |
| 进程内 Scheme program 编译接口 | 未实现 |
| trailer 容器与 application launcher 分派 | 未实现 |
| 纯 Chez / Soda application 两层打包 | 未实现 |

## 编辑器构建

Soda 使用 C executable 作为进程入口和 ELF 容器。构建图为：

```text
Chez kernel
native core + libuv + Tree-sitter core
  -> soda launcher

petite.boot + scheme.boot
  -> independent ELF sections (.petite.boot, .scheme.boot, .soda_core.boot)

Soda core Scheme program
  -> whole-program object
  -> soda-core.boot (base boots: scheme, petite)

launcher + embedded boot sections
  -> soda executable
```

C 入口完成 native foreign symbol 注册、boot 注册、heap 建立和进程参数准备，然后
调用 Scheme 入口。launcher 按 Chez 约定注册 `petite.boot`、`scheme.boot` 和
`soda-core.boot`；Soda core boot 直接声明 Chez base boot 依赖。launcher 不实现编辑器
策略，也不解析 Scheme library。

嵌入的 `scheme.boot` 提供 Chez compiler，因此运行中的编辑器可以使用 `eval`、
`compile-program` 和 debugger，不依赖外部 Chez 安装。Soda core boot 由
whole-program 编译生成，构建时要求 remaining runtime libraries 为空。

Chez 发行版中的 `scheme-script.boot` 是 `scheme-script` 可执行文件使用的入口名称；
它与 `scheme.boot` 通常具有相同的 boot 内容。Soda 通过 `Sscheme_start` 进入编辑器，
不把 `scheme-script.boot` 作为第三个 runtime boot 嵌入。需要脚本启动入口的打包器可以
为同一份 `scheme.boot` 内容注册 `scheme-script.boot` 别名。

## Native 链接边界

编辑器可执行文件静态链接：

- document、C++ lexer/analysis、indentation；
- runtime、terminal 和 Tree-sitter core；
- libuv 及构建配置要求的系统库；
- Chez kernel。

语言 grammar 不进入可执行文件。grammar shared library 和 Soda-owned query bundle
作为 runtime package 安装，由 [09-language-modes.md](09-language-modes.md) 的
language runtime 按需加载。runtime root 的查找契约见项目 [README](../README.md)。

## 安装布局

```text
<prefix>/bin/soda
<prefix>/share/soda/runtime/grammars/<language>.<shared-library-extension>
<prefix>/share/soda/runtime/queries/<language>/<query>.scm
```

可执行文件和 runtime package 是一个发行单元。grammar 与 query 使用同一个
language identity；parser ABI、query capture 和 language profile 必须匹配。

## Application 打包契约

Scheme application 打包器使用运行中 Soda 所携带的 Chez compiler，把 program
编译为 boot entry，再附加到适配所选 runtime 的 launcher。目标产物分为：

- **Chez runtime**：Chez kernel、Chez boot 和用户 program，不注册 Soda native
  symbols；
- **Soda runtime**：Soda launcher、native ABI、所需 `(soda ...)` library 和用户
  program，可承载 [16-tui-applications.md](16-tui-applications.md) 定义的 sole host。

两类产物共享 boot container：

```text
PackagedExecutable = StubImage BootEntry* Toc Footer

TocEntry = { name, offset, length, crc32 }
Footer   = { magic "SODABOOT", format_version, toc_offset }
```

launcher 从自身文件末尾读取定长 footer，验证格式版本、entry 范围和 checksum，按
TOC 顺序注册 boot，最后建立 heap 并进入 program。boot 与 Chez kernel 版本严格
绑定；打包器只使用当前进程携带的 kernel/boot 组合。

Soda runtime application 只能使用 launcher 已注册的 foreign symbol。新增 native
能力需要进入 Soda ABI 和 launcher，不能由打包后的 Scheme program 动态扩展。

## 编译请求

打包入口接收结构化请求：

```text
BuildRequest {
  program_path,
  output_path,
  runtime: chez | soda,
  library_directories,
  optimize_level,
  inspector_information?
}
```

流水线依次执行 `compile-program`、`compile-whole-program` 和 `make-boot-file`。
remaining runtime library 非空、program 引用未注册 foreign symbol、boot 版本不匹配
或 container 校验失败都构成构建错误。

application library 的源码发现通过显式 library directory 和 Soda runtime library
surface 完成。打包器不从编辑器当前 Buffer 集合推断依赖；Buffer 只作为命令的
program/resource 输入。
