# iOS 签名安装与续签

DUO你电脑的 iOS 客户端使用免费 Apple 个人团队签名时，描述文件通常 7 天后到期。安装与续签请使用成熟的自签名工具。

## 推荐工具

| 工具 | 说明 | 官方入口 |
| :--- | :--- | :--- |
| **Sideloadly** | macOS / Windows，USB 或 Wi-Fi 安装；内置自动刷新守护进程，可在设置中选择要刷新的应用和刷新计划 | [sideloadly.io](https://sideloadly.io/) |
| **AltStore Classic** | 需要同一网络中的 Mac 运行 AltServer；可在后台自动刷新，也可以手动 Refresh | [altstore.io](https://altstore.io/) · [安装指南](https://faq.altstore.io/getting-started/how-to-install-altstore-macos) |
| **SideStore** | 首次安装后无需电脑，通过 Wi-Fi 刷新；需要配对文件与 StosVPN | [sidestore.io](https://sidestore.io/) · [文档](https://docs.sidestore.io/) |

## 使用 Sideloadly 续签

1. 在 Mac 或 Windows 打开 Sideloadly，用 USB 连接 Duo 并信任电脑。
2. 选择 `DUO-iOS-unsigned.ipa`，登录用于签名的 Apple 账号并安装。更新时保持同一账号、Team 与 Bundle ID 覆盖安装，才能保留应用数据和配对。
3. 在 Sideloadly 的设置中开启自动刷新，选择要刷新的应用与刷新计划；保持电脑和手机可连接，或到期前手动重新安装同一 IPA。
4. 下载与常见问题见 [Sideloadly 官方网站](https://sideloadly.io/)。

## 使用 AltStore Classic 刷新

1. 按[官方安装指南](https://faq.altstore.io/getting-started/how-to-install-altstore-macos)在 Mac 上安装 AltServer 与 AltStore Classic，并登录同一 Apple 账号。
2. 把 IPA 导入 AltStore 完成安装；在 My Apps 中点击 Refresh，或让 AltServer 在同一网络时后台刷新。
3. 更多说明见 [AltStore FAQ](https://faq.altstore.io/altstore-classic/your-altstore)。

## 使用 SideStore 刷新

1. 按 [SideStore 文档](https://docs.sidestore.io/)准备配对文件并完成首次安装。
2. 在 SideStore 中刷新已安装的应用；首次安装之后不需要连接电脑，但需要可用的 Wi-Fi 与 StosVPN。

## 说明

- 免费 Apple 账号的限制由 Apple 管理：应用通常每 7 天需要续签，同时可安装的应用数量也有限，具体以系统或工具显示为准。参见 [Apple 账户说明](https://developer.apple.com/help/account/basics/about-your-developer-account)。
- 续签时使用与安装时相同的 Apple 账号、Team 与 Bundle ID；卸载应用或更换签名身份后，可能需要在 Mac 上重新配对。
- 从源码构建和用 Xcode 安装见[安装文档](../docs/INSTALL.md)。
