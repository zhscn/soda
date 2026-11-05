# 图形界面

`soda-gui` 是图形前端，与终端版共用 Runtime、交互层和 `screen` 的布局（见[终端界面](ui.md)），只是画法不同（winit、wgpu、cosmic-text）。参数、`init.lua`、状态文件和异常退出后的恢复与终端版相同（`host`）。

```sh
cargo build --release --features gui --bin soda-gui
soda-gui [--no-config] [FILE | DIRECTORY]
```

## 显示

参照 Emacs 的图形界面：仍按文本行布局，但文字按像素排，装饰是像素级的，不占字符格；网格只是排版的尺子。

- **文本**：等宽字体排在网格上，字形簇占的列数与核心的列宽规则一致；回退字体（中文等）的字形对齐到整列，比所占列窄的宽字形居中。行高是字号的 `line-height`%。窗口底部不足一行的部分也画，翻页和视口跟随仍按完整的行，光标行总是完整的。
- **字体**：fontconfig 的选择：正文是 `monospace`；汉字、假名、韩文的回退分别是 `monospace:lang=zh-cn`（繁体中文环境用对应语言）、`ja`、`ko` 匹配到的字体，排在 cosmic-text 自带回退之前，所以全角标点按简体中文字形画。没有 fontconfig（macOS）时用平台默认字体。
- **界面文字**：标签、状态栏、消息、命令说明、按键提示说明和补全类型用比例字体（`ui-font`）；输入框、候选名、按键和帮助要按列对齐，用正文字体。
- **inlay 与行尾注记**：小一号字体，按字形实际宽度排（`Measure` 的 `Hint`），inlay 有淡色圆角底。
- **下划线**：诊断范围是波浪线，其他是直线。
- **行号栏**：最左是 fringe，标记（`flag-lines`、`soda.flag`）画成标记 face 颜色的小圆点；行号右对齐，后空一列，列中间一条分隔线（`border` 色减半，比窗口之间的线淡，不会被看成窗口边界）。没有行号（`line-numbers` 为 `off`）时只留 fringe，也没有分隔线。
- **选区**：同一行相邻的选中片段合成一块圆角矩形，多行逐行一块。
- **分屏**：窗口树仍以行列为单位，按默认字体的单元格换算后拉伸到填满；窗口之间是一像素 `border` 色细线：左右窗口之间画在隔开的那一列中间，上下窗口之间画在下面窗口的顶边（Emacs 在这里是上面窗口的 mode line），关掉标签栏也分得清。焦点以外的窗口铺 `inactive-window` 的底色，它们的当前标签也是这个底色，仍像通向下面的正文。`ruler` 是一条细竖线。
- **浮层**：补全、文档、按键提示、帮助、弹出文字是带阴影和描边的圆角面板。命令行的排布与终端版相同。
- **状态栏**：全局一条，内容同终端版（`screen::content`）；模式是圆角色块，未保存是小圆点。
- **滚动条**：滚动时右侧出现细拇指，停下 0.8 秒后淡出，颜色是 face `scrollbar` 的背景色；显示时可以拖动。
- **光标**：Normal 和 Beacon 是盖住整个字符的半透明块（汉字两列，tab 上一列，同 Emacs 默认的 `x-stretch-cursor`），Insert 和输入框是字宽五分之一（至少 2 像素）的竖线，颜色随模式。`smooth-caret` 让光标在 80 ms 内 ease-out 滑到新位置（参照 IntelliJ），没有拖尾；当前行高亮带随之滑动，行号颜色按被高亮带盖住的比例渐变（`gutter-current` 与 `gutter` 属性不同时直接切换）。形状改变、输入法组字中或选项关闭时直接跳过去。

## 滚动

视口锚点（顶行的字节偏移）仍由 Application 持有；图形界面在它之上加一个按像素的偏移。

- **平滑滚动**：锚点变了（翻页、跳转、视口跟随、滚轮一格 `scroll-lines` 行），先把偏移设成抵消相差的行数，再在 150 ms 内 ease-out 到新位置。相差超过窗口三倍的直接到位。
- **水平滚动**：视口横向移动时同样在 150 ms 内缓动，每帧按缓动中的位置排版；超过窗口三倍宽的直接到位。
- **触控板**：按像素滚动，攒满一行移动锚点，余下的留在偏移里，顶行可以只露出一部分（同 Emacs `pixel-scroll-precision-mode`）。
- 光标、当前行高亮和行号都按文字的位置画，随文字一起移动。

`smooth-scroll` 关闭后按整行跳动，触控板攒满一行再滚。

## 选项与外观

| 选项 | 默认 | 作用 |
| --- | --- | --- |
| `font` | 空 | 正文字体族；空时用 fontconfig 的 `monospace` |
| `ui-font` | 空 | 界面字体族；空时用 fontconfig 的 `sans-serif` |
| `font-size` | 14 | 字号（点），乘以窗口缩放比例 |
| `line-height` | 135 | 行高，字号的百分比 |
| `smooth-caret` | true | 光标滑动 |
| `smooth-scroll` | true | 平滑滚动与触控板按像素滚动 |

改了下一帧生效。颜色用 `face` 改，与终端版共用；图形界面另读 `scrollbar`。`theme` 命令补全时的预览两个前端都有。

## 输入

- **键盘**：winit 的按键转换成与终端相同的 `KeyStroke`：带 Shift 的字符取上档字符，Shift-Tab 是 BackTab；有 Ctrl 或 Alt 时取不带修饰键的那个键，所以 macOS 的 Option 字符不影响绑定。Super 标为不支持的修饰键。
- **输入法**：只在 Insert 和输入框里开启。组字中的文字画在光标处加下划线，候选窗口跟着光标；提交的文字逐字作为按键输入。
- **鼠标**：点击标签在它的窗口里显示那个文档，中键点击标签关掉它（`close-tab`），点击窗口聚焦并放置光标，拖动选择，滚轮和触控板滚动指针下的窗口或弹出文字，拖动滚动条。拖动左右窗口间的空隙或上下窗口交界处（上下各 4 像素）按整格调整窗口大小，指针停在那里时变成调整形状。
- **窗口**：关闭窗口相当于 `quit`，逐个询问未保存的文档；`suspend`（`C-z`）最小化窗口。
- **剪贴板**：直接用窗口系统的剪贴板：Wayland 下经窗口自己的连接（smithay-clipboard），X11 和 macOS 用 arboard；都不可用时退回剪贴板工具（wl-copy、xclip、xsel、pbcopy），再没有就只在编辑器内部。Wayland 的内容由程序自己提供，没有剪贴板管理器时退出后随之消失。

macOS 的 Command 键按系统习惯处理，不经过键位表：

| 键 | 命令 |
| --- | --- |
| Cmd-C / X / V | `copy` / `cut` / `paste`；有选区时 Cmd-C 是 `save`（同 `M-w`，复制后取消选区）；命令行和输入框里 Cmd-V 粘贴系统剪贴板 |
| Cmd-Z / Shift-Cmd-Z | `undo` / `redo` |
| Cmd-A / S / Q | `select-all` / `write` / `quit` |
| Cmd-H / M | 隐藏程序 / 最小化窗口 |

不用 winit 自带的应用菜单：它的 Cmd-Q 不询问未保存的文档就退出。

## 渲染

`gui/render.rs` 用 wgpu 画一列实例化的四边形，图元只有圆角矩形（片元着色器里 SDF 抗锯齿）、矩形描边、字形和波浪线，每个带一个裁剪矩形。字形由 cosmic-text 整形、swash 光栅化，放进 2048×2048 的图集，满了就清空，下一帧补齐。表面优先用非 sRGB 格式，颜色按写下的值混合，和终端一样，避免文字变细。这样混合时浅底上的深色字仍偏细，所以字形的 coverage 在着色器里先按文字亮度增强对比、再按 gamma 修正（`font-contrast`、`font-gamma`），和 Zed 一样沿用 DirectWrite 的参数。

取不到可画的图像时跳过这一帧：超时（Metal 在窗口上屏前会这样）稍后再画，窗口被遮挡时等它露出来（`Occluded(false)`）再画。macOS 上第一帧总在窗口上屏前，跳过后不再画就会白屏到下一个事件。

设了环境变量 `SODA_TRACE_STARTUP` 时，标准错误里列出启动的各步（配置、窗口、GPU、字体、跳过的帧）距启动的毫秒数，直到第一帧显示出来，用来查启动慢或白屏。

## 快照

`gui_snapshot` 示例不开窗口，在离屏纹理上画一帧写成 PPM，不写状态文件。先画一帧，再输入 `--keys`（`map` 的记法），等动画停下后取画面（滚动条可能还没淡出）；`--config` 运行 `init.lua`。

```sh
cargo run --features gui --example gui_snapshot -- \
    --size 1400x900 --scale 1.5 --keys 'C-x 3 M-x o' --out shot.ppm src/main.rs
```

## 打包

应用标识是 `io.github.zhscn.soda`（`gui::APP_ID`）：Linux 上它是 Wayland 的 app_id、X11 的 `WM_CLASS` 和桌面入口的文件名，桌面环境据此把窗口对应到入口和图标；macOS 上它是包标识。

- **Linux**：`scripts/install-linux.sh` 把 `soda`、`soda-gui`、`packaging/linux/io.github.zhscn.soda.desktop` 和 `assets/icon.svg`（装成 hicolor 的 scalable 图标）放到 `PREFIX`，默认 `~/.local`。
- **macOS**：`scripts/bundle-macos.sh` 构建 `soda-gui`，用 `packaging/macos/Info.plist` 和已提交的 `soda.icns` 组装 `Soda.app` 并做临时签名。`scripts/make-icons.sh` 从 `assets/icon.svg` 渲染 `.icns`，只在图标改动后运行。

从启动器或 Finder 打开时，工作目录若是根目录就换成主目录，项目从主目录找起。macOS 上从 Finder 启动的程序拿不到 shell 的 `PATH`，语言服务器的命令要写绝对路径；Finder 里“用 Soda 打开”文件还不支持。
