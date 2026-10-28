# iPhone 试用交付阶段

> 当前版本更新为 **1.1.2（5）**，新增键盘提交收起及家长搜索记录；最新 IPA 和验证见 [INTERACTION_UPDATE_1.1.2.md](INTERACTION_UPDATE_1.1.2.md)。以下版本说明为历史记录。

> 2026-10-27 正式试用词库已纳入 1.1.1（4）重新构建，使用带 `fiction-v1` 文件名的新 IPA。最新校验与安装核对见 [FILTER_RULES_INTEGRATION_2026-10-27.md](FILTER_RULES_INTEGRATION_2026-10-27.md)。以下旧阶段的 example 状态仅为历史记录。

> 2026-10-27 更新：验收修复 1.1.1（4）已完成，修复首次键盘搜索、统一搜索、底部遮挡、分类加载与最近更新。最新 IPA、截图和验收交接见 [ACCEPTANCE_FIXES_2026-10-27.md](ACCEPTANCE_FIXES_2026-10-27.md)。UI 改版历史见 [UI_REDESIGN_2026-10-27.md](UI_REDESIGN_2026-10-27.md)。以下保留首版交付历史。

核查日期：2026-10-26（Asia/Hong_Kong）。固定 Bundle Identifier：`org.quietcast.family`；App 最低 iOS 16.0。本阶段只修复构建和验证问题。

## 当前结果

- 已安装完整 Xcode 27.1（27A9275）和 iOS 27.1 SDK，已完成首次启动组件安装及用户同意的许可流程。
- 完整 iphoneos Release 编译通过，已生成 `build/QuietCast-unsigned.ipa`。这是 arm64 iPhone 程序，需要 Sideloadly 重签后才能安装。
- 标准 macOS XCTest：72 项测试、0 失败，日志 `build/delivery/xctest-core-final.log`。
- iOS 27.1 专用 iPhone 模拟器：**78 项 hosted XCTest、0 失败**，日志 `build/delivery/ios-xctest-final.log`，包含真实 Keychain、AVPlayer 进度、后台 URLSession 下载、离线播放、删除、旧下载迁移及全部核心过滤测试。
- 首轮测试发现 `.audio` 扩展名导致离线音频无法打开，已修复：按音频头/MIME/安全扩展名保留容器类型，兼容迁移旧下载，不改变逐集 ID、PIN 或资料库身份。
- 模拟器启动错误通过重新加载当前用户 CoreSimulator 服务解除，没有删除设备或数据。模拟器使用本地临时签名（不需要 Apple ID），否则真实 Keychain 返回 -34018；**iPhone IPA 仍为无签名，交给 Sideloadly 重签**。
- 系统 `xcode-select` 仍为 CLT，项目脚本均使用完整 Xcode；Xcode 测试完成时的辅助诊断收集会报告找不到 simctl，但实际测试结果为成功，xcresult 已生成。日后可在 Xcode Settings > Locations 选择 Xcode 来消除该系统配置警告。
- 独立 App 安装与启动命令成功，已核对主显示屏的听芽首页；截图 `build/delivery/simulator-primary.png`。这不是 UI 全流程自动化验收。
- 没有真机安装、后台音频真机验收或 Sideloadly 自动续签成功记录；没有安装 Sideloadly。

## 可重复执行

```sh
cd '<项目目录>'
python3 Scripts/ios-preflight.py --report build/delivery/environment.json
Scripts/test.sh
Scripts/build-ios.sh
# 专用 QA 模拟器；不擦除用户模拟器数据
QUIETCAST_SIMULATOR_UDID=<SIMULATOR_UDID> Scripts/test-ios.sh
QUIETCAST_SIMULATOR_UDID=<SIMULATOR_UDID> Scripts/run-ios-simulator.sh
Scripts/build-ipa.sh
```

脚本在进程内选择完整 Xcode。若模拟器系统服务仍使用 CLT，在 Xcode Settings > Locations > Command Line Tools 选择完整 Xcode；管理员密码只在系统授权窗口输入。也可由用户自行运行 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。

`test.sh` 为标准 Swift Package XCTest；`test-ios.sh` 为 hosted 原生 iOS XCTest（72 项核心测试及 6 项原生 IO 测试）。Xcode 27 的 XCTest 要求测试 target 最低 iOS 17，**App target 仍为 iOS 16**。`run-ios-simulator.sh` 仅安装和启动冒烟检查，不能代替功能测试。后台音频、耳机、锁屏、来电、设备重启恢复及免费签名覆盖升级仍须按 DEVICE_ACCEPTANCE.md 在 iPhone 验收。

`build-ipa.sh` 核验 Bundle ID、部署目标、arm64、Mach-O 平台 IOS、后台 audio 配置与词库资源，通过后才打包 IPA；拒绝模拟器和 macOS 产物。`build/delivery/ipa-manifest.json` 记录 IPA 哈希、源码 commit、工作区修改状态及词库 example/production 状态。

## 签名与覆盖升级

使用免费 Apple ID + Sideloadly，不调用付费团队的 archive/export 分发流程。没有自定义 Entitlements，没有推送、App Groups、CloudKit；后台 audio 配置和默认本地 Keychain 不要求付费会员。无签名 IPA 交给 Sideloadly 重新签名；具体步骤见 SIDELOADING.md。

后续始终使用相同 Apple ID/Team 和 Bundle ID 选项，首次安装记录实际重签后的标识符。不要先卸载再升级，以免删除资料库。必须实际验收覆盖安装后订阅、进度和 PIN 保留。没有保存 Apple ID 密码。

## 任务 B 正式词库

研究提交 `b182e11` 已在当前历史中，不重复合并。研究发布报告 `reports/fiction_research/release/release-readiness.json` 的 `productionEligible=false`、`productionRuleFile=null`，没有人工标注金标准；不能作为正式默认词库。App 内置规则仍明确为 `status=example`。

收到正式 commit 后：先检查发布状态和评估证据，再用 `git merge-base --is-ancestor <B_COMMIT> HEAD` 检查是否已包含。只整合尚未合并的规则与测试，保留共享 Schema 1.1 和 App 功能；记录来源 commit/版本/哈希。随后重新运行 Schema、Swift loader、全部核心及 iOS 测试和 Release 构建，再交付 IPA。不能只把 JSON 改为 production。

## 验证边界

iOS 测试运行在 iOS 27.1 的 iPhone Duo 模拟器，未验证 iOS 16 运行时；App 的 iOS 16 SDK 可用性已通过编译。后台 audio 配置及中断恢复逻辑已测试，真实来电、耳机、锁屏持续播放、手机重启及 Sideloadly Wi-Fi 自动续签仍需 iPhone 实测。模拟器出现音频会话同步激活的性能提醒；当前测试通过，真机验收时仍需观察操作响应。
