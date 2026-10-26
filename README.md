# DUO你电脑 · DuoDesk

把 iPhone Duo 折成一台远程 Mac 笔记本。上半屏完整显示 Mac 桌面，下半屏提供拟物键盘和触控板，支持纯键盘、纯触控板、键盘＋触控板三种模式。

桌面的比例和分辨率以 Duo 上半屏的原生像素为准：连接时切换 Mac 桌面，正常断开或退出后恢复。编码仅向上对齐偶数像素，不因网络或编码性能不足而自动降低分辨率。

原生 iOS 客户端与 Mac 服务端基于 [Sill](https://github.com/Saffsanity/sill) 的 HEVC、TLS 配对和输入链路开发，使用 Apache-2.0 开源许可证。视频会话优先使用 QUIC，TCP 作为受相同身份校验保护的备用通道。采用强制硬件编解码，目标为局域网和公网直连 120 FPS。原生尺寸的编解码与局域网测试图已测到约 120 FPS，真实桌面采集尚未达标；真实 Duo、中文输入与跨周期自动续签仍待真机验收。

- [当前开发状态与验收范围](docs/the development notes)
- [开发、构建与连接](docs/DUO-DEVELOPMENT.md)
- [自签名与自动续签](Signing/README.md)
- [贡献说明](CONTRIBUTING.md)
- [许可证](LICENSE) · [上游来源与改动](NOTICE)

需要 Xcode 27.1 正式版，iOS 27.1 SDK，Mac 端目标为 macOS 27。运行 `Scripts/build-duodesk-mac.sh` 构建独立 Mac 应用；在 Xcode 打开 `iOSClient/Sill.xcodeproj` 构建手机端。运行 `Tests/duodesk/run.sh` 检查键盘、布局、帧率统计、身份启动和续签状态。

本项目仍在开发，尚未发布 GitHub 仓库或可供公众安装的版本。[原项目说明](docs/UPSTREAM-README.md) 与旧文档用于追溯来源；本 README 和开发说明描述本分支行为。
