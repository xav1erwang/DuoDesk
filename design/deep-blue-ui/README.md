# DUO你电脑 · 深蓝色统计图模板 UI 设计稿

用 Remotion 项目里的 **深蓝色统计图模板**（`Codex技能/deep-blue-stat-chart-template`）的视觉语言，重做 App 的界面外壳。深色、浅色各一套配色，**跟随系统外观**自动切换。

**这是设计稿，仓库里的 App 代码一行没改。** 设计板是独立的 HTML，模拟器预览是独立的 SwiftUI demo（`demo/`），都不接进 DuoDesk 客户端。

## 文件

| 路径 | 内容 |
| --- | --- |
| `board.html` / `board.css` | 设计板：深色 A–F、浅色 A′–F′、字标 G、两套色板、对照表、规则 |
| `build-board.py` | 生成 `board.html` 的脚本（手工改 `board.html` 会被覆盖） |
| `renders/board-full.png` | 整板位图，3200 × 8342 |
| `connect-redesign.html` | 连接页改版稿：横屏卡片 + 右侧工具栏 + 设置入口 |
| `renders/connect-redesign.png` | 上面这稿的位图 |
| `demo/` | 模拟器预览 App（SwiftUI，`build.sh` 出 `.app`） |
| `renders/sim/` | 模拟器实拍截图（8 张 + 拼版 `all.png`） |
| `fonts/` | Montserrat Black 与 OFL 许可证（VisionTec 字标用） |

打开方式：浏览器打开 `board.html`；`renders/board-full.png` 是全板。

## 模拟器预览

`demo/` 是一个只画设计稿的独立 App，跑在 iPhone Duo 模拟器上，用来确认这套配色在真实屏幕、真实字体渲染下的样子。

```sh
cd design/deep-blue-ui/demo
./build.sh                      # 出 build/DesignDemo.app
xcrun simctl install <Duo UDID> build/DesignDemo.app
xcrun simctl launch <Duo UDID> com.duodesk.designdemo -DemoScreen stream   # connect / stream / settings
```

- 横屏页（串流、设置）按 951 × 669 pt 画布绘制，对应 Duo 内屏横屏；连接页与扫码配对页是 382 × 678 pt 的竖排列，对应外屏。
- `-DemoScreen` 取 `connect` / `pairing` / `stream` / `settings`。
- 明暗由系统外观决定（`xcrun simctl ui <UDID> appearance dark|light`），App 内没有开关——和设计规则一致。
- 截图命令：`xcrun simctl io <UDID> screenshot --display=primary-1`（内屏）或 `--display=primary`（外屏）。
- 折叠姿态用仓库的 `Tests/duorig/run.sh <UDID> pose flat-landscape` / `closed-upright`。

截图见 `renders/sim/`：`stream-*`、`settings-*`、`pairing-*`、`connect-*`（各深/浅，JPEG），拼版 `all.png`。

## 取自模板的部分

| 模板 | 这里的用法 |
| --- | --- |
| 深蓝黑底 + 径向环境光 | `#030811` 台面，顶部一束冷蓝光；浅色改为带蓝的纸白 `#EEF3F9` |
| 大 R 角玻璃面板 + 蓝描边 | 24 pt 圆角、`1px rgba(105,180,255,.24)`、`inset 0 1px 0 rgba(255,255,255,.08)` 顶边光、内侧蓝雾 |
| 青蓝高亮单条数据 | 只给“当前”：当前窗口缩略图、展开的抽屉/设置、选中行、当前设备 |
| 冷灰蓝普通数据 / 青蓝重点 | 普通文字 `#8FA7C2`，强调 `#2BD6FF`（深色）/ `#0A6488`（浅色文字）、`#0B63C6`（浅色按钮） |
| 细网格与颗粒 | **不用**。模板为 4K 视频防 8-bit 断层而加，缩到 App 尺寸会变成可见格子，两套主题都不画 |

## 改动范围

改：iOS 连接页、串流顶栏、窗口缩略条、应用抽屉、设置面板、配对卡；Mac 状态菜单卡片、配对窗口。

不改：浅色铝面控制台（键盘、触控板、模式切换、帧率）、iOS 状态栏、串流画面本身、AppKit 菜单本体与 SwiftUI `Form` 的系统控件、系统键盘。

## 连接页：去掉页脚

稿里不再画「在 Mac 上运行 DUO你电脑服务端…」「支持局域网与公网直连」和三个链接，底部只留居中的字标。

注意：这三行在现有代码里是 App Review 要求的入口（Mac 端下载、支持、隐私政策，`ConnectScreen` 的 `footer`）。真要删，得先把支持与隐私链接挪到设置面板；否则审核会缺项。稿里先按“干净”的视觉做。

## VisionTec 字标

来源：VisionLab 的 `VisionTec 品牌资源/VisionTec 文字 Logo 设计规范.md`——Montserrat Black 900、全大写 `VISIONTEC`、字距 `0.18em`、行高 1、单行、按字形边缘视觉居中。字体在 `fonts/Montserrat-900.ttf`，附 OFL 1.1（`fonts/LICENSE-Montserrat.txt`，OFL 要求随字体分发）。

- **位置**：连接页底部居中，离开页脚链接区，上下留 18 pt。
- **大小**：9 pt。
- **颜色**：深色 `#7C93AD` / 62%，浅色 `#435A70` / 50%。不发光、不加描边、不做按钮态。
- **字体不可用**时回退 `.system(size:weight: .black)`，字距保持 `0.18em`。不手绘近似字形（App 图标里的 “V” 水印也是从字体轮廓化来的）。

字号说明：规范建议屏幕可见字高 ≥ 20 px；这里按 9 pt 排版（可见字高约 6.4 pt），是刻意的“印刷角标”用法，只提供形状提示。要做正式品牌露出需另起一处 ≥ 20 px。

## 图标尺寸

连接页标题左侧原来的 48 pt 图标块偏大。稿里改成 **34 pt 圆角块 + 17 pt 图标**，和 `DrawerRow` 的 32 pt 图标块一致。

## Token

### 深色

| 用途 | 值 |
| --- | --- |
| 台面 | `#030811`，渐变 `#061323 → #030811 → #02060D` |
| 玻璃面板 | `linear-gradient(145deg, rgba(14,46,82,.72), rgba(2,10,22,.54))` over `rgba(5,18,34,.72)` |
| 控件 | `#0C2440` |
| 选中 / 展开 | `#12395C` + `1px rgba(43,214,255,.55)` |
| 正文 / 次级 / 三级 | `#F2F7FF` / `#8FA7C2` / `#7C93AD` |
| 动作、链接 | `#23A7FF` |
| 当前态 | `#2BD6FF → #129DFF` |
| 中性数据 | `#85A4C5` |

### 浅色

| 用途 | 值 |
| --- | --- |
| 台面 | `#EEF3F9`，渐变 `#F3F8FE → #EEF3F9 → #E7EEF7` |
| 面板 | `#FFFFFF → #F5F9FD` + `1px rgba(11,99,198,.16)` |
| 控件 | `#E7EFF9` |
| 选中 / 展开 | `#D8E8FB` + `1px rgba(11,99,198,.48)` |
| 正文 / 次级 / 三级 | `#0C1A2A`（15.7:1）/ `#4C6076`（5.8:1）/ `#435A70`（7.2:1） |
| 动作、按钮 | `#0B63C6`（白字 5.8:1） |
| 当前态文字 | `#0A6488`（5.5:1） |
| 中性数据 | `#4B6D8F` |

浅色不是反相：底色换纸白、发光换成阴影与描边、青蓝换成更深一档的蓝（`#2BD6FF` 在白底只有 2.8:1）。

## 对照现在的 `Palette`

| 现在 | 深色 | 浅色 |
| --- | --- | --- |
| `bar #16181C` | `#071729` 玻璃条 | `#FFFFFF → #F2F7FD` |
| `panel #1F2126` | 玻璃面板 + 24 pt 圆角 | 白面板 + 蓝描边 |
| `control #23262C` | `#0C2440` | `#E7EFF9` |
| `controlOpen #2C3550` | `#12395C` + 青蓝描边 | `#D8E8FB` + 蓝描边 |
| `accent #9BB7FF` | `#23A7FF` | `#0B63C6` |
| `muted #A4ABB5` | `#8FA7C2` | `#4C6076`（三级 `#7C93AD` → `#435A70`） |
| `barLabel #C4C9D1` | 保留 | `#4C6076` |
| `text #EEF0F3` | `#F2F7FF` | `#0C1A2A` |
| `trackpad #101215` | 保留（属控制台） | 保留 |

其余尺寸沿用现有数值：66 pt 顶栏按钮、16 pt 按钮圆角、15 pt 正文、380 pt 连接列；`HostSettingsPanel` 的面板圆角从 20 pt 改成 24 pt。

## 跟随系统，没有开关

两套主题都从 `@Environment(\.colorScheme)` 取色。**不提供“深色 / 浅色”手动选项。**

改主题前必须先处理这几处强制深色，否则浅色永远不生效：

- `iOSClient/ContentView.swift:40` — `.preferredColorScheme(.dark)`
- `iOSClient/ContentView.swift:550` — DEBUG 布局台里那处，可保留
- `iOSClient/DisplayPicker.swift:26` — `.preferredColorScheme(.dark)`

Mac 端的 `StatusCard`、`PairDeviceWindow` 读同一个 `colorScheme`；AppKit 菜单本体不重绘。

## 需要按主题分叉的组件

| 组件 | 深色 | 浅色 |
| --- | --- | --- |
| `BarButton` / `bar-chip` | `#0C2440` + 顶边光 | `#FFFFFF` + 1 px 蓝描边 + 2 px 阴影 |
| `WindowThumbnail` 外框 | 中性描边，当前项青蓝 + 外发光 | 当前项蓝描边，**无发光** |
| `AppDrawer` 面板 | 玻璃 + 40 px 蓝色外晕 | 白面板 + 26 px 灰蓝阴影 |
| `HostSettingsPanel` `Rows` | `linear-gradient(160deg, rgba(10,33,58,.92), rgba(5,18,33,.9))` | `#FFFFFF` + 1 px 描边 |
| `Toggle` 打开态 | `#2BD6FF → #1199F0` + 16 px 青色光 | `#1B7BD4 → #0B63C6`，无光 |
| `ConnectScreen` 设备行 | 当前行 `#12395C` 渐变 + 左侧 3 pt 青光 | `#DBEAFA` 渐变 + 3 pt 蓝条 |
| 扫码框 | 青蓝四角 + 青蓝投影 | 蓝色四角，无投影 |
| 配对码文字 | `#2BD6FF` + 光 | `#0A6488`，无光 |

## 浮层一律毛玻璃

抽屉、设置面板、配对卡都是浮在串流画面上的，必须是**真模糊**而不是半透明色块：

| | 做法 |
| --- | --- |
| 模糊 | demo 用 `.ultraThinMaterial`；设计板用 `backdrop-filter: blur(22px) saturate(1.06)` |
| 填充 | 52–74% 不透明度，让底下的 Mac 窗口透出模糊虚影 |
| 高光 | 面板上再加一道 155° 的白色斜向反光（深色 10%→0，浅色 60%→6%→22%）——没有这道反光，玻璃会读成半透明色块 |
| 遮罩 | 深色 0.24、浅色 0.14。遮罩太重会把背后的画面压平，模糊就没有可解的细节 |

**模糊能不能看出来，取决于背后有什么。** 第一版把 Mac 桌面画成一片近黑，抽屉再好的模糊也只是一块深灰——所以模拟器里的桌面改成了彩色壁纸加两个窗口（Finder + 一张米色便笺），面板后面的窗口边缘和便笺会以虚影透出来。

真实 App 里桌子后面是用户自己的桌面，通常有内容；但如果用户桌面很暗、窗口又正好不在面板下方，观感仍会接近实色。这是材质本身的限制，不是实现没做。

## 规则

1. 深蓝只用于 App 自绘外壳。串流画面、缩略图内容、Mac 桌面不做任何调色。
2. 同一时刻只有一处强调。深色用青蓝 + 微光，浅色用深蓝 + 描边，不叠加。
3. 不用贴顶亮条、满宽细线、渐变扫光、背景网格当装饰；面板的顶边光用渐变描边，不能是横贯顶边的白线。
4. 两套都满足对比度：正文 ≥ 11:1，次级 ≥ 4.5:1，强调 ≥ 5:1。
5. 所有浮层都带毛玻璃模糊。
5. 切主题不重新连接、不重建视频层；面板与卡片 0.2 s 交叉淡化，避免闪白。

## 来源

- 模板：`Remotion Skill 视频包装制作/Codex技能/deep-blue-stat-chart-template`（`SKILL.md`、`references/style-and-motion.md`、`assets/remotion-template/deepBlueStatChart.css`）
- 字标：`VisionLab/VisionTec 品牌资源/VisionTec 文字 Logo 设计规范.md`
- 结构：`iOSClient/`（`StreamScreen`、`PortraitStreamScreen`、`DuoControlDeck`、`AppDrawer`、`HostSettingsPanel`、`AddMacCard`、`PairingOverlay`、`ConnectScreen`）、`Sources/SillMenuBar/`（`StatusCard`、`PairDeviceWindow`、`SettingsPanes`）
