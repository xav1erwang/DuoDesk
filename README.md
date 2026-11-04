# DuoMac · DUO你电脑

把 iPhone Duo 折成一台远程 Mac 笔记本。上半屏完整显示 Mac 桌面，下半屏提供键盘和触控板，支持纯键盘、纯触控板、键盘＋触控板三种模式。

基于 [Sill](https://github.com/Saffsanity/sill) 的原生捕获、HEVC、TLS 配对和输入链路开发，采用 Apache-2.0 许可证。加密会话优先使用 QUIC，TCP 备用通道执行相同身份校验。桌面保持原生像素，硬件编解码不可用时会报告失败。

## 下载与安装

前往本仓库的 [Releases](https://github.com/xav1erwang/DuoMac/releases)。首个版本正在准备，公开下载以已发布的 Release 为准。

| 平台 | 下载文件 | 安装方式 |
| --- | --- | --- |
| macOS 27 或更新 | `DUO-macOS-universal.dmg` 或 `.zip` | 含 Apple Silicon 与 Intel 可执行文件。复制应用到「应用程序」，未公证版首次启动按系统提示手动放行 |
| iOS / iPadOS 27.1 或更新 | `DUO-iOS-unsigned.ipa` | 使用自己的 Apple 账号，通过 Sideloadly 或 AltStore Classic 重签安装 |

主要适配 iPhone Duo。其他 iPhone、iPad 与 Intel Mac 的实际可用性需要对应设备验证。Mac 与手机均需支持硬件 HEVC。免费 Apple 账号的 iOS 签名有效期通常为 7 天，需要定期续签。[Apple 账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account)

完整步骤见 [安装与首次连接](docs/INSTALL.md)，源码安装及自动续签见 [Signing/README.md](Signing/README.md)。

## 从源码构建

需要安装完整 Xcode 27.1 或更新版本并完成首次启动配置，包含 iOS SDK。当前本机验证工具链为 Xcode 27.2。所需系统框架由 Xcode 提供，Swift Package 依赖均在仓库内。

```sh
git clone https://github.com/xav1erwang/DuoMac.git
cd DuoMac
bash Scripts/build-duodesk-mac.sh
```

Mac 应用位于 `Build/DUO你电脑 Mac.app`。脚本默认使用本地 ad-hoc 签名，构建时无需 Apple 开发证书。也可一次生成两端发布文件。

```sh
bash Scripts/release-duodesk.sh
```

产物位于 `Temp/Release/0.1.0/`，包括 Mac DMG、ZIP、iOS IPA、安装说明及 SHA-256 校验文件。iOS 真机安装仍需用户签名。需要自行在 Xcode 运行时，打开 `iOSClient/Sill.xcodeproj`，选择 `Sill` Scheme、自己的 Team、唯一的 Bundle Identifier 和目标设备，再运行。

```sh
bash Tests/duodesk/run.sh
```

更多构建方式与权限说明见 [安装文档](docs/INSTALL.md)，维护者发布流程见 [发布清单](docs/release-checklist.md)。

## 当前验证范围

默认请求 60 FPS，可选择 120 FPS。已有原生尺寸硬件编解码与局域网测试图结果，真实桌面稳定 120 FPS、真实 Duo 当前版本完整操作及跨七天自动续签仍待验收。首次公开版本按预览版准备。具体证据与已知问题见 [开发状态](docs/the development notes)。

## 参与和来源

- [贡献说明](CONTRIBUTING.md) · [安全问题](SECURITY.md) · [隐私说明](docs/PRIVACY.md)
- [开发说明](docs/DUO-DEVELOPMENT.md) · [上游原始 README](docs/UPSTREAM-README.md)
- [Apache-2.0 许可证](LICENSE) · [Sill 归属与修改声明](NOTICE)

`site/`、`docs/DEVELOPMENT.md`、旧规划与上游发布记录保留用于溯源。当前安装和发布以本 README、安装文档及 DuoMac 发布清单为准。
