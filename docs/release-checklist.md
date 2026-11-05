# DuoMac 发布清单

项目仓库为 [xav1erwang/DuoMac](https://github.com/xav1erwang/DuoMac)。旧版 Sill 发布记录完整保存在 [上游发布记录](UPSTREAM-RELEASE-CHECKLIST.md)。

## 当前发行方式

维护者目前使用免费 Apple 账号。GitHub Release 提供 ad-hoc 签名的 macOS 通用 DMG、ZIP，以及供用户重签的 iOS IPA。macOS 用户首次启动可能需要在系统设置手动放行，iOS 用户通过自己的免费账号安装并定期续签。安装步骤见 [INSTALL.md](INSTALL.md)。

## 版本与产物

`Packaging/DuoHost-Info.plist` 的 `CFBundleShortVersionString` 与 iOS 工程的 `MARKETING_VERSION` 必须相同。标签格式为 `vX.Y.Z`。默认发布 build 使用 iOS 工程的 `CURRENT_PROJECT_VERSION`，脚本把同一 build 写入两个产物，也可用 `--build` 显式指定。

```sh
bash Scripts/release-duodesk.sh --check-version
DUODESK_REPOSITORY_URL=https://github.com/xav1erwang/DuoMac \
  bash Scripts/release-duodesk.sh --version 0.1.0
```

默认产物目录为 `Temp/Release/0.1.0/`。

每次打包使用空输出目录。再次打包同一版本时，通过 `--output Temp/Release/0.1.0-rebuild` 指定新目录，避免不同平台或 build 混入同一批产物。

- `DUO-macOS-universal.dmg`
- `DUO-macOS-universal.zip`
- `DUO-iOS-unsigned.ipa`
- `INSTALL.txt`
- `SHA256SUMS`

两端应用包含 Apache-2.0 `LICENSE` 和 `NOTICE`。打包脚本验证 Mac 签名、二进制架构、iOS 包内容和校验和。它不会启动应用。iOS IPA 的配对钥匙串能力需在重签后的设备安装中验证。

## GitHub 自动构建

`.github/workflows/ci.yml` 在主分支推送、PR 和手动触发时编译两个平台，执行控制和续签检查。`.github/workflows/release.yml` 在 `v*` 标签推送或手动指定标签时构建，使用当前仓库地址生成下载和支持链接，并创建 Draft Release。维护者确认产物后发布草稿。

发布任务需要仓库 Actions 可用，并允许该工作流的 `contents: write` 权限。首次公开版本应在发布界面标记为预览版，并附上当前验证范围。云端运行成功记录是正式启用这套流程的验收项。

## 首次公开前

- [ ] 确认新仓库归属为 `xav1erwang`，名称为 `DuoMac`，公开范围符合维护者决定。
- [ ] 推送准备好的源码，确认下载源码包和干净 clone 都可构建。
- [ ] 运行 GitHub CI，确认 Mac、iOS 与现有检查全部通过。
- [ ] 使用本次下载的 Mac 包，在另一台 Mac 或新用户下完成安装、手动放行、权限授权与启动。
- [ ] 使用发布 IPA 在真实 Duo 上通过 Sideloadly 或 AltStore 安装，完成启动、配对、桌面画面、键盘、触控板及断开恢复。
- [ ] 记录免费签名到期时间，完成一次跨到期前的自动刷新验收。
- [ ] 检查版本说明，列明实际硬件和系统、已验证功能及剩余问题。
- [ ] 启用私人漏洞报告，并核对安全报告入口。
- [ ] 人工复核历史与二进制资源的公开范围，尤其是截图、日志片段和个人信息。
- [ ] 确认所有新增源码、Signing 工具和发布脚本已纳入 Git，`Local/`、`Temp/`、Build、密钥及配对资料均被排除。
- [ ] 发布前更新开源状态说明，并公开仓库与首个 Release。

## 2026-11-04 本地准备记录

源码依赖全部在本仓库，iOS 工程通过相对路径引用 Swift Package。Apache-2.0 文件与上游一致，修改声明保存在 NOTICE。已补齐双平台打包、CI、草稿 Release、安装文档及可选仓库链接，关闭旧上游发布入口，清理上游赞助与客服入口。

定向扫描覆盖 776 个当前文件和 5,130 个可达历史 blob，约 272 MB。七类明确令牌和私钥标记检查未发现有效密钥材料，历史路径未发现 `Local/`、`Temp/` 或常见证书、描述文件。该扫描覆盖范围之外仍包括图片 OCR、全历史高熵检测与个人邮箱人工审阅。

独立源码副本在 Xcode 27.2 下从零编译通过 macOS arm64、x86_64 及 iOS 真机 Release，并生成 DMG、ZIP 和 IPA，校验和通过。副本不含原工作区的 Local、Temp、Build 或编译缓存。控制模型 192 项、Python 续签 18 项、身份启动 31 项、更新规则 124 项、QUIC 回环 16 类场景通过，视频呈现器严格 Swift 6 并发编译通过。

真实设备安装、完整桌面端到端操作和七天续签仍是首发验收项，既有测试范围见 [开发状态](the development notes)。

## 后续 Developer ID 公证

取得 Apple Developer Program 及 Developer ID Application 证书后，可在本机钥匙串保存公证凭据，使用下列入口构建。证书与凭据保存在仓库外。

```sh
DUODESK_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
DUODESK_NOTARY_PROFILE='duomac-notary' \
  bash Scripts/release-duodesk.sh --platform macos --notarize
```

该路径包含 hardened runtime、时间戳签名、公证、票据装订和 Gatekeeper 检查。本次使用免费账号，公证路径待具备凭据后实测。[Apple Developer ID 与公证](https://developer.apple.com/developer-id/)

TestFlight 或 App Store 另需开发者计划、App Store Connect 记录、隐私资料与审核。当前 GitHub IPA 采用用户自签安装方式，TestFlight 发布流程待后续单独配置。[Apple 分发方式](https://help.apple.com/xcode/mac/current/en.lproj/dev31de635e5.html)
