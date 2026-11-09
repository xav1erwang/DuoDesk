# 参与开发

先阅读 [README](README.md) 与 [开发说明](docs/DEVELOPMENT.md)，使用正式版 Xcode 27.1 或更新版本构建。保持 Apple 原生框架实现，视频、指针和编码路径避免每帧触发 SwiftUI 布局。

修改键盘、布局或续签工具后运行 `Tests/duodesk/run.sh`；修改上游传输核心后运行对应的 `Tests/checks/<name>/run.sh`。提交涉及 UI 的改动时附上 Duo 半折叠、展平、合盖的验证范围；只在模拟器验证的结果请直接说明。

不要提交 `Local/`、描述文件、证书、Apple 账号信息或真实设备标识。Apache-2.0 许可证和 Sill 来源说明必须保留。发布流程见 [发布清单](docs/release-checklist.md)，安装步骤见 [安装文档](docs/INSTALL.md)。GitHub 仓库为 `xav1erwang/DuoDesk`。
