# 听芽 QuietCast

面向家庭的原生 iPhone 播客播放器：孩子可以探索公开播客，家长可以用 PIN 管理分类、屏蔽词和节目／单集例外，并查看本机搜索与拦截记录。适合希望保留中文内容探索自由，同时细化收听边界的家庭。

**当前版本：1.1.3（6）｜iOS 16+｜SwiftUI / AVPlayer｜Bundle ID：`org.quietcast.family`。**

本项目目前通过源码构建和侧装使用，尚未提供 App Store 发行渠道。**未签名 IPA 必须由安装者使用自己的 Apple 账户签名后安装**。没有 App 内账号、云同步、付费 AI 接口或第三方 Swift 运行时依赖。

本版重点：本地优先加载、减少切页与重开时的重复计算，以及家长允许节目／单集后的明确反馈。详见[更新日志](CHANGELOG.md)。

## 从这里开始

- [完整中文使用手册](Docs/USER_GUIDE.md)：首次设置、探索、订阅、播放、下载、家长控制及故障处理。
- [侧装、签名、续签与升级](Docs/SIDELOADING.md)：Mac 构建、Sideloadly 和 Xcode 真机安装。
- [版本保存、重新拉取与共享](Docs/GIT_GUIDE.md)：克隆、备份边界、继续开发和安全提交。
- [隐私与发布说明](Docs/PRIVACY_AND_RELEASE.md)：网络访问、设备数据、脱敏范围。
- [架构](Docs/ARCHITECTURE.md)、[发现模块](Docs/DISCOVERY.md)、[词库接口](schemas/content-filter-interface.md)。

## 核心功能与优势

| 功能 | 听芽当前实现 |
| --- | --- |
| 真实公开播客 | iTunes 公开目录搜索、公开 RSS 与 Apple Podcasts 节目链接导入；音频直接来自发布者 |
| 内容发现 | 节目榜、单集榜、分类探索、目录发现与本机推荐；网络失败可使用已有缓存 |
| 家长可调规则 | PIN 保护规则修改；Apple 父／子分类限制、自定义屏蔽词、节目／单集允许与禁止 |
| 多来源判定 | 词库可结合标题、简介、Apple 分类和发布身份，显示命中证据、规则版本与原因 |
| 多入口校验 | 搜索展示、详情、播放、队列、下载、历史与恢复等入口执行过滤；规则变更会重新校验 |
| 本机使用记录 | 家长验证 PIN 后可查看搜索关键词、次数和时间，管理拦截记录与误拦截例外 |
| 日常播放器 | 0.75～3 倍速、逐集进度、指定时间跳转、队列、连播、睡眠定时、收藏和历史 |
| 下载与系统音频 | 下载暂停／继续／重试、空间上限与清理；实现后台音频、锁屏控制、蓝牙与 AirPlay |
| 可维护性 | Swift 原生代码、规则 JSON 可本地导入；没有自建后端或 AI 推理服务的运行成本 |

## 与带家长控制的音频产品对比

以下按官方公开介绍对比（查阅日期：2026-10-28），不把官方未提及的功能直接认定为不存在。优势针对不同家庭需求，不代表过滤准确率优于其他产品。

| 产品／方案 | 主要控制方式 | 听芽的差异与适用优势 | 对方的优势／听芽的限制 |
| --- | --- | --- | --- |
| Gertrude Podcasts | 家长 PIN 控制搜索和添加节目，孩子收听已批准节目 | 听芽允许孩子自行搜索，通过分类、关键词及节目／单集例外细化边界；有 PIN 保护的本机搜索记录。适合希望保留自主探索的家庭 | Gertrude 的逐节目批准模式更适合严格白名单家庭，且提供 App Store 安装；听芽当前没有“所有新节目必须先获家长批准”的严格模式，存在漏拦截风险 |
| Pinna | 儿童内容库、年龄／类型发现和家长控制，完整内容通过订阅提供 | 听芽支持公开 RSS 和中文公开目录，不局限于单个平台内容库；App 本身无订阅服务，也不需要听芽账号 | Pinna 有策划与审核的儿童内容及原创节目；听芽不提供人工逐集审核，也没有这些专属内容的授权 |
| Apple Podcasts ＋屏幕使用时间 | 系统内容限制、设备使用时段及家庭管理 | 听芽在播放器内提供可解释规则、自定义词和逐节目／逐集例外；适合希望更细地配置中文主题边界的家庭 | Apple 的系统级管理覆盖整个设备且便于远程家庭管理；听芽只控制自身 App，不能限制其他 App、网页或设备使用时长 |

官方来源：[Gertrude 产品介绍](https://gertrude.app/updates/gertrude-podcasts-launch)、[Pinna](https://pinna.fm/)、[Apple 家长控制](https://support.apple.com/en-us/105121)。本表不依赖未经证实的竞品功能推测，也不承诺其他服务长期维持当前政策。

## 过滤边界与当前状态

内置规则版本为 `fiction-zh-2026-10-27-v1`，重点是中文小说／有声书识别，属于正式集成的**试用规则**；独立准确率尚未认证。色情擦边、恐怖猎奇、赌博等类别没有完整可启用词库，不能宣传为全面儿童内容防护。

过滤依赖节目与单集元数据，**不会转写或识别实际音频，也不会识别封面画面**。标题／简介未描述的内容、发布者误标分类、节目后来改变方向，都可能造成漏拦截。允许整个节目后也应关注新增单集。它不自动去除音频广告，不提供儿童安全保证。首次交给孩子前，请由家长设置 PIN、检查分类和词库、试听内容，并测试允许与禁止。

当前没有：云同步、远程家长管理、多儿童档案、强制每日使用时长、OPML 导入导出、推送、Atom feed、音频转写、Share Extension 或 Universal Links。支持自定义 `quietcast://feed?url=...` 路由，但不等于系统分享扩展。仓库用于恢复项目源码，不能恢复手机的订阅、PIN 或播放进度。

## 本地开发与构建

需要 macOS、完整 Xcode 和支持目标设备的 iOS SDK。最低系统要求是 iOS 16，但旧版 Xcode 未必能连接更新系统的手机。打开 `QuietCast.xcodeproj`，选择共享的 `QuietCast` scheme 和 iPhone 模拟器运行。所有 Swift 模块均在仓库内。

```sh
# 核心 XCTest
Scripts/test.sh

# 只有 Command Line Tools 时的核心用例适配器
Scripts/test-cli.sh

# 工程结构检查
python3 Scripts/check-project.py

# 真正的模拟器构建
Scripts/build-ios.sh

# iOS hosted 测试（需要可用模拟器；参数见脚本）
Scripts/test-ios.sh

# 构建未签名 iPhone IPA：build/QuietCast-unsigned.ipa
Scripts/build-ipa.sh

# 可选：需自行安装 jsonschema 的 JSON Schema 检查
python3 Scripts/validate_rules.py rules/example-fiction.json
```

核心编译后，`.build/debug/quietcast-tools validate <规则文件>` 使用 Swift 加载器验证规则；`score <规则文件> <节目标题> [单集标题]` 展示判定；`smoke-network 科学` 测试真实目录与 RSS，不下载音频。

### 验证状态

1.1.3 开发阶段验证记录：88 项核心测试、115 项 iOS hosted 回归通过，另有家长授权反馈可见性补充回归通过；iPhoneOS Release 编译与最终 IPA 构建记录已核对。见[本版技术与验证记录](Docs/PERFORMANCE_AND_PARENT_FEEDBACK_1.1.3.md)。这些是该版本的历史验证结果，不保证任何新环境都无需配置即可通过。

本版完整真机交互、长时间锁屏播放、所有下载恢复场景与自然自动续签仍需实际验收。更早版本曾完成侧装与保留数据的覆盖安装，不代表 1.1.3 全部场景已经真机验收。

## 目录结构

```text
App/                       SwiftUI 界面、播放器、下载与系统集成
Sources/PodcastModels/     播客领域模型
Sources/PodcastCore/       网络、RSS、持久化、家长安全、搜索记录
Sources/ContentFiltering/  独立过滤模块及规则验证
Sources/QuietCastTools/    规则和网络命令行工具
Tests/                     核心与 iOS hosted 测试
Scripts/                   构建、打包与验证脚本
rules/ schemas/            当前词库、示例和接口契约
research/                  规则研究方法和脚本
datasets/ reports/        公开元数据研究样本和脱敏研究结果
Docs/                      使用手册、架构与历史开发记录
```

`research/`、`datasets/` 和 `reports/` 中的研究资料不能直接当作生产词库；App 实际打包文件为 `App/Resources/content-filter.json`。部分历史文档仍保留早期示例规则与待验阶段描述，当前功能以本 README、使用手册和当前源码为准。

## 共享和隐私

公开仓库以脱敏快照建立新历史，提交使用项目作者身份；原有个人提交历史、个人签名资料、设备验收私密记录、App 沙盒数据、构建目录与 IPA 不上传。研究样本中的节目名、公开发布者名称与公开 feed 属于第三方公开资料，不是使用者个人账号。

公开 RSS／音频／封面请求仍会向 Apple、发布者及其托管商暴露正常网络请求信息，例如 IP 地址。部分公开 RSS 使用 HTTP，不保证传输加密；详见[隐私说明](Docs/PRIVACY_AND_RELEASE.md)。

分享时发送仓库链接，由接收者克隆并使用自己的账户签名。不要分享签名证书、描述文件、Apple 密码、验证码、家长 PIN、真实搜索／收听记录或带个人身份的日志。源码公开可阅读和克隆；本仓库尚未另行授予开源许可证，二次分发与商业使用需另行取得许可，节目内容权利归各发布者。
