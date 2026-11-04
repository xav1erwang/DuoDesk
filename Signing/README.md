# 自签名和 Mac 自动续签

下载 Release IPA 后用 Sideloadly 或 AltStore 安装，见 [安装文档](../docs/INSTALL.md)。以下步骤适用于通过 Xcode 从本仓库源码构建、安装和续签。

使用 Xcode 账户中的开发签名，把应用装到自己配对的 iPhone Duo。工具不保存 Apple 账号密码，不上传代码到签名平台，不在手机上放置续签服务。

Apple 免费 Personal Team 的设备描述文件有效期为 7 天，具体以应用内嵌描述文件的 `ExpirationDate` 为准。[Apple 账户说明](https://developer.apple.com/help/account/basics/about-your-developer-account)同时列出了免费账号的应用和设备数量限制。Xcode 自动签名的行为见 [Signing & Capabilities workflow](https://help.apple.com/xcode/mac/current/en.lproj/dev60b6fbbc7.html)。

## 第一次安装

1. 在 Xcode 设置的 Accounts 登录自己的 Apple 账号。把 Duo 连接并信任这台 Mac，开启手机的 Developer Mode。先在 Xcode 运行一次应用，完成必要的系统确认。
2. 创建只在本机保存的配置：

   ```sh
   mkdir -p Local
   cp Signing/signing.example.json Local/signing.json
   chmod 600 Local/signing.json
   ```

3. 填写 Xcode 选中的 `team_id`、设备的 UDID 作为 `device_id`，以及自己的 `bundle_id`。`xcrun devicectl list devices` 的 Identifier 列会标明所显示的标识种类：只有标为 UDID 的值才能用于描述文件的设备校验；CoreDevice ID 或 ECID 不能当作 UDID。后续保持同一 Team 和 Bundle ID，覆盖安装才可保留应用数据和配对。
4. 运行 `python3 Signing/renew.py --force`。工具先在本机保存一致的源码快照，再使用 Xcode 的账户会话从该快照构建、校验描述文件和签名，通过 `devicectl` 安装。首次签名或新设备注册会访问 Apple 开发服务；只有设备报告安装成功后，快照才成为后续自动续签的来源。

## 自动续签

```sh
python3 Signing/renew.py --status
python3 Signing/renew.py --enable-auto
python3 Signing/renew.py --renew-now
```

启用后在这台 Mac 当前用户登录时运行，默认每 24 小时尝试续签一次；检测到指定手机重新连接时也会尝试。`renew_interval_hours` 可调整日常间隔，未设置时为 24。任务每分钟只读取本机 CoreDevice 的设备状态，不为此唤醒睡眠中的 Mac；运行中的签名任务不会并发启动另一份。手机离线时不构建，下一次检测到连接后再尝试。如果续签失败且距离到期不超过 48 小时，仍连接时最多每 6 小时重试一次。连接检测依赖 Xcode 与系统报告的设备状态，手机在两次检查之间短暂连接又断开时可能无法触发。

每次自动尝试使用 Xcode 的已有账户会话获取新描述文件，只有有效期确实比已安装版本更晚，且身份、设备与签名校验通过时才覆盖安装。Xcode 可能复用旧文件或无法签发新的文件：这种情况不会被记作续签成功，原安装记录和应用保留。重新安装会短暂中断手机上的应用；实际构建和签名时有短时 CPU、磁盘和网络开销，空闲时不持续编译。

任务读取本地配置，只安装到其中指定的设备；不会卸载应用、修改其他描述文件或撤销证书。自动续签从最近安装所用的本地源码快照构建，不会把工作区里尚未安装的修改自动带到手机，也不自动拉取远程提交。快照位于忽略的 `Local/signing-sources/`，只复制项目源码和资源，排除 Xcode 个人配置、构建产物及常见密钥和描述文件类型，不读取 `Local/` 配置或设备配对资料；构建前后都会校验。手动 `--force` 会快照当前源码并在安装成功后自动更新来源。启用命令若设置了 `DEVELOPER_DIR`，后台任务会保留这个 Xcode 路径；否则使用系统当前选择的工具链，不复制其他环境变量。再次执行 `--enable-auto` 会更新本机已有的续签任务，并在更新失败时恢复此前的配置。

签名刷新由 Xcode 的 `-allowProvisioningUpdates` 完成。安装前工具检查应用、Team、设备、签名和到期时间。自动续签必须延长有效期；手动 `--force` 可以用有效期相同、且仍超过续签提前量的描述文件覆盖安装新代码，避免 Xcode 沿用已有描述文件时无法更新。任何模式都拒绝比已安装记录更早到期的描述文件。安装开始前会保存待安装快照；如果安装或记录结果时中断，设备在线时下一次检查会立即尝试恢复同一个快照，避免退回到更旧的代码。恢复再次中断或失败后按日程、设备重连及临期规则重试，不会每分钟反复构建。设备没有成功安装，不会写入续签成功状态。来源快照缺失或校验失败时不会安装工作区的其他代码。最近一次成功安装的记录独立保存，失败不会覆盖它。

普通构建沿用未延长的描述文件时，自动续签会采用 Apple [描述文件说明](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/)中的缓存刷新方式：仅定位与本应用、团队和目标设备都精确匹配的有效文件，先把原件备份到仅本机可访问、已忽略的 `Local/signing-profile-backups/`，临时移出 Xcode 缓存，再从已安装源码快照隔离构建。构建后先恢复缓存，再验证签名并尝试安装；如果同名文件已被 Xcode 替换，会保留新旧两份，绝不覆盖。进程意外中断留下的事务会在下一次自动检查时恢复。不会处理其他应用或通配符描述文件，也不会上传备份。

若找不到本应用的匹配缓存，工具会尝试 Xcode 的自动签名归档与调试导出；归档及 IPA 只暂存在 `Local/` 的私有临时目录。无论采用哪条路径，仍须通过 Team、应用、设备、签名和有效期检查，且设备报告安装成功才更新成功记录。2026-11-02 已在 Air 上取得新的七天描述文件，并成功验签覆盖安装到真实 Duo；跨到期自动续签仍待验收。

Mac 关机、休眠、未登录，手机不可连接、未信任、Developer Mode 关闭，或者 Apple 账户需要重新认证时，任务无法完成。手机需要通过 USB 或 Xcode 已配对的无线连接可达；远程桌面的公网连接不等于可进行开发安装。应用自身不能延长 iOS 签名有效期。

查看 `Local/signing-status.json` 中最近一次成功安装、`Local/signing-monitor.json` 中的连接检查和最近尝试、`Local/signing-error.json` 中最近一次失败，以及 `Local/signing-build.log` 和 `Local/renewal-error.log`。错误文件不会因后续成功自动删除，检查其时间即可判断是否为历史记录。日志仅在本地，可能包含设备或签名元数据，反馈问题前应删去个人信息。工具的失败分支和调度已做自动测试；2026-10-29 已在 Air 上使用个人团队签名并向真实 Duo 首次安装和覆盖安装。真实设备的跨 7 天续签仍待验收。

## 停用

```sh
python3 Signing/renew.py --disable-auto
```

只移除本工具的用户后台任务，保留应用、钥匙串、证书、描述文件和本地日志。
