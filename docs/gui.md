# 图形界面

`soda-gui` 是图形前端，与终端版 `soda` 共用 Runtime、交互层和 `screen` 的文本布局，只是显示方式不同。它需要 `gui` 特性：

```sh
cargo build --release --features gui --bin soda-gui
soda-gui [--no-config] [FILE | DIRECTORY]
```

参数、`init.lua`、状态文件和异常退出时的恢复与终端版相同（`host`）。

## 显示

参照 Emacs 的图形界面：仍然按文本行布局，但装饰是像素级的，不占字符格。

- **文本**：等宽字体（fontconfig 的 `monospace`），排在网格上：一个字形簇占的列数与核心的列宽规则一致，回退字体（中文等）的字形对齐到整列。行高是字号的 1.35 倍。
- **inlay 与行尾注记**：用小一号的字体，按字形的实际宽度排布（`Measure` 的 `Hint`），inlay 有淡色的圆角底。
- **诊断**：注记范围画波浪线；其他下划线是直线。
- **行号栏**：没有竖线，最左一列是标记（`flag-lines`），行号右对齐，后面空一列。
- **分屏**：窗口树仍以行和列为单位，按默认字体的单元格尺寸换算后拉伸到填满编辑区；左右窗口之间是一像素的细线。
- **ruler**：一条细竖线，不占列。
- **浮层**：补全、文档、按键提示、帮助、弹出文字都是带阴影和描边的圆角面板。命令行的候选在状态栏下面、输入行上面展开，与终端版相同。
- **状态栏**：模式是圆角色块，其余与终端版的内容相同（`screen::content`）。
- **光标**：Normal 和 Beacon 是半透明的块，Insert 和输入框是细竖线，颜色随模式。选项 `smooth-caret`（默认开）让光标在 80 ms 内滑到新位置（ease-out），参照 IntelliJ 的 smooth caret movement，只移动光标本身，没有拖尾。形状改变、输入法正在组字或关掉这个选项时，光标直接跳过去。

选项 `font-size`（默认 14，单位是点）设置字号，乘以窗口的缩放比例。`theme auto` 在图形界面里取深色。

## 输入

- **键盘**：winit 的按键转换成与终端相同的 `KeyStroke`：带 Shift 的字符是上档字符，Shift-Tab 是 BackTab；有 Ctrl 或 Alt 时取不带修饰键的那个键，所以 macOS 上 Option 打出的特殊字符不影响绑定。Super（Command）键标记为不支持的修饰键。
- **输入法**：只在 Insert 和输入框里开启，Normal 下按键直接是命令。组字中的文字画在光标处并加下划线，候选窗口跟着光标。提交的文字逐字作为按键输入。
- **鼠标**：点击标签切换文档，点击窗口聚焦并放置光标，拖动选择，滚轮滚动指针下的窗口或弹出文字（触摸板的像素滚动累计到一整行再滚）。拖动窗口边界还没有实现，用 `resize-window`。
- **窗口**：关闭窗口相当于 `quit`，逐个询问未保存的文档。`suspend`（Ctrl-Z）把窗口最小化。
- **剪贴板**：使用系统的剪贴板工具（wl-copy、xclip、xsel、pbcopy）；找不到时只在编辑器内部复制粘贴。

## 渲染

`gui/render.rs` 用 wgpu 画一列实例化的四边形，只有几种图元：带圆角的矩形（片元着色器里用 SDF 抗锯齿）、矩形描边、字形和波浪线。字形由 cosmic-text 整形、swash 光栅化，放进 2048×2048 的图集；图集满了就清空重来，下一帧补齐。表面优先用非 sRGB 格式，颜色按写下的值混合，和终端一样，避免文字在线性空间混合后变细。

## 快照

`gui_snapshot` 示例不开窗口，在离屏纹理上画一帧并写成 PPM 图片，用来检查画面，不会写状态文件：

```sh
cargo run --features gui --example gui_snapshot -- \
    --size 1400x900 --scale 1.5 --keys '<c-x>3<a-x>o' --out shot.ppm src/main.rs
```

`--config` 运行 `init.lua`；`--keys` 用 `map` 的记法，在文件打开后输入。
