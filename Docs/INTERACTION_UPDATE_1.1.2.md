# 听芽 1.1.2（5）：提交收起键盘与家长搜索记录

日期：2026-10-27，Asia/Hong_Kong。基于 main 上的 1.1.1（4）＋正式试用词库，不创建新分支。

## 交互

- 探索页点击搜索按钮、键盘 Search／Return 或重新搜索时，结束编辑并收起键盘；结果更新不会主动重新聚焦，下一次点击输入框可正常输入。
- 保留中文组合文字提交读取与请求代次保护；先结束输入，再发起搜索，不等待结果返回才收起键盘。
- 添加 RSS 的“验证并订阅”、家长 PIN 验证、添加屏蔽词、保存 PIN 和播放时间跳转同样结束编辑。RSS 和屏蔽词支持键盘提交。
- 未修改原有列表与底部播放栏的占位布局，原合法滚动终点和末项完整可见回归仍通过。

## 家长搜索记录

入口：设置 → 家长管理 → 验证 PIN → 使用记录 → 搜索记录。

- 从本版升级后开始记录手动提交的非空搜索；包含无结果、网络失败及被过滤的搜索。首页推荐、排行榜与分类后台检索不记入。
- 仅保存在本机 Application Support/search-journal.json，与旧资料库结构独立。没有新账号、服务器或上传接口；没有向儿童搜索框提供历史建议。
- 相同词合并并累计次数，按最近提交排序；合并时规范大小写、全半角及多余空白，保留最近提交的显示文本与时间。
- 最多 200 个不同关键词，每词最多 200 字；超额淘汰最久未提交的词。旧版没有记录的搜索不会凭空补造。
- 左滑可删除单条，右上角清空按钮确认后删除全部；删除后写回磁盘，重启不会恢复旧记录。
- 查看和删除均复核 ParentGrant，PIN 授权过期、锁定或离开前台时沿用既有家长页面锁定机制。记录文件损坏时保留原文件并在家长页报错，家长可明确清空恢复；不会通过记录错误重置 PIN 或关闭过滤。
- 不改变订阅、逐集进度、下载、收藏、家长规则及 Keychain 身份。

## 本轮验证

- 核心 XCTest：87 项，0 失败，build/interaction-1.1.2/core-tests.log。
- iOS hosted XCTest：109 项，0 失败，build/interaction-1.1.2/ios-tests.log。
- iPhoneOS Release 编译和实际 IPA 平台检查通过，build/interaction-1.1.2/release-build.log。
- 新增覆盖：重复词次数／最近排序、200 条上限、单词长度、空白忽略、删除和重新读取、损坏文件不静默覆盖、PIN 过期拒绝查看与删除、记录不进入儿童建议、输入法焦点结束与再次编辑。
- 中文首次 Return 和随后 editingChanged 不取消查询、原搜索／分类／过滤／播放／下载／布局回归继续通过。
- 结果包：build/interaction-1.1.2/Verification.xcresult。家长页截图：build/interaction-1.1.2/screenshots/parent-search-history.png（测试样本）。

运行时为 iOS 27.1 Duo；输入法通过真实 UITextField 焦点和 delegate 验证，未代替 iPhone 上的中文键盘人工操作。本轮未连接手机、操作 Sideloadly 或验证自然自动续签。

## 安装包

- 版本：1.1.2（5）。最低 iOS 16.0；Bundle ID 保持 org.quietcast.family。
- 正式试用词库仍为 fiction-zh-2026-10-27-v1，未改动词库或过滤判定。
- IPA：build/QuietCast-1.1.2-build5-unsigned.ipa。
- ASCII 导入副本：/private/tmp/QuietCast-1.1.2-build5.ipa。
- 源码 commit、词库／IPA 哈希及测试记录：build/interaction-1.1.2/delivery-manifest.json。

使用原 Sideloadly Apple ID／Team／重签 Bundle ID 设置覆盖安装，不先卸载。覆盖后核对版本、订阅、播放进度、下载及家长 PIN 保留，再测试搜索按钮和键盘提交收起、新搜索记录计数及左滑／清空删除。已导入的自定义词库继续保留，不强行覆盖家长选择。
