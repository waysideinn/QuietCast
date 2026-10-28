# 实施记录

环境：2026-10-25，macOS arm64，Swift 6.2，仅 Command Line Tools；无 Xcode、iOS SDK、模拟器或已连接测试设备。不能在本机证明 iOS 编译、后台音频、锁屏、实际下载或签名成功。

1. 固定 Schema v1、原生领域模型；真实目录搜索、RSS 解析、网络恢复。
2. 原子本地持久化、订阅与逐集进度；AVPlayer、队列与系统音频集成。
3. 资料库、下载管理及离线文件；所有媒体入口统一授权。
4. Keychain PIN、限流、家长策略、解释式过滤、受保护规则导入。
5. 为任务 B 提供稳定文件接口；目前只有明确标记的样例，正式词库待交接。
6. macOS Swift Package 自动测试、工程结构验证、交付与真机验收表。

最低 iOS 16；不依赖 SwiftData 或第三方包。应用名称「听芽 / QuietCast」，Bundle ID 固定 `org.quietcast.family`。Swift Package 与 App 共用核心源文件，Xcode App target 引用仓库内的本地 PodcastCore package，无远程依赖。

执行结果：阶段 1–4 代码已写入；核心编译与 42 个用例 / 160 条断言通过。阶段 5 的研究候选可加载，正式生产词库待交付。阶段 6 的 iOS 编译、真机与签名验收因缺 Xcode / iOS SDK / 设备尚未执行，详见 VERIFICATION.md。

2026-10-26：在原项目内增加兼容的 Schema v1.1、多来源规则、目录/RSS来源元数据、家长分类继承限制及纯客户端发现系统。72个用例/280条断言通过；官方公开榜单、单集GUID Lookup、真实RSS和发现服务链路已实测。iOS SDK仍缺失，完整App/真机验收继续待环境具备后执行。任务B已收到契约更新通知，生产词库状态不变。
