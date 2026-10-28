# 共享接口 v1.1：分类、发布账号、关键词

2026-10-26。当前 `content-filter.schema.json` 同时验证 v1.0 与 v1.1；旧契约完整保存在 `content-filter.v1.0.schema.json`。旧文件不必改动，加载器对新字段缺失采用默认值；新文件须明确 `schemaVersion: "1.1"`，不能把新字段放进 v1.0。原评分、家长名单和安全回退优先级不变。

## 每个内容类别新增三个可选字段

- `recognition`：`appleCategories`、`publishers`、`keywords` 各自布尔；`combination` 为 `score` 或 `allEnabledSources`；`metadataMaxAgeDays` 为 1–365 整数。整体省略时默认三个来源开启、score、30 天。家长 UI 仍只控制内容类别；这些是词库研究配置。
- `classificationRules`：数组。每条有 id/enabled/match/action/score/note/sources。match 为 `ids`（Apple genre ID）、`names`（标准分类精确名称及显式本地化别名）、`paths`（精确层级数组）、`primaryOnly`。三个列表之间 OR，至少一个非空；不做模糊 contains，不用“小说”去匹配“小说研究”。ID 只匹配 `apple.podcasts.genre` 观察；名称/路径只匹配 Apple 目录或 RSS itunes 分类，普通 RSS category 不冒充标准分类。父+子命中同一条规则只计一次。多个规则的相关分类证据只取最高分，避免重复累加。
- `publisherRules`：id/enabled/identities/names/role/scope/showIDs/action/score/confirmation/expiresAt/note。稳定身份当前支持 `{"namespace":"apple.podcasts.artist","id":"..."}`，不能填 feed host、CDN、节目 ID 或作者名字。role 为 publisher/creator/aggregator/unknown；scope 为 allShows/selectedShows，后者必须有 showIDs，前者必须空数组。混合/聚合账号只可对 selectedShows 作高置信判定；聚合或未知角色的 allShows 规则只能 review。names 是精确名称/别名线索；名称独自命中、稳定 ID 缺失或过时不能 fallback 成 block。

所有新规则 action 为 score/review/block。confirmation 有 status（pending/confirmed/rejected）、by、at（ISO8601）、evidence（非空来源数组）。confirmed + 正确稳定 ID + 角色合法 + 未过期，才能执行 publisher score/block；pending 或只有名字只产生 review（0 分，不满足联合判定的 publisher 信号），rejected/expired/disabled 完全不参与。confirmed 不能缺 identities；确认日期不能晚于失效日期；运行时也检查未来确认日期。多个相同账号的 publisher 证据仅取最高贡献分。

## 联合判断

score 模式：`旧关键词净分 + 分类来源最高贡献 + 发布账号来源最高贡献`，再使用原 review/block 阈值。action=review 强制至少 review，但不加分；action=block 强制 block（仍受家长例外优先级约束）。普通 score 证据贡献为规则分数，不再乘旧字段权重。pending/name-only 证据只能独立提示 review，不参与分数或多来源联合门槛。

allEnabledSources 模式：只有 recognition 中开启的每个来源都存在有效正向信号时，才应用上述自动分数/直接 block。未齐全不会仅凭一个来源 block；有待确认/过期身份提示时仍可 review。关键词来源的正向信号指排除后净分 > 0。该模式没有开启任何来源时不做自动拦截。家长显式自定义词、家长/词库节目与单集名单不受此门槛影响。

元数据缺失不是账户身份匹配：只有实际观察到的字段才能匹配；不臆造账号、不根据托管域名归属账号。相关身份仅有名称线索/匹配到过期观察时，输出 review 和 identityUnavailable/staleMetadata。没有任何相关线索时不假装命中账号。规则未加载/启用类别缺失仍按原契约安全封锁。规则的 metadataMaxAgeDays 只限制分类/账号观察；旧 v1 关键词语义不变。

## 输入、解释和保存

Podcast 保留旧 author/categories，增加可缺省的 `classificationObservations` 和 `publisherIdentities`，每条保存来源、sourceURL 与 observedAt。分类 namespace: apple.podcasts.genre / rss.itunes.category / rss.category；含 id/name/path/primary。发布身份 namespace: apple.podcasts.artist / rss.itunes.author / rss.managingEditor / rss.dc.creator / rss.itunes.owner / rss.publisher；含 id（可空）、name、role。Apple artistName 是平台提供的显示名，初始 role=unknown；RSS author/owner/publisher 是声明，不代表已证实的法律出版者。

目录与 RSS 元数据分别保留，刷新 RSS 不丢失 artistId/genreIds，不把 RSS author 覆盖成目录作者；观察有时效，不无期限提升旧账号匹配。旧 library.json 缺新字段也可读取。

RuleEvidence 保留原字段，新增可选 family（appleCategories/publishers/keywords）、namespace、matchedIdentity、source、sourceURL、role、confirmation。原因展示区应显示这些信息。pending/name-only/missing identity 与真正账号封禁必须可区分。来源的“确认”描述规则研究状态，不声称 RSS 自报账号已经认证。

## 给任务 B

以 `rules/example-multisource.json` 为结构范本，补充真实 classificationRules / publisherRules；保留旧关键词规则及字段，按内容类别配置识别策略。不得将聚合平台账号整体当小说发布者。不要把研究 sidecar 直接塞入导入器；先转换为本契约，再运行 Schema 和 Swift 验证。所有生产账号需有身份、证据、确认和失效日期，混合账号须列出具体节目 ID。没有足够证据时继续标 example/pending，不能伪装 production。

发现页使用公开榜单、目录检索和自有正向选题（访谈、科学、历史、新闻、人文、技术）；明确区分官方公开榜单、本地推荐和目录发现，不声称取得苹果编辑精选。所有候选经相同引擎，发现/分类只展示 allow。没有复制有声书、网络文学或小说栏目。分类和作者都是元数据线索，不能保证听到的实际音频完全符合标签。

## 补充安全与去重语义

启用了当前有效、已确认的 publisher score/block 限制，而节目没有新鲜稳定账号身份时，整体进入 review（identityUnavailable），不假装命中某个账号，也不因未知身份而默认允许 RSS 导入。只有 review/pending 规则时不会把所有未知账号提升为复核。旧 v1.0 没有发布账号规则时保持原语义。

结构化分类证据已经命中时，不再把同一 showCategories 文本计成关键词证据；有效发布账号证据已经命中时，同理移除 author 派生分，避免同源重复加分。没有新来源规则的旧 v1.0 文件仍按原字段权重计算。

## 家长直接禁用分类

家长策略新增可缺省 blockedAppleCategories（标准分类 ID 集合，旧版缺省为空）。完整标准分类树与中繁体目录别名用于父子继承；父类禁用隐藏全部子类，子类禁用不影响父类与兄弟类。该策略在家长具体节目/单集例外之后、词库名单及自动来源之前执行。所有发现、榜单、分类、搜索和媒体执行入口共用；分类入口本身不因个别节目 allow 而重新显示。家长只需内容类别开关及单独的分类限制页面，不暴露三种信号的复杂联合配置。
