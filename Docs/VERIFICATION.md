# 最新 SDK 构建验证（2026-10-26）

完整 Xcode 27.1（27A9275）、iOS 27.1 SDK 已就绪。真实 iphoneos Release 编译和 IPA 平台核验通过，产物 `build/QuietCast-unsigned.ipa`。标准 macOS XCTest：72 项、0 失败，日志 `build/delivery/xctest-core-final.log`；iOS 27.1 hosted XCTest：78 项、0 失败，日志 `build/delivery/ios-xctest-final.log`。其中 6 项原生测试使用真实模拟器 Keychain、AVPlayer 与后台 URLSession；离线格式失败已修复并回归。没有真机或 Sideloadly 续签成功记录。详见 IPHONE_DELIVERY.md。以下为此前阶段历史记录，其环境限制已部分解决。

# 实际验证记录

## 最新：2026-10-26（Asia/Hong_Kong）

- 当前仍只有 Command Line Tools，`xcode-select -p` 为 `/Library/Developer/CommandLineTools`，`xcodebuild -version` 仍明确要求完整 Xcode。没有 iOS SDK 构建、IPA 或真机验收结果。
- `Scripts/test-cli.sh` 实际编译核心与工具，运行 **72 个用例、280 条断言、0 失败**，日志为 `core-test-results-2026-10-26.txt`。标准 XCTest 入口仍保留；这些结果来自同用例 CLI 适配器，不能称为 iOS UI 自动化通过。
- 新增覆盖：v1.0/v1.1兼容、分类ID/名称/路径、全部110个标准分类ID完整性及继承、同名不同账号、托管域名与账号区分、混合账号部分节目、待确认/过期/缺失身份、三源独立/联合、同源去重、家长例外优先级、旧模型解码、旧缓存不能覆盖新元数据、各发现来源重复授权、推荐多样性、缓存优先/失败回退、单集ID/GUID对齐及本地次数不被进度检查点放大。
- 任务 B 的 `research-multisource-2026-10-26-v0.1` 候选已同时通过当前 JSON Schema 与真实 Swift loader，仍为 example，未替换为生产词库。
- 当前与冻结 v1.0 Schema 校验均通过；冻结文件逐字节等于原始接口提交，SHA-256 为 `62480d94c7828797d715b29f4ae7452f359849f7cdd0aa85e9f918ddd4fa0f43`。旧示例未修改，新示例明确为 example，没有启用真实发布账号黑名单。
- `Scripts/check-project.py`：工程引用、资源、稳定 Bundle ID、共享 scheme、后台配置和全部 App Swift 语法通过。AppStore 另外在 macOS SDK 上以临时播放器/下载类型适配器完成类型检查；这不等于完整 iOS 构建。
- 官方公开数据源实测：CN现代节目榜100条、CN/US现代单集榜50条、CN旧版节目榜50条、CN历史分类榜20条；旧版单集 Feed 为空，不采用；一次美区现代节目榜探测超时，保留失败记录。详见 public-source-probe.json 与 DISCOVERY.md。
- 公开 `entity=podcastEpisode` Lookup 实测单节目返回21条（1节目+20集），多节目ID返回每个节目的对应单集GUID。探测文件只保留必要标识，未请求音频。
- 实际客户端完整链路使用当前多来源示例并限制6个榜单候选：`.build/debug/quietcast-tools smoke-home CN` 最后输出如下。节目榜和单集榜来源保持真实，单集已经使用稳定GUID对齐，不按标题猜测。数量只是当次过滤后的结果，不承诺固定数量。

```text
topShows: origin=appleShowsChart, source=https://rss.marketingtools.apple.com/api/v2/cn/podcasts/top/50/podcasts.json, allowed=5, cached=false
topEpisodes: origin=appleEpisodesChart, source=https://rss.marketingtools.apple.com/api/v2/cn/podcasts/top/50/podcast-episodes.json, allowed=4, cached=false
```

新增原生横向节目卡片、分类导航、榜单/本地推荐/发现栏目、缓存状态与下拉刷新已写入现有 App，仍待 SDK 类型检查和真实 iPhone 交互验收。后台播放、系统中断、实际下载、Keychain设备行为及Sideloadly自动续签的未验证状态不变。正式词库仍由任务B交付，未把研究状态包装为生产完成。

## 2026-10-25 历史记录


日期：2026-10-25，Asia/Hong_Kong。

## 环境与阻碍

- 工作目录初始为空、无 Git 仓库；已按用户提交要求创建 `main`，共享 Schema 首个提交 `9e908672b5ac6afe94a0f6ea4e5d0f31f66b7360`。
- macOS arm64，Apple Swift 6.2，`xcode-select -p` 为 `/Library/Developer/CommandLineTools`。
- `xcodebuild -version` / `-showsdks` 失败：需要完整 Xcode。
- 标准 `swift test` 无法运行：`no such module 'XCTest'`。保留标准 XCTest 用例，另提供仅改变断言适配与入口的 CLI runner，在同一 PodcastCore 二进制上执行相同测试函数。

## 已执行并通过

1. `Scripts/test-cli.sh`：核心和 CLI 实际编译链接，**42 个用例、160 条断言、0 失败**。完整输出见 `core-test-results.txt`。覆盖加载器、评分/归一化/排除、名单优先级、失败回退、入口枚举绕过、更新后重新授权、RSS/XML/UTF16 实体拒绝、超时重试、URL/外链、缓存、持久化、会话隔离、离线文件/配额/删除、PBKDF2 标准向量、PIN/失败延迟/授权失效、规则导入保留原状态、中断恢复意图。PIN 测试使用注入的内存安全存储，不代表真实 iOS Keychain 已通过。
2. `python3 Scripts/validate_rules.py rules/example-fiction.json`：draft 2020-12 Schema 自检及样例验证通过。原三个交接文件未更改。
3. `.build/debug/quietcast-tools validate rules/research/fiction-candidate.json`：任务 B `research-2026-10-25-v0.2` 候选可通过真实 Swift loader，status=example，未安装到 App；这里只证明接口兼容。
4. `.build/debug/quietcast-tools smoke-network 科学`：在允许网络访问的运行中，使用真实核心网络客户端从 iTunes 得到 31 个唯一 RSS（当时 limit=40，之后调整为20以覆盖全部结果的 RSS 简介加载）；成功解析 `http://www.ximalaya.com/album/60789081.xml`，标题 `3-6岁儿童科学百科故事|睡前科普故事`，134 个音频单集。**只取目录与 RSS，没有请求音频，也未声称该节目适合儿童或应当被允许。** 沙盒内首次 DNS 请求失败，放开网络后验证成功。
5. `plutil -lint`：Info.plist 和 project.pbxproj 通过；`python3 Scripts/check-project.py`：工程引用、本地 Package、共享 scheme、资源、稳定 Bundle ID、iOS 16 deployment target、后台 audio 配置和 App Swift 语法检查通过。
6. AppStore 另外在 macOS SDK 上使用临时的播放器/下载类型适配器做类型检查通过；临时适配器没有进入工程。这只能检查业务层与核心模型调用，不证明原生 iOS AV/SwiftUI 层可以编译。

## 未验证且不能宣称已完成

- 完整 iOS SDK 类型检查/链接、模拟器运行、SwiftUI 视觉布局与交互。
- 真机音频流、后台长时间播放、锁屏/蓝牙/AirPlay/耳机、真实来电中断、强杀/设备重启恢复。
- 后台 URLSession 实际网络下载、暂停恢复/系统唤醒/离线音频解码。
- 真机 Keychain、设备锁定后存储可用性、签名身份保持、覆盖升级。
- IPA：`Scripts/build-ios.sh`、`Scripts/build-ipa.sh` 均明确以缺少 Xcode/SDK 停止；**没有导出 IPA**。
- Sideloadly 安装与自动续签：没有执行，文档只有操作步骤。
- B 的正式生产词库与独立评估：目前只有探索候选；未自动把 example 改为 production。

## 已知限制与建议

- 未经 iOS 编译和真机验收，不能把本版本当作已证明可日常替代 Apple Podcasts 的成品。先完成 DEVICE_ACCEPTANCE.md，再评估发布。
- 词库只能检查 RSS/目录元数据，不能判断没有文字线索的音频；示例词条覆盖率很低。
- 仅 RSS 2.0；最多解析每 feed 的 3,000 个可播放 item；未提供 Atom、OPML、榜单或云同步。尚无 UI 自动化测试。
- 不自动合并不同 RSS 别名；guid 变化会成为新单集。JSON 整库原子写入适合首版，超大资料库未来可迁移原生数据库。
- 初始进度 seek 完成前不会写临时零位；强杀仍可能损失最近约 10 秒。真实 AVPlayer 时序需设备验证。
- 暂停恢复依赖源服务器/系统 resume data；不支持恢复的源可能从头重下。系统临时下载缓存未计入显示容量。manifest 损坏后音频可能成为未索引文件，后续应增加带确认的孤立文件修复工具。
- HTTP RSS/audio 为兼容公开源而开放 ATS，传输不加密。下载文件不通过文件共享暴露；外部 URL 不允许 file:// 或音频直链。
- Keychain 无法访问时保持锁定。忘记 PIN 无恢复功能；重新签不同 Team/标识符、卸载或设备重置不是可靠的找回方式。

阶段 1–4 的实现代码已交付，阶段 5 仍等待生产词库，阶段 6 核心测试已执行，iOS 构建与真机验收被环境阻碍。没有将“写了代码”标为真实设备功能已验证。
