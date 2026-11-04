# DuoMac · DUO你电脑

把 iPhone Duo 折成一台远程 Mac 笔记本。上半屏显示完整 Mac 桌面，下半屏提供键盘和触控板，支持纯键盘、纯触控板、键盘＋触控板三种模式。

![DuoMac 折叠使用示意](docs/images/duomac-overview.png)

| 键盘与触控板 | 连接你的 Mac |
| --- | --- |
| ![键盘与触控板界面示意](docs/images/duomac-controls.png) | ![Mac 与手机连接示意](docs/images/duomac-desktop.png) |

*AI 生成的界面示意*

## 下载与安装

安装包见 [Releases](https://github.com/xav1erwang/DuoMac/releases)。

| 平台 | 下载文件 | 安装方式 |
| --- | --- | --- |
| macOS 27+ | `DUO-macOS-universal.dmg` 或 `.zip` | 将应用放入「应用程序」，首次启动按系统提示手动放行 |
| iOS / iPadOS 27.1+ | `DUO-iOS-unsigned.ipa` | 使用 Sideloadly 或 AltStore Classic，用自己的 Apple 账号重签安装 |

主要适配 iPhone Duo，两端需支持硬件 HEVC。Mac 包包含 Apple Silicon 与 Intel 版本。免费 Apple 账号通常每 7 天需要续签一次。

安装后在 Mac 上授予屏幕录制、辅助功能和本地网络权限，再打开手机端完成配对。[详细安装步骤](docs/INSTALL.md) · [自动续签](Signing/README.md)

## 从源码构建

需要完整 Xcode 27.1 或更新版本。

```sh
git clone https://github.com/xav1erwang/DuoMac.git
cd DuoMac
bash Scripts/build-duodesk-mac.sh
```

Mac 应用生成在 `Build/DUO你电脑 Mac.app`。iOS 端打开 `iOSClient/Sill.xcodeproj`，选择 `Sill` Scheme、自己的 Team 与唯一 Bundle Identifier，连接设备后运行。

## 开源与贡献

DuoMac 基于 [Sill](https://github.com/Saffsanity/sill) 开发，采用 [Apache-2.0 许可证](LICENSE)，上游归属与修改说明见 [NOTICE](NOTICE)。

[贡献说明](CONTRIBUTING.md) · [安全问题](SECURITY.md) · [隐私说明](docs/PRIVACY.md)
