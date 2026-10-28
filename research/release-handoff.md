> Production trial update (2026-10-27): explicitly accepted by the user without an independent-accuracy release gate. The production rules/fiction-audiobooks.json is installed as App/Resources/content-filter.json. See [current delivery report](reports/fiction_research/release/production-trial/report.md). Earlier status below is historical.

> 2026-10-27进展：已新增50档真实人工元数据复核。冻结规则已完成首轮比较，但账号/作品族独立性未认证，仍不发布生产包。最新数据与错误见 [首轮人工复核报告](reports/fiction_research/release/human-pilot/report.md)。以下为2026-10-26交付时的历史状态。

# 正式发布阶段交接：证据不足，未发布生产包

本轮按用户要求8执行：不把example改名production，不用未验证账号充当默认黑名单。没有修改App、Sources、Tests、Schema或任务A的构建脚本。研究数据和脚本将单独提交Git。

## 当前可核对状态

- 真实候选2943档；原始成功RSS861档、6416个单集摘要。实体/分类补采与原始语料重叠，不能相加冒充新节目。
- 权威标签来自labels.json和entities/labels-additions.json，共112条AI元数据判读；human标签为0。derived fixtures中的重复记录不另计样本。
- 当前v1.1研究候选：19个普通关键词、14条组合、1条弱章节正则、12条排除、1条分类族规则、201条账号研究记录。strongKeywords为空。4条名称簇只提示review，没有已确认账号默认block。
- 已标注开发集103档节目（48 fiction、43 nonfiction、12 uncertain）及9个单集。它们不是独立测试，更不是人工金标准。
- 正式规则文件不存在，正式词条/账号黑名单均为0。候选仍在rules/research/，不替换App默认资源。

## 本轮准备的可复核材料

`datasets/fiction_research/release/holdout-preparation.json` 固定候选规则SHA、RSS与节目元数据SHA。筛出221档带RSS、未标注且与开发集显示名无交集的原test候选，形成221个节目和435个单集的盲标任务。

`blind-holdout-tasks.json` 不带查询词、分类、账号簇、预测分或预测结果；`human-labels.template.json` 是待填写模板；`human-labels.json` 目前为空。名称无交集并不等于真实账号或作品族独立，`independence-audit.json` 必须先完成作品族、账号和语言审计，当前仍pending。已经曝光的文化有限被排除，不能重回独立测试。

此批是**待审计、待人工标注的测试准备集**，不是已完成的独立测试集。没有运行它的模型预测来调参。候选或语料变化会触发快照不一致；不得为了获得漂亮指标而覆盖旧快照。

## 后续人工输入

逐项复核后，在human-labels.json提交真实标签及annotator/labeled_at/rationale/family_id/account_group_id；source只能真实填写human，不能把AI标签改字段充数。所有单集独立判断，不继承节目标签。作品/账号泄漏、外语、无足够证据等应在评分之前处理并记录；不能在看到模型错误之后挑选删除样本。

完成独立性审计和人工标注后，才能进行冻结规则的正式评分，报告block召回、非虚构误block和review，另列unknown block、领域分组、误判清单和置信区间。release_audit.py只审计证据，不会凭填入标签/切换状态伪造预测或自动发布。

## 复现与校验

```sh
python3 research/scripts/release_audit.py
python3 -m unittest discover -s research/scripts -p 'test_*.py'
python3 research/scripts/run_core_tests.py
python3 Scripts/validate_rules.py rules/research/fiction-multisource-candidate.json rules/research/publisher-accounts.json
python3 research/scripts/swift_multisource_parity.py
python3 research/scripts/qa_entities.py
```

标准swift test在当前Command Line Tools环境缺XCTest，失败日志保留，不标通过。run_core_tests在临时目录复用A的相同测试函数和CLI断言适配器，避免写A的工程目录。完整iOS SDK/真机测试仍需适当环境。

最终状态与指标见reports/fiction_research/release/final-delivery.md及release-readiness.json。
