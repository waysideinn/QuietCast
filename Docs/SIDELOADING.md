# 侧装、签名、续签与升级

听芽当前没有 App Store 发行版。仓库提供源码；未签名 IPA 必须经过安装者自己的 Apple 账户签名，才能在非越狱 iPhone 运行。**下载源码、编译成功和成功安装是三个不同步骤**。

## 需要准备什么

- iOS 16 或以上 iPhone、数据线和自己的 Apple 账户。
- 从源码构建需要 macOS、完整 Xcode 及匹配设备版本的 SDK；仅有 Command Line Tools 不足以编译 iPhone App。
- 使用 Sideloadly 时，从[官方网站](https://sideloadly.io/)下载工具。Windows 使用者可重签已有 IPA，但此 Swift/Xcode 工程的源码构建需要 Mac。
- 不需要越狱。免费 Personal Team 可用于个人开发测试；签名与可安装数量遵循 Apple 当期限制。

## 途径 A：编译 IPA，再使用 Sideloadly

1. 克隆项目，打开 Xcode 一次，按官方提示安装所需组件并接受许可。在 Xcode Settings → Locations 检查 Command Line Tools。
2. 进入项目目录，运行 `Scripts/build-ios.sh` 验证模拟器构建，再运行 `Scripts/build-ipa.sh`。
3. 结果为 `build/QuietCast-unsigned.ipa`。脚本使用真实 iPhoneOS Release 构建，检查平台、arm64、资源和 Bundle ID。它没有签名，不能直接在手机上点开安装。
4. 用 USB 连接并解锁 iPhone，在电脑与手机上完成配对和「信任此电脑」。
5. 打开 Sideloadly，选择自己的设备，将 IPA 拖入；按工具流程输入自己的 Apple 账户并完成二次验证。密码、验证码不发给项目维护者，不写进仓库或 issue。
6. 点击工具安装按钮，等待成功。根据系统提示启用开发者模式并重启，再在「设置 → 通用 → VPN 与设备管理」信任相应开发者；具体入口可能随系统版本变化。
7. 启动听芽，检查版本，设置自己的家长 PIN，按[使用手册](USER_GUIDE.md)完成首次验收。

如果「屏幕使用时间」禁止安装 App，应由设备家长在系统设置中自行决定是否临时允许；安装后恢复需要的设备限制，并实际检查该限制下后续覆盖安装／续签是否可行。

## 途径 B：Xcode 直接安装

1. 打开 `QuietCast.xcodeproj`，选择 QuietCast scheme。
2. 在 Xcode Settings → Accounts 添加自己的 Apple 账户。
3. 在 target 的 Signing & Capabilities 中选择自己的 Personal Team，按需启用自动管理签名。公开工程没有预填个人 Team。
4. 连接并选择自己的 iPhone，按系统提示完成开发者模式和配对，点击 Run。
5. 若 Bundle ID 注册冲突，首次安装前可选择自己可用的标识符；确认后记录，后续更新维持一致。自行修改标识符时也要理解仓库校验脚本固定检查默认 `org.quietcast.family`，相应修改校验配置。

Xcode 安装不等于配置好了 Sideloadly 的自动刷新，两条路径应分别验证。

## 免费签名和续签

Apple 官方说明：Personal Team 用于设备安装的描述文件签发后 **7 天过期**，届时 App 可能无法启动；以实际描述文件为准。[Apple 账户说明](https://developer.apple.com/help/account/basics/about-your-developer-account)。

Sideloadly 提供后台自动刷新与 Wi-Fi 安装。按当前版本界面启用自动刷新，确认听芽已加入刷新列表；保持电脑及 daemon 正常运行、手机可达、网络与账户会话有效。无线使用前通常需要 USB 配对，并在 Finder 的设备页开启 Wi-Fi 显示／同步，按官方工具要求保持网络可达。[Sideloadly 官方说明](https://sideloadly.io/)。

开启开关不等于已续签成功：观察一次实际刷新，核对新的到期日，并验证 App 能打开和数据仍在。电脑关机、daemon 停止、手机离线或账户验证失效都可能错过刷新。过期后通常需重新重签覆盖，而非永久失去源码。付费开发者账户也不意味着随意签一次就永久有效，按对应分发方式与配置期限执行。

## 升级时保留数据

1. 记录首次安装实际使用的 Apple 账户／Team、最终 Bundle ID 和 Sideloadly 标识符相关选项；这些只保存在自己的安全记录中。
2. 新版本构建新 IPA，以相同账户、Team、最终 Bundle ID 及工具设置覆盖原安装。工具可能为免费账户调整 Bundle ID，以实际签名结果为准。
3. **不要先卸载旧 App。**覆盖通常保留沙盒；改变身份可能使 Keychain 不再可访问，不能保证 PIN 或安全策略自动迁移。
4. 升级前做好设备备份。升级后核对版本、订阅、收藏、逐集进度、下载、家长 PIN 和实际词库版本。
5. 先完成一次手动覆盖验收，再信任自动刷新流程。升级源码与恢复手机使用数据是两回事。

## 分享给别人

分享仓库链接，让对方拉取源码、构建并用自己的 Apple 账户签名。若另外分享 IPA，仅提供经过隐私检查的**未签名 Release 包**；本仓库不内置 IPA 或任何签名凭据。不要分享自己的已签名包、p12／私钥、描述文件、设备 UDID、Apple 账户、家长 PIN 或手机沙盒备份。

## 常见安装故障

- **没有 SDK／找不到 Xcode**：安装完整 Xcode，完成首次组件安装和工具链选择，重新运行脚本。
- **未受信任／开发者模式未开**：按 iPhone 系统提示完成信任、开发者模式和重启。
- **无法安装或验证**：检查签名是否有效、设备配对、账户验证、系统安装限制及 Apple 当期限制；读取日志时先遮盖个人信息。
- **已过期**：同身份重签覆盖，不先卸载；之后检查 daemon 和刷新登记。
- **拖入文件失败**：核对文件是否完整；可复制到简单英文路径再导入，保留原文件做哈希比对。不要据单次失败断言是中文路径问题。

资料查阅日期：2026-10-28。工具界面和 Apple 政策可能变化，以官方说明及实际签名结果为准；本项目不承诺自然自动续签在所有环境下成功。
