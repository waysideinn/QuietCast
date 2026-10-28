# 正式试用词库集成 · 听芽 1.1.1（4）

日期：2026-10-27，Asia/Hong_Kong。本次基于人工验收后改版对话的当前工作区，没有回退到早期界面或旧版本。

## 核对与改动

- B 提交 `0db724b947eef5ff9701225ad76c8072d288e867` 已是 HEAD 的祖先，没有重复 cherry-pick 或 merge。
- `rules/fiction-audiobooks.json` 和 `App/Resources/content-filter.json` 已逐字节一致。规则版本 `fiction-zh-2026-10-27-v1`，Schema 1.1，status=production（按用户批准的正式试用标准）。21 个关键词、16 条组合、1 条正则、15 个排除词、1 条分类族规则；没有未确认发布账号黑名单。
- 原 `build/QuietCast-1.1.1-build4-unsigned.ipa` 仍包含旧 example 资源，因此重新构建。原版本化安装包未覆盖，原哈希保持不变；通用 `build/QuietCast-unsigned.ipa` 已更新。
- App、Sources、工程文件及 1.1.1（4）版本号与本次开始时逐文件核对，均未改动。此前改版、性能和验收修复的未提交工作全部保留；没有将它们批量提交。
- 新增一个实际 App Bundle 的内置词库 SHA／版本加载测试。首次整套测试 103 项中有 1 项横屏布局测量失败，截图显示直接跳至 LazyVStack 估算终点产生空视口。将测试改成逐屏滚动并等待终点稳定，保留原末项完整可见和未超拉断言；单项及整套重测通过。没有为使测试通过放行被拦内容、改变页面或关闭过滤。

## 验证

| 检查 | 本轮结果 | 证据 |
| --- | --- | --- |
| 两份词库 JSON Schema | 通过 | Scripts/validate_rules.py |
| 研究自动化测试 | 34 项，0 失败 | build/filter-trial-1.1.1/research-tests.log |
| 已曝光人工案例回归 | 50/50 符合预期 | build/filter-trial-1.1.1/rule-checks/checks.json |
| 当前 Swift 引擎对照 | 162 次，0 差异 | build/filter-trial-1.1.1/rule-parity.log |
| 全部核心 XCTest | 83 项，0 失败 | build/filter-trial-1.1.1/core-tests.log |
| 全部 iOS hosted XCTest | 103 项，0 失败 | build/filter-trial-1.1.1/ios-final.log |
| iPhoneOS Release／IPA 核验 | 通过，arm64、iOS 16 最低版本、audio 配置 | build/filter-trial-1.1.1/release-build.log |

结果包 `build/filter-trial-1.1.1/Final-verification.xcresult`；布局截图与坐标 `build/filter-trial-1.1.1/screenshots/`。本轮包括新词库资源校验及既有搜索、布局、播放进度、下载／离线、PIN、父子分类和各入口权限回归。iOS 运行时为 27.1 Duo，较小尺寸是 hosted 视口检查，不代替这些机型或 iOS 16 的真机测试。

## 新安装包

- 版本：**1.1.1（4）**；Bundle ID：`org.quietcast.family`。
- 项目 IPA：`build/QuietCast-1.1.1-build4-fiction-v1-unsigned.ipa`。
- ASCII 导入副本：`/private/tmp/QuietCast-1.1.1-build4-fiction-v1.ipa`。
- IPA SHA256：`4714ac6f463ae10e669a1b52467cf8507d634eb75f98b187097dbf1fc88a952a`。
- 内置词库 SHA256：`b1d875e5b49415f74c111389f0ec1b3c189abc37cdc547dd5c21e18d3393d765`。
- 来源与完整源码文件哈希：`build/filter-trial-1.1.1/delivery-manifest.json`。来源 commit 是 B 提交；当前未提交的改版代码由逐文件哈希标明，不能仅用 commit 重现此 IPA。

该文件为无签名 IPA，需要沿用现有 Sideloadly Apple ID、Team 和实际重签 Bundle ID 设置覆盖，不能先卸载。版本号与旧包相同，用文件名中的 `fiction-v1` 及词库版本识别本轮产物。

## 覆盖安装后最少核对

1. 确认订阅、收藏、逐集进度、下载及家长 PIN 仍保留。
2. 设置 → 家长管理 → 输入 PIN → 规则文件，核对版本为 `fiction-zh-2026-10-27-v1`。
3. 如果以前导入过自定义词库，它会继续优先使用；请在同一页面使用“从本地 JSON 导入并验证”导入 `rules/fiction-audiobooks.json`。本轮不覆盖家长自己的导入包，当前界面没有“恢复内置规则”按钮，不能按旧研究文档假定该按钮存在。
4. 确认已启用过滤及“网络小说及有声书”类别，实际检查一个小说节目和一个正常访谈；已有允许／禁止名单仍优先。
5. 检查新规则对已下载、播放队列、历史及自动下一集的约束。本轮未连接手机或操作 Sideloadly，不把模拟器结果写为真机安装／锁屏／自动续签通过。

这是用户批准的正式试用词库，不是独立准确率认证；沿用 B 的已知误拦／漏拦说明，混合节目可由家长单集／节目例外纠正。后续是否升级版本号交由下一次产品改动决定，本轮保持用户指定的 1.1.1（4）。

## 统一到 main（用户追加要求）

经 `git branch -avv` 与 `git worktree list` 核对，只有 `main` 和当前一个工作目录，没有其他分支需要合并。按用户要求将此前改版、性能修复、验收回归与本次词库打包测试统一提交到 main；保留 Git 历史供回滚，不创建额外开发分支。

本次滚动修改仅在 `Tests/iOSVerification/UIRedesignTests.swift` 的 `restAtBottom` 测试辅助函数中：从直接跳至估算终点改为逐屏移动并等待三次稳定。`assertLastItemVisible` 的视口／末项／播放条位置断言及合法终点断言没有放宽。App/Views/RootView.swift 的实际占位和裁剪、App/Views/HomeView.swift 的内容布局、节目详情等全部 App 与 Sources 文件，均与 1.1.1（4）改版交付基线逐文件哈希一致，因此没有撤销或重做上次“列表滑到底后被播放栏遮挡”的修复。
