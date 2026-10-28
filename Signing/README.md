# 自签名和 Mac 自动续签

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
4. 运行 `python3 Signing/renew.py --force`。工具使用 Xcode 的账户会话，构建、校验描述文件和签名，然后通过 `devicectl` 安装。首次签名或新设备注册会访问 Apple 开发服务。

## 自动续签

```sh
python3 Signing/renew.py --status
python3 Signing/renew.py --enable-auto
```

启用后在这台 Mac 当前用户登录时运行，每 6 小时检查一次，在签名到期前 48 小时尝试更新。任务读取本地配置，只安装到其中指定的设备；不会卸载应用、修改其他描述文件或撤销证书。任务使用这份本地源码，不自动拉取远程提交。启用命令若设置了 `DEVELOPER_DIR`，后台任务会保留这个 Xcode 路径；否则使用系统当前选择的工具链，不复制其他环境变量。

签名刷新由 Xcode 的 `-allowProvisioningUpdates` 完成。安装前工具检查应用、Team、设备、签名和到期时间。自动续签必须延长有效期；手动 `--force` 可以用有效期相同、且仍超过续签提前量的描述文件覆盖安装新代码，避免 Xcode 沿用已有描述文件时无法更新。任何模式都拒绝比已安装记录更早到期的描述文件。设备没有成功安装，也不会写入续签成功状态，下次检查会重试安装。最近一次成功安装的记录独立保存，失败不会覆盖它；缓存的构建或描述文件损坏时，续签会重新构建并再次校验。

Mac 关机、休眠、未登录，手机不可连接、未信任、Developer Mode 关闭，或者 Apple 账户需要重新认证时，任务无法完成。手机需要通过 USB 或 Xcode 已配对的无线连接可达；远程桌面的公网连接不等于可进行开发安装。应用自身不能延长 iOS 签名有效期。

查看 `Local/signing-status.json` 中最近一次成功安装、`Local/signing-error.json` 中最近一次失败，以及 `Local/signing-build.log` 和 `Local/renewal-error.log`。错误文件不会因后续成功自动删除，检查其时间即可判断是否为历史记录。日志仅在本地，可能包含设备或签名元数据，反馈问题前应删去个人信息。工具的失败分支和调度已做自动测试；尚未完成真实 Duo 的签名、覆盖安装及跨 7 天续签验收。

## 停用

```sh
python3 Signing/renew.py --disable-auto
```

只移除本工具的用户后台任务，保留应用、钥匙串、证书、描述文件和本地日志。
