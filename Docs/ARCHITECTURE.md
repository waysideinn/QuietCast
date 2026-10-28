# 架构、过滤解释与维护约定

SwiftUI UI → MainActor AppStore → PodcastCore；独立的 ContentFiltering target 仅依赖 PodcastModels，不依赖播放器、UI 或网络。PodcastCore 重导出这两个原生模块供 App 使用。AppStore 是业务入口，重新读取当前节目、单集、策略和词库后授权；AVPlayer 的 load/resume/seek、自动下一集、下载 start/finish 另行复核。搜索中的可见性不授予播放权。历史、收藏、队列、订阅、下载列表均根据当前结果重新筛选。

## ContentFiltering

`RulesProvider` 提供 bytes；`RulesRepository` 负责加载及验证后替换，接口可以增加远程 Provider；本版没有联网更新词库。`RulesLoader` 严格检查属性、类型、语义、重复 ID、阈值及有限正则语法。`ContentFilter` 是无 IO、可测试的纯判定器。`AccessGate` 为入口枚举统一判定；AppStore 的 UI 授权包装调用同一 ContentFilter 以记录解释和显示 PIN 界面。

结构、评分公式、字段权重、繁简归一化、排除规则和优先级以共享接口文档为准；不在业务代码中存放小说关键词。规则编译/导入失败，不把自动过滤改成关闭。已启用过滤但缺规则、缺启用类别或 Keychain 读取失败时全部阻止；后者连普通 allow 例外也不放行。家长可恢复有效规则；Keychain 可在设备解锁后重试。

节目目录信息常常没有简介，先标 review，进入详情加载 RSS。自动词条按每条最强匹配字段计一次，普通词低分不等于封禁。家长自定义关键词是明确的阻止意图，可以直接 block。例外按单集优先于节目、同层 deny 优先；家长例外高于自动词库名单。更新词库/家长策略/已加载 RSS 后，立即校验当前音频、清理失效队列、暂停失效下载。已完成下载可以继续留在设备，但没有授权不能显示或播放。

判定解释返回类别、证据规则/字段、贡献、总分、版本与原因。各类别分开评分，总分显示最大类别分，不把不同类别分数混加。元数据缺失的 review 在完整 RSS 到来后重新计算。过滤不监听音频，不能承诺过滤所有没有标题/简介线索的故事。

## PIN 与安全边界

Security/Keychain (`AfterFirstUnlockThisDeviceOnly`) 存储一份完整安全记录。随机 32 byte salt、PBKDF2-HMAC-SHA256 210,000 次、32 byte verifier，等时字节比较。默认 PIN 6–12 位数字。前 4 次失败记录计数，第 5 次后延迟 30 秒，随后指数增加最多 1 小时。失败状态持久化，重启 App 不清除。授权能力令牌只能由成功验证/初始设置产生，两分钟过期；离开前台即作废，所有写策略接口检查令牌。没有公开 reset/delete PIN 方法。

家长页面验证后才能查看词库、规则、例外及日志；每秒检查过期并重建导航栈，防止停留在已打开的家长子页面。普通设置仅允许播放偏好。忘记 PIN 无恢复入口，设置时明确告知记录 PIN；不要给出“清空偏好设置恢复”的绕过方式。

这是应用级限制。无法替代 iOS Screen Time、阻止其他 App 播放或对抗越狱/重新签不同身份/设备级密钥删除。覆盖安装要保持 Bundle ID 与 Team 一致，否则原 Keychain 访问可能不同；不保证卸载再安装能重置或恢复 PIN。

## 持久化、播放和下载

核心模型 Codable，schemaVersion=1，私有 Application Support，原子替换写入；发现损坏文件保留原文件并锁定写入，不静默创建空库。订阅刷新只合并节目/单集，保留进度、收藏和历史；当前不会主动删除 RSS 中消失的旧单集。每集身份为 feed ID + GUID 的 SHA256；缺 GUID 用 enclosure URL。不自动把不同 RSS 别名合并，否则会影响例外稳定性。

AVPlayer 在切换前保存旧集；观察器同时捕获单集 ID 与代次，旧集 KVO、seek completion 和结束事件不能写新集。初始进度 seek 完成前不保存 AVPlayer 的临时 0；每 10 秒及生命周期节点保存，强杀最多可能损失上次检查点之后的约 10 秒。达到 98% 或自然结束标记已完成；显式“未播放”重置完成/位置。

音频会话 `.playback / .spokenAudio / .longFormAudio`，只在用户播放时激活；中断开始保存，只有先前确实要播放、系统允许恢复且当前内容仍获准时恢复；耳机断开暂停，媒体服务重置重建播放器并要求手动恢复。Now Playing + Remote Commands 覆盖耳机、锁屏、进度、前后曲和跳秒。AirPlay 使用系统 route picker。

下载使用固定 ID 的后台 URLSession；任务 description 绑定单集 ID、重连现有任务、保存可用 resume data。暂停通过 cancel(byProducingResumeData)，服务器不支持恢复时允许从头重下，不能承诺每个源都可断点续传。下载完成先移入暂存文件，再在主 actor 重新验证当前权限，落盘后更新清单。单集最多 1 GB，设置限制总容量，用户可删除或清理已完成的单集（跳过当前播放文件）。断网播放只使用私有已完成文件，并依然验证当前内容权限。系统临时下载缓存不计入页面显示的已完成/恢复文件容量。

## 后续维护重点

先安装 Xcode 跑实际 App 编译并解决 SDK 才能发现的类型/可用性问题，再完成真机矩阵；不要把语法检查当构建成功。接入 B 正式词库之前，对其真实语料跑 Swift/Python 引擎一致性检查，确认误拦截、漏拦截、阈值。后续可加入 OPML、增量刷新、历史归档、元数据审计、UI 测试、share extension；远程家长管理通过 RulesProvider 和家长授权接口扩展，而非在播放器里添加旁路。

## 2026-10-26 扩展

规则 v1.1 向后兼容 v1.0，三种识别来源与解释字段见 schemas/content-filter-v1.1.md。发布账号只认公开目录稳定身份和经确认的规则，不把托管/CDN当账号；未知身份在有效账号限制下进入复核。标准分类树和家长分类禁用在所有入口继承执行。

纯客户端发现由 DiscoveryService / PublicChartsClient / LocalRecommender / DiscoveryPresentation 实现，见 DISCOVERY.md。真实榜单与目录补充不混淆来源；按日缓存更新、失败保留、展示和执行均重新过滤。RSS/目录来源分别保存，旧缓存不能覆盖新的 RSS，旧模型字段可缺省。播放开始事件记录本地次数，原有进度恢复保持。
