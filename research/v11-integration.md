# v1.1研究候选集成说明

以任务A当前 `schemas/content-filter-v1.1.md` 和 `schemas/content-filter.schema.json` 为唯一契约。本研究未修改它们。初版Schema仍通过被冻结的content-filter.v1.0.schema.json核对原提交，原词库文件保留。

最终对齐提交：`b62212bdf9b36f0f90e2f7f3a8f0990bba6544b9`（已经在当前main，无需cherry-pick）。补充语义已映射研究评分器：有效confirmed账号score/block限制下缺新鲜稳定身份→review；pending/review本身不全局升级未知账号；结构化分类/有效账号命中时清除showCategories/author同源关键词分。现有候选没有confirmed账号，两个派生字段权重也为0，因此这次契约收尾不改变当前消融结果。App家长分类限制属于独立家长策略，本研究的空家长策略对照不代替其验收。

- 完整候选：`rules/research/fiction-multisource-candidate.json`，schemaVersion=1.1、status=example、category id=fiction-audiobooks。
- 账号独立候选包：`rules/research/publisher-accounts.json`，同一Schema和类别，recognition只开publishers。可由同一加载器导入，但导入会替换整包，不要把仅账号包当成含关键词/分类的完整包。
- 深度注册表：`publisher-accounts.research.json`，供核对证据/标注，不作为App导入。
- 分类配置：一个Fiction族规则score=4，精确IDs/名称/路径，普通Books和grouping不匹配。父子及目录/RSS匹配不重复加分。
- 账号配置：所有confirmation=pending；4个已有多档小说判读的显示名簇启用review候选，贡献0分。聚合artist主体及其他待研究规则disabled，没有账号block。名称保持标点，不能模糊contains。

元数据适配实例见 `datasets/fiction_research/entities/engine-fixtures.json`：classificationObservations与publisherIdentities带namespace/source/sourceURL/observedAt，缺ID为null，目录/RSS并列保留。Apple artistName初始role=unknown；版权声明不自动升级publisher身份。所有日期按来源记录，运行时按metadataMaxAgeDays执行。

验证命令（仓库根目录）：

```sh
python3 research/scripts/collect_entities.py --rss-limit 160
python3 research/scripts/enrich_accounts.py --rss-limit 50
python3 research/scripts/analyze_entities.py
python3 research/scripts/build_multisource.py
python3 research/scripts/ablate.py
python3 research/scripts/swift_multisource_parity.py
python3 -m unittest discover -s research/scripts -p 'test_*.py'
python3 research/scripts/qa_entities.py
python3 research/scripts/report_multisource.py
```

build_multisource会更新候选确认记录时间/失效日，因此重建后必须重跑ablate和Swift对照，不能沿用旧SHA的结果。Swift probe只在临时目录编译现有模块，不写App、Sources、Tests、根Package或Schema；如果A源码并发变化，编译会拒绝该次结果，稍后重试。对照覆盖当前单一内容类别和空家长策略，不能代替A完整权限/播放测试。

完整结果见reports/fiction_research/multisource-report.md。独立测试未封存、人工金标准未完成，禁止把开发结果当发布指标。尤其不要默认采用allEnabledSources：没有确认账号时它会取消自动评分，必须看消融实测。正式生产提升需在新独立样本达标后决定。
