# 安装与首次连接

## 运行要求

Mac 应用要求 macOS 27 或更新版本，iOS 客户端要求 iOS / iPadOS 27.1 或更新版本。主要适配 iPhone Duo。两端均使用硬件 HEVC，通用 Mac 包包含 arm64 与 x86_64，实际兼容性仍取决于系统、硬件编码能力和对应设备验收。

普通使用者下载 Release 文件即可，源码构建需要完整 Xcode 27.1 或更新版本。初次启动 Xcode 时完成许可证确认、平台组件安装，并在 Xcode 的 Locations 中选中对应的 Command Line Tools。[Apple Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)

## macOS

1. 在本仓库 [Releases](https://github.com/xav1erwang/DuoDesk/releases) 下载 `DUO-macOS-universal.dmg`。
2. 打开磁盘映像，将「DUO你电脑 Mac」拖入「应用程序」，再从「应用程序」启动。
3. 当前免费账号发布包使用 ad-hoc 签名。若系统阻止启动，先尝试打开一次，再进入「系统设置 → 隐私与安全性」，为这一个应用选择「仍要打开」。系统提示的具体措辞取决于 macOS 版本。[Apple 打开受阻应用说明](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)
4. 按应用指引授予屏幕录制、辅助功能和本地网络权限，必要时退出并重新打开应用。

ZIP 是同一应用的另一种封装，解压后将应用移入「应用程序」。正式的 Developer ID 签名及 Apple 公证需要维护者加入 Apple Developer Program，目前尚未配置。[Apple 分发与公证说明](https://developer.apple.com/developer-id/)

## iOS 自签 IPA

发布文件 `DUO-iOS-unsigned.ipa` 包含真机 arm64 应用，需要安装工具用你的账号重签。免费账号最多同时安装三个开发应用，描述文件自签发起七天到期，需要重新签名安装。实际到期时间以签名工具或描述文件显示为准。[Apple Personal Team 限制](https://developer.apple.com/help/account/basics/about-your-developer-account)

### Sideloadly

1. 从 Sideloadly 官方网站下载 macOS 或 Windows 版本。
2. 用 USB 连接并在 iPhone 上信任电脑。按设备和工具提示启用「设置 → 隐私与安全性 → 开发者模式」，完成重启确认。
3. 打开 Sideloadly，选择手机，把 `DUO-iOS-unsigned.ipa` 拖进去，登录自己的 Apple 账号并完成签名安装。
4. 按手机提示在「通用 → VPN 与设备管理」中信任开发者，然后打开应用。
5. 在 Sideloadly 中配置自动续签。电脑与设备必须在续签时可达，首次安装使用 USB 更容易排查问题。

这些步骤依据工具官方安装方式整理，本项目当前 IPA 还需在真实设备上完成 Sideloadly 安装、启动、配对与到期续签验收。[Sideloadly 官方说明](https://sideloadly.io/)

### AltStore Classic

先按 AltStore 官方流程安装 AltServer 与 AltStore Classic，再在手机的 My Apps 页面导入本项目 IPA。安装后保持 AltServer 可达并在到期前刷新签名。AltStore 本身也占一个免费开发应用名额。项目当前 IPA 的 AltStore 安装仍待真机验收。[AltStore Classic 安装入口](https://faq.altstore.io/)、[刷新与应用数量说明](https://faq.altstore.io/altstore-classic/your-altstore)

更新时保持相同签名账号、Team 与 Bundle Identifier，覆盖安装有助于保留设置和配对。卸载或更换签名身份可能需要重新配对。

### 从源码通过 Xcode 安装

1. 克隆仓库，打开 `iOSClient/Sill.xcodeproj`，选择 `Sill` Scheme。
2. 在 Xcode Settings → Accounts 登录自己的账号。
3. 在 Target 的 Signing & Capabilities 中选择自己的 Team，并将 Bundle Identifier 改为你可用的唯一标识，例如 `com.yourname.duodesk`。
4. 连接手机，选择目标设备，开启开发者模式后运行。

本地持续续签工具的配置、启停与失败处理见 [Signing/README.md](../Signing/README.md)。跨到期自动续签仍需真机验收。

## 首次连接

1. 在 Mac 上启动主机，确保两端处于同一局域网并允许本地网络访问。
2. 在手机打开应用，找到 Mac，按配对界面操作，也可扫描 Mac 展示的配对码。
3. 配对后选择共享桌面，在 Duo 上使用键盘与触控板。
4. 无画面时先检查 Mac 屏幕录制权限、两端系统版本和主机提示。无法控制时检查 Mac 辅助功能权限。
5. 使用后在客户端断开，Mac 主机正常结束共享并恢复它管理的显示状态。

初次验收先使用局域网。公网访问须单独配置网络和主机设置，步骤见开发文档。

## 校验下载

将同一次 Release 的文件与 `SHA256SUMS` 放在同一目录，在终端运行以下命令。下载全部列出的文件后，所有项目应显示 `OK`。

```sh
shasum -a 256 -c SHA256SUMS
```

## 仅构建

```sh
bash Scripts/build-duodesk-mac.sh
bash Scripts/build-duodesk-mac.sh --arch universal
bash Scripts/build-duodesk-simulator.sh
bash Scripts/release-duodesk.sh --platform ios
```

前两个命令生成 Mac 应用。模拟器脚本生成测试应用。最后一个命令生成供真机重签的 IPA。构建脚本的 `--help` 列出输出路径、版本和签名选项。
