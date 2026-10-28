# 任务 A / B 共享规则接口

当前扩展为 **v1.1**，详见 [v1.1 接口](content-filter-v1.1.md) 与 [变更记录](CHANGELOG.md)。当前 Schema 同时接受旧 v1.0 和新 v1.1；原始 Schema 另存为 `content-filter.v1.0.schema.json`。以下保留 v1.0 基础契约，新能力不改变旧文件语义。

## v1.0 基础契约

固定文件：`schemas/content-filter.schema.json`（JSON Schema draft 2020-12）；样例：`rules/example-fiction.json`。UTF-8 JSON，最大 2 MiB。`schemaVersion` 固定 `1.0`，`ruleVersion` 是每次词库发布的新版本字符串。结构变化必须记录迁移与变更，不得悄悄变更 v1 语义。当前样例 `status=example`，不能当作已完成的生产词库。

## 任务 B 的交付

按 Schema 提供完整 JSON；保留类别 ID `fiction-audiobooks`。正式词库标记 `status=production`，填写日期、来源、规则 ID 和 note；附正常访谈/知识讲述与小说类的正反例。每个类别所有数组都必须提供，无数据用 `[]`。字段不允许额外属性。规则 ID 在类别内全局唯一，类别 ID 全局唯一；`0 < review < block`；词条经规范化后不能为空，组合词不能重复。这些跨字段约束由加载器额外验证。

把正式文件替换为 `App/Resources/content-filter.json` 后即可构建；也可由 App 家长管理导入，不需要修改搜索或播放器。任务 A 不自行把演示词升级为生产词。该目录的 Schema 是唯一契约，App 内置文件是它的实例。

## 输入与匹配

可匹配字段：`showTitle`、`showDescription`、`showCategories`、`author`、`episodeTitle`、`episodeDescription`、`rssMetadata`。分类以换行拼接，RSS 元数据包含 itunes:type、explicit、keywords、language、podcast:medium 等。HTML 先提取纯文本；统一 Unicode/全半角、繁转简、小写并移除空白/标点。正则匹配同样的规范化文本，因此不要依赖原始标点/空白。字段最多取 20,000 个字符。

每条规则每个内容只计分一次：`score × 命中字段中的最高 fieldWeight`；重复出现和多个字段命中不重复加分。强特征分 S、普通关键词/组合/正则分 N、排除分 E 分开累计，最终为 `S + max(0, N − E)`。排除词不能抵扣强特征。组合 `sameField` 要求所有词出现在同一字段；`anyField` 允许跨字段，权重取各词命中最大权重中的最小值。分数 ≥ block 为 block，否则 ≥ review 为 review，否则 allow；多个启用类别取最严格结果。没有词库的类别不能显示为可用。

`enabled` 是词库提供方默认可用状态；家长启用的类别与此取交集。家长自定义词是明确屏蔽意图，命中直接 block；无需把普通词条做成单词封锁策略。

正则采用受限 ICU 子集：禁止分组、分支 `|`、反向引用、前后查找、`* + ?` 和无界量词；最多一个 `{m}` / `{m,n}`，且 `0 ≤ m ≤ n ≤ 64`。允许字符集、锚点、点和 `\d \w \s`（及其大写反义）。加载器必须拒绝其他转义和复杂正则，以免导入词库引入灾难回溯。Schema 只约束字符串，安全语法由加载器检查。

## 身份与优先级

节目 ID = RSS URL 的规范形式（scheme/host 小写、去 fragment，保留 path/query）。同一 RSS 的目录/手动导入身份一致；不同别名 URL 不会自动合并。单集 ID = 小写十六进制 SHA-256(`节目ID + "\n" + RSS guid`)，缺 guid 用 enclosure URL。未知准确 ID 时请留空黑白名单，不要填标题。

过滤关闭 → allow。过滤开启但规则加载失败/选中类别缺失 → block（明确安全回退）。其他优先级：家长单集规则 > 家长节目规则 > 词库单集名单 > 词库节目名单 > 自定义屏蔽词 > 自动评分。同一层级 block 优先；更具体的单集 allow 可以覆盖节目 block。词库名单只在启用类别内生效；家长规则跨类别有效。任意类别的同层 block 胜过其他类别 allow。节目未取得 RSS 完整元数据时自动判定至少 review，需先加载 RSS，不能仅凭目录标题授予播放权。

输出包含 decision (`allow/block/review`)、categoryIDs、evidence（ruleID、kind、字段、词/表达式、贡献分）、score、ruleVersion、reason。规则更新后重新计算，不能永久缓存旧的 allow。搜索隐藏 block，播放/下载/订阅/队列/历史/RSS/外链/自动下一集全部在执行时再授权。review 需要家长 PIN 设置单集或节目例外。

## 验证

用支持 draft 2020-12 的 JSON Schema validator 验证（例如 `python3 Scripts/validate_rules.py rules/example-fiction.json`；依赖 jsonschema），并运行 `swift test --disable-sandbox` 的加载器/语义测试。Task B 不需要运行 iOS 工程。后续实现不得与此文件冲突；若发现契约不足，先记录兼容性变更。
