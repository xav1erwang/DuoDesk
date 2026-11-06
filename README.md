# DuoDesk · DUO你电脑

把 iPhone Duo 折成一台远程 Mac 笔记本。上半屏显示完整 Mac 桌面，下半屏提供键盘和触控板，支持纯键盘、纯触控板、键盘＋触控板三种模式。

![DUO你电脑折叠使用示意](docs/images/duomac-overview.png)

| 键盘与触控板 | 连接你的 Mac |
| --- | --- |
| ![键盘与触控板界面示意](docs/images/duomac-controls.png) | ![Mac 与手机连接示意](docs/images/duomac-desktop.png) |

*AI 生成的界面示意*

## 下载与安装

[Releases](https://github.com/xav1erwang/DuoDesk/releases) 中的安装包目前仍为草稿，尚未正式发布。现在可以先按下方步骤从源码构建和安装。

| 平台 | 下载文件 | 安装方式 |
| --- | --- | --- |
| macOS 27+ | `DUO-macOS-universal.dmg` 或 `.zip` | 将应用放入「应用程序」，首次启动按系统提示手动放行 |
| iOS / iPadOS 27.1+ | `DUO-iOS-unsigned.ipa` | 使用 Sideloadly 或 AltStore Classic，用自己的 Apple 账号重签安装 |

主要适配 iPhone Duo，两端需支持硬件 HEVC。Mac 包包含 Apple Silicon 与 Intel 版本。免费 Apple 账号通常每 7 天需要续签一次。

[详细安装步骤](docs/INSTALL.md) · [自动续签](Signing/README.md)

## 从源码构建

需要完整 Xcode 27.1 或更新版本。

```sh
git clone https://github.com/xav1erwang/DuoDesk.git
cd DuoDesk
bash Scripts/build-duodesk-mac.sh
```

Mac 应用生成在 `Build/DUO你电脑.app`，将它移入「应用程序」并打开。

在 Xcode 中打开 `iOSClient/Sill.xcodeproj`，选择 `Sill` Scheme，在「Signing & Capabilities」中选择自己的 Team 并设置唯一的 Bundle Identifier。用 USB 连接并信任 Duo，按提示开启开发者模式，选择该设备后运行，即可安装手机端。

## 运行与配对

1. 在 Mac 上打开「DUO你电脑」，按提示允许屏幕录制、辅助功能和本地网络访问，并保持应用运行。
2. 将 Duo 和 Mac 接入同一局域网，在 Duo 上打开「DUO你电脑」，允许本地网络访问，然后在列表中选择你的 Mac。
3. 首次配对时，在 Duo 上扫描 Mac 显示的二维码；也可以选择「输入配对码」，输入 Mac 上显示的数字并点击「配对」。扫码时按提示允许相机访问。
4. 配对成功后，选择要使用的显示器，例如「主显示器」。桌面显示在 Duo 上屏，下屏可切换键盘、触控板或组合模式。以后连接同一台 Mac 无需重复配对。
5. 使用完毕后，在 Duo 上点击「断开连接」。

如果列表中没有 Mac，检查两端是否在同一局域网、本地网络权限是否开启，以及 Mac 端是否正在运行。局域网扫描暂时漏掉已配对的 Mac 时，应用也会尝试查找它；「已保存」表示暂未确认连接方式，仍可点按尝试连接。没有画面时检查 Mac 的屏幕录制权限；无法控制时检查辅助功能权限。

## 休眠与远程连接

Mac 端「设置 → 远程访问」中的「空闲时保持 Mac 可连接」默认开启：应用运行时会阻止 Mac 因空闲自动睡眠，屏幕仍可正常熄灭；使用电池时也会增加耗电，可以随时关闭。合盖、手动睡眠和关机仍由 macOS 管理。

Mac 仍在运行时，已配对的设备连接会请求唤亮显示器；如果 Mac 已锁屏，仍需输入 Mac 的锁屏密码。

两端更新后，在 Mac 清醒时连接一次，Duo 会保存局域网唤醒信息。Mac 的「系统设置 → 电池 → 选项」中需要允许「唤醒以供网络访问」（台式机在「能源」中设置）。Duo 在同一局域网选择已配对的 Mac 时会尝试唤醒并连接。能否唤醒取决于 Mac、电源、网卡与路由器；部分网络需要 Bonjour 睡眠代理，合盖或深度休眠时也可能无法唤醒。

在外网连接无需域名：先在 Mac 的「设置 → 远程访问」开启「远程访问」和「允许公网连接」，再把路由器的 TCP 端口转发到 Mac（默认 `7455`，建议同时转发 UDP 以使用 QUIC），并给 Mac 保留局域网 IP。Mac 会尝试读取路由器的公网 IP；如果没有自动获取，可在同一页面的「公网地址或域名」中输入并保存公网 IP，再用 Duo 在局域网连接一次以保存地址。公网 IP 变化后需要更新。若运营商没有提供可入站的公网 IP，或存在多级路由，可使用 VPN 或检查路由配置。外网不能保证唤醒已休眠的 Mac，保持空闲时可连接更适合无人值守的远程使用。

## 开源与贡献

DUO你电脑基于 [Sill](https://github.com/Saffsanity/sill) 开发，采用 [Apache-2.0 许可证](LICENSE)，上游归属与修改说明见 [NOTICE](NOTICE)。

[贡献说明](CONTRIBUTING.md) · [安全问题](SECURITY.md) · [隐私说明](docs/PRIVACY.md)
