> Production trial update (2026-10-27): explicitly accepted by the user without an independent-accuracy release gate. The production rules/fiction-audiobooks.json is installed as App/Resources/content-filter.json. See [current delivery report](reports/fiction_research/release/production-trial/report.md). Earlier status below is historical.

> 2026-10-27进展：已新增50档真实人工元数据复核。冻结规则已完成首轮比较，但账号/作品族独立性未认证，仍不发布生产包。最新数据与错误见 [首轮人工复核报告](reports/fiction_research/release/human-pilot/report.md)。以下为2026-10-26交付时的历史状态。

# 正式词库发布审计与交付结果

**结果：证据门禁未通过，未发布正式默认规则包。** 遵循用户“证据不足明确未完成，不强行启用”的要求，保留研究候选，不把example重命名production，不改App默认资源。

## 正式规则位置与状态

- 正式规则文件：**未生成**。发布状态和缺口见本目录release-readiness.json；该文件是审计清单，不是App规则包。
- v1.1兼容研究候选仍为rules/research/fiction-multisource-candidate.json，status=example。独立账号候选publisher-accounts.json同样不是生产词库。
- 契约对齐任务A提交b62212bdf9b36f0f90e2f7f3a8f0990bba6544b9；原1.0 Schema仍冻结保留。

## 实际样本、账号、词条数量

原始真实Apple搜索候选 **2943档**，成功解析RSS **861档**，单集摘要 **6416条**。本轮多源观察与该语料重叠，不累加冒充新样本。检索候选并非人工判定的中文小说/正常节目数量，目录并不覆盖所有中文播客。

权威标签文件合计 **112条AI元数据判读，0条人工标签**。derived fixtures中重复存储的标签不计成新样本。没有发现额外人工标注文件。

已确认可进入默认黑名单的发布账号 **0个**。201条研究账号记录逐条审计，195个是名称簇，6个是Apple artist身份记录；确认状态均pending，不能借稳定artist记录就封禁整个品牌。喜马拉雅聚合身份和综合名称簇的正常内容反例均保留；publisher-eligibility.json记录逐条排除原因。

| 类型 | 研究候选 | 正式启用 |
|---|---:|---:|
| 普通关键词 | 19 | 0 |
| 组合规则 | 14 | 0 |
| 强关键词 | 0 | 0 |
| 章节正则 / 排除 / 分类族 | 1 / 12 / 1 | 0 |
| 已确认账号block | 0 | 0 |

格式与执行逻辑通过不等于内容区分能力已经验证。这些候选分数仍基于小规模AI开发判读，不能直接变为儿童App的生产默认包。

## 独立测试与实际指标

**人工独立测试未完成：节目级、单集级的召回、误拦、精确率、review均未测量，JSON为null，不能写成0%误拦或独立准确率。** 没有将review算入自动拦截。

已准备 221档节目、435个单集的盲标任务，共656项。来自原test候选的成功RSS，排除了已曝光样本以及开发集已有显示名称。候选SHA、RSS、节目和盲标包SHA已固定，模型尚未对这批队列评分。真实账号、作品族、语言范围审计仍pending，故不能宣称独立性已通过。

盲标包与空白标签模板位于datasets/fiction_research/release/；规则或语料变化会触发快照不一致。已曝光的文化有限被隔离，不能重新作为独立测试。旧开发案例即使由人复核，也不能直接冒充新的独立测试。

以下仅披露已有AI开发判读结果，供识别失败类型，**不是发布指标**：

| v1.1联合候选 | 节目级 | 单集级 |
|---|---:|---:|
| 小说自动block召回 | 32/48 = 66.7% | 4/4 = 100.0% |
| 非虚构误block率 | 0/43 = 0.0% | 2/4 = 50.0% |
| review比例 | 19/103 = 18.4% | 0/9 = 0.0% |

开发集有103档节目（48小说、43非虚构、12 uncertain）与9个独立判读单集。节目级0/43误拦不证明总体≤3%；单集仅4个正常案例，其中2个误拦，当前候选明显还不适合宣称生产可靠。详细置信区间、访谈/科学/课程/文学评论分组及错误见ablation-results.json和multisource-report.md。

## 测试执行结果

- Python研究/评分/发布证据门禁：**29项通过**。包含拒绝把AI标签改状态当人工金标准、未审计测试不独立、pending稳定ID不能默认block。
- A同用例CLI核心测试：**72用例、280断言、0失败**。临时目录复用A的测试函数和适配器，不改App/源代码。
- 实际Swift加载/评分对照：**784次，0差异**；所有结果绑定规则与源码SHA。
- 4个App格式候选包通过Schema校验；研究注册表作为sidecar，不冒充App规则文件。
- 标准swift test：已尝试，因本机Command Line Tools缺少XCTest模块失败。失败日志为swift-tests.log；CLI通过不是XCTest通过，也不是iOS真机验收。

## 仍不能可靠识别的内容

- 只用书名、不写小说/演播、简介不足且分类错误的连载。
- 知识教育包装的虚构童话，或推广赏析/欢迎评论措辞掩盖全文演播。
- 文学评论与作品朗读、真实案件与纪实改编剧、传记与传记小说的混合边界。
- 小说节目中的科普答疑/书序等非虚构单集；继承节目证据会误伤。
- 改名、转移、缺失稳定身份、混合发布主体及不完整账号目录；托管商/CDN不能替代账号身份。
- metadata与实际音频不符的内容；第一版没有语音识别或语义模型，无法验证声音本体。

## 未完成项与提交范围

人工标注目标（300小说、300正常、150边界）尚未达到；独立性审计、正式独立测试、账号身份与内容类型确认、生产默认规则导出未完成。剩余工作不能靠重命名JSON或放宽门禁补齐。

本轮提交保留research/、datasets/、reports/、rules/research/的采样、证据、脚本、候选、失败日志及盲标材料；不提交或覆盖其他任务正在修改的App/构建脚本。完整Git提交ID由交付回复提供。
