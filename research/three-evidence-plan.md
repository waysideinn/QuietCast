# 三类证据联合研究预注册补充（2026-10-26）

保留原始采样、版权、限流、人工标签及独立测试要求。此轮新增信息保存为 sidecar，不覆盖首轮语料与规则，不修改 A 的 Schema/工程。首次接口分析发现 v1 缺少结构化分类ID与发布者实体；先交研究实例和兼容性提案，不能把不兼容 sidecar 冒充 v1 可加载词库。

1. **分类证据**：重读已缓存 Apple genreIds；对选定节目用公开 lookup 复查。RSS 精确解析 itunes:category 父子层级，保留多分类及来源差异，不把媒体分类小说等同内容真值。核实 CN grouping/197714、grouping/197716、genre/1483 与 Fiction 三子分类的网页标题和节目链接；网页专题收录只做发现路径，不能据此直接block。Arts/Books、Stories for Kids不等于fiction。
2. **实体证据**：保留 Apple artistId/artistViewUrl/artistName、RSS itunes:author、owner/name（不采email）、copyright、dc:publisher、channel/link及公开主页能确认的账户ID。字段角色分别标注，author不默认为版权方。RSS主机、重定向主机、enclosure主机仅作托管/CDN观察，绝不产生封禁。Apple artistId 可以是平台聚合发布主体，不把同ID下不同创作者名字合并成同人别名。
3. **别名**：Unicode/全半角/繁简/空白归一化仅产生检索名簇，不证明身份；别名合并需要来源证据与人工确认。名称相同、不同平台或账户ID不合并；名称不同而聚合artistId相同也不合并创作者身份。无稳定ID时明确unknown，不拿album/show ID当账号ID。
4. **账号统计**：分别列已采样节目数、人工/AI标签小说数、非虚构数、unknown数和分类命中数。只有真实标签进入小说数量。混合=已观察到正负内容；只有fiction样本叫“观察样本仅小说”，不能宣称纯小说账号。无人工确认的账号规则默认disabled；生产黑名单候选需要稳定ID、角色确认、跨作品覆盖、普通播客反例检查及人工确认。
5. **采样选择**：只使用原开发集内容进行选择和调试。新增公共推荐专题节目单独保留来源并作为开发扩展，不能伪装原独立测试。重取原65档节目及高频名称簇的公开元数据；候选账号再用不同检索词扩样，至少查找名称下的非虚构反例。所有缺失字段、失效、账号枚举上限/目录截断都披露。
6. **预定义对照**：关键词单独（现有v0.2）；分类单独（精确Fiction/三个子类ID或RSS等价路径，诊断性直接block）；发布账号单独（仅人工确认enabled稳定IDblock；其他仅review）；三者OR（诊断性，预期容易误伤）；保守联合（已确认发布账号block或关键词block或分类命中且关键词review→block；其余分类/账号候选/关键词review→review）。未知RSS至少review。目录缺字段不当成否定证据。
7. **测量**：节目和单集独立，review不算召回；分母仅已标注样本，人工与agent结果分开。每策略列召回、误拦、精确率、review、unknown block、分领域误伤。新原型不声称独立准确率；正式评估仍需人工标签、作品族/发布账号隔离和冻结测试。发布账号未知的新账号应另报泛化召回，避免把同账号的训练记忆当泛化能力。

待协商：结构化categoryMatches、publisherMatches、publisher identity provenance、人工确认状态、联合条件和显式review动作。v1 的 author/字符串分类只能作弱证据，不能安全表达这些语义；不把ID塞入 author 或 rssMetadata 来绕过契约。

## A交接v1.1后的补充

共享目录已提供v1.1：新增 classificationRules/publisherRules/recognition。本轮可加载候选采用A的score语义，分类贡献预设4分（单独至review，非单独block），账号未确认只review且0分；原关键词阈值4/10不变。另测allEnabledSources，因为没有确认账号时该模式不能自动拦截，不能把待确认名称伪装有效第三源。原“分类直接block/三者OR/保守联合”保留为诊断策略，明确不等同可加载包。所有调试仍只开发集；独立人工测试未开始。

边界曝光隔离：公开分类页与RSS反例研究中读取了“文化有限”（1482731836），其原哈希预分为test且从未封存。该节目已显式隔离为 `quarantined_original_test_boundary_challenge`（entities/development-overrides.json），只作为已曝光边界挑战，禁止再作独立测试。原始shows.json不覆盖；正式独立测试必须剔除此ID及同作品族/同账号泄漏。其他新增公开推荐页样本是开发扩展，不称独立测试。
