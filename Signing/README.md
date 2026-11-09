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
4. 运行 `python3 Signing/renew.py --force`。工具读取当前项目的最新源码（包括未提交修改），为本次构建保存一致的本地快照，再使用 Xcode 的账户会话构建、验签和覆盖安装。首次签名或新设备注册会访问 Apple 开发服务。安装前后都会读取手机上的实际版本，核对成功才更新安装记录。

## 自动续签

```sh
python3 Signing/renew.py --status
python3 Signing/renew.py --enable-auto
python3 Signing/renew.py --renew-now
```

启用后在这台 Mac 当前用户登录时运行，默认每 24 小时尝试续签一次；检测到指定手机重新连接时也会尝试。`renew_interval_hours` 可调整日常间隔，未设置时为 24。任务每分钟只读取本机 CoreDevice 的设备状态，不为此唤醒睡眠中的 Mac；运行中的签名任务不会并发启动另一份。手机离线时不构建，下一次检测到连接后再尝试。如果续签失败且距离到期不超过 48 小时，仍连接时最多每 6 小时重试一次。连接检测依赖 Xcode 与系统报告的设备状态，手机在两次检查之间短暂连接又断开时可能无法触发。

每次自动尝试使用 Xcode 的已有账户会话获取新描述文件，只有有效期确实比已安装版本更晚，且身份、设备与签名校验通过时才覆盖安装。Xcode 可能复用旧文件或无法签发新的文件：这种情况不会被记作续签成功，原安装记录和应用保留。重新安装会短暂中断手机上的应用；实际构建和签名时有短时 CPU、磁盘和网络开销，空闲时不持续编译。

**每次续签都重新读取当前项目的最新源码。** 每日任务、手机重连和失败重试使用相同规则，不再从历史安装记录或上次中断的快照选择源码。快照只用于保证本次构建的一致性；工具不自动拉取 GitHub，更新远程源码后应先同步到这份项目。代码有变化而版本号与手机相同时，工具会提升构建号；源码版本已经落后于手机时，必须先更新源码，不能通过升号或 `--force` 覆盖新版。

同一台手机建议只由一台主要 Mac 续签，并在这台 Mac 保持源码最新。切换电脑时，先在旧电脑执行 `python3 Signing/renew.py --disable-auto`，再在新电脑启用。安装脚本与续签共用版本检查：构建前检查一次，安装前再检查一次，防止构建期间其他电脑更新了手机；安装后手机报告的版本必须与产物一致。

任务只安装到本地配置指定的设备，不会卸载应用或撤销证书。快照位于已忽略的 `Local/signing-sources/`，只复制源码和资源，排除 Xcode 个人配置、构建产物、常见密钥和描述文件，不复制 `Local/` 配置或配对资料；构建前后都会校验。启用命令若设置了 `DEVELOPER_DIR`，后台任务会保留这个 Xcode 路径；否则使用系统当前选择的工具链。再次执行 `--enable-auto` 会更新本机已有任务，更新失败时恢复此前配置。

签名刷新由 Xcode 的 `-allowProvisioningUpdates` 完成。安装前工具检查应用、Team、设备、签名和到期时间。自动续签必须延长有效期；手动 `--force` 更新代码时可以使用与安装记录到期时间相同、且仍有效的描述文件，无需剩余超过 48 小时。任何模式都拒绝比已安装记录更早到期的描述文件。中断后，设备在线时下一次检查会立即用当前最新源码重试；再次失败后按日程、设备重连及临期规则重试，不会每分钟反复构建。设备没有通过安装后版本核对，不会写入成功状态；失败保留最近一次成功安装记录。

普通构建沿用未延长的描述文件时，自动续签会采用 Apple [描述文件说明](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/)中的缓存刷新方式：仅定位与本应用、团队和目标设备都精确匹配的有效文件，先把原件备份到仅本机可访问、已忽略的 `Local/signing-profile-backups/`，临时移出 Xcode 缓存，再从本次最新源码快照隔离构建。构建后先恢复缓存，再验证签名并尝试安装；如果同名文件已被 Xcode 替换，会保留新旧两份，绝不覆盖。进程意外中断留下的事务会在下一次自动检查时恢复。不会处理其他应用或通配符描述文件，也不会上传备份。

若找不到本应用的匹配缓存，工具会尝试 Xcode 的自动签名归档与调试导出；归档及 IPA 只暂存在 `Local/` 的私有临时目录。无论采用哪条路径，都使用本次最新源码快照，仍须通过 Team、应用、设备、签名和有效期检查，以及安装后的实际版本核对。

Mac 关机、休眠、未登录，手机不可连接、未信任、Developer Mode 关闭，或者 Apple 账户需要重新认证时，任务无法完成。手机需要通过 USB 或 Xcode 已配对的无线连接可达；远程桌面的公网连接不等于可进行开发安装。应用自身不能延长 iOS 签名有效期。

macOS 可能限制后台 Python 读取「桌面」「文稿」「下载」。若后台日志出现 `Operation not permitted`，可将项目放在 `~/Developer/` 等普通目录后重新启用任务，或使用已获该目录访问权限的 Python 执行 `--enable-auto`。终端中手动续签成功，并不代表后台任务也有相同权限。

查看 `Local/signing-status.json` 中最近一次成功安装的版本、构建号、源码摘要和到期时间，`Local/signing-monitor.json` 中的连接检查和最近尝试，以及 `Local/signing-error.json`、`Local/signing-build.log`、`Local/renewal-error.log`。`newer_version_installed` 表示这台 Mac 的源码落后于手机，未构建或安装。错误文件不会因后续成功自动删除，检查其时间即可判断是否为历史记录。日志仅在本地，可能包含设备或签名元数据，反馈问题前应删去个人信息。真实设备的跨 7 天续签仍待验收。

## 停用

```sh
python3 Signing/renew.py --disable-auto
```

只移除本工具的用户后台任务，保留应用、钥匙串、证书、描述文件和本地日志。
