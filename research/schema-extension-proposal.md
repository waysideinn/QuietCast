# 给任务 A 的接口变更建议（待确认，未修改现有契约）

2026-10-26；基准仍为 Schema v1.0，commit `9e908672b5ac6afe94a0f6ea4e5d0f31f66b7360`。本文件是建议，不是已经生效的规范；研究 sidecar 不能直接导入 v1。

**后续状态：任务A已在共享目录提供 `schemas/content-filter-v1.1.md` 与兼容Schema。下面保留最初建议作为研究决策记录；正式转换以A的v1.1为准，不采用本文件中的自定义字段。** 已采纳分类精确匹配、账号身份/确认/失效/范围、聚合账号保护和联合评分；v1.1目前仅支持Apple artist稳定ID，不支持直接用Apple channel或喜马拉雅平台账号ID执行封禁。相关发现仍保存研究证据，不塞入错误namespace。

## 为什么不能只增加 author 关键词

- artistName/itunes:author 可为创作者、团队或品牌，不证明法律出版者或账号所有权。Apple artistId 也可能是覆盖多创作者的聚合发布主体。
- v1 showCategories 是拼接文本，无法区分 Apple标准ID、RSS分类层级、Apple推荐专题、主次分类及来源冲突。
- RSS URL host与音频CDN均不代表内容账号；把平台名匹配进 author/rssMetadata 会造成身份误判。
- v1 排除规则只有减分，没有结构化“分类且关键词证据”等条件或显式review账号规则。

## 建议的运行时输入

保留现有内容身份及名单优先级；在新契约版本中增补：

```json
{
  "classificationObservations": [
    {"namespace":"apple.podcasts.genre","id":"1484","label":"Drama","source":"appleLookup","primary":true},
    {"namespace":"rss.itunes.category","path":["Fiction","Drama"],"source":"rss"}
  ],
  "publisherIdentities": [
    {"namespace":"apple.podcasts.artist","id":"694593627","role":"aggregatedProvider","source":"appleLookup","name":"听喜马拉雅"}
  ],
  "creatorClaims": [
    {"name":"RSS/Apple实际作者名称","source":"rss.itunes.author","identityVerified":false}
  ]
}
```

以上 ID 是已观察到的公开值，用于解释角色，**并非封禁列表**。输入应保留 fetchedAt/sourceURL/missing/conflict 等来源；URL/网页发生变更不能让旧身份无期限生效。推荐专题应独立为 `discoveryCollections`（scope=discoveryOnly），不能伪装为 genre。未知字段缺失是unknown，而不是匹配失败等同允许。

## 建议的新规则能力

1. `classificationRules`：id、namespace、exactIDs或exactPaths、matchPrimary/any、action=review/block、score（如走评分）、evidenceRefs。支持精确父子关系；Fiction与其子类一次证据只计一次，不因父+子重复加分。Arts/Books和Stories for Kids不默认封禁。
2. `publisherRules`：id、publisherRef、stableIdentities（namespace/id/role）、name/aliases、action、enabled、confirmation(status=pending/confirmed/rejected, by, at, evidenceRefs)、scope、expiresAt。v1本地文件最大2MiB等边界应继续保留；大量账号可拆分资源但需包级校验。
3. 名称/别名只作发现或review候选；仅name命中不允许直接高置信block。稳定ID也必须有正确角色，未知/托管/CDN/聚合平台不能自动当成纯小说账号。别名作为附属信息，不以多个创作者共享聚合ID来推导同人。
4. `evidencePolicies`：用受限条件枚举组合证据，不引入任意脚本。建议支持 `anyOfSignals`、`allOfSignals`、`minimumDistinctEvidenceFamilies`（publisher/category/keyword），同时去重同一源字段派生的相关证据。不能简单把genre小说与由genre推出来的账号“小说比例”计为两条独立证据。
5. 显式review名单或账号rule action=review。待确认规则只进入review队列，不偷偷转为block；人工确认且enabled才允许block。
6. 输出 evidence 新增 family、namespace、matchedIdentity、role、source、ruleID、contribution、confirmation。稳定ID无数据时报告identityUnavailable。不能因为某规则缺ID而回退到模糊名称强制block。

## 优先级与兼容性

维持：家长单集 > 家长节目 > 词库单集 > 词库节目 > 后续自动证据；自动发布者/分类block不应覆盖更具体的家长allow。已关闭过滤仍allow，必要规则缺失仍遵循A定义的安全回退。显式名单allow不应随意提升成整个发布者allow。

建议提升schemaVersion（最终版本号由A确认），不要在1.0 additionalProperties=false的对象塞新字段。新加载器须明确拒绝未知版本，旧词库可按显式迁移路径默认新数组为空。保留 v1 探索词库原文件不变。本研究先提供 `rules/research/publisher-accounts.research.json` 与分类研究实例；**它们是新能力的证据输入，不是 v1 可加载生产规则**。

## A需要补充的验收

精确分类ID/路径与本地化名称解耦；聚合artistID跨小说与知识节目不自动block；同名不同账号不合并；换托管/CDN不改变内容归属；待确认账号只review；仅分类误标的文学评论可保留/复核；家长单集allow优先；证据去重；丢失账号身份不使用模糊匹配兜底；规则资源大小/版本/重复ID/证据引用/日期范围验证。B提供真实元数据fixtures，A负责实现及Swift一致性测试。
