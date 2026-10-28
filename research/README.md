# 任务 B：中文小说音频过滤研究

**正式交付审计：见 `research/release-handoff.md` 和 `reports/fiction_research/release/final-delivery.md`。现有0条人工标签，发布门禁未通过，没有生产包；不要把候选或盲标准备集当成正式词库/独立测试。**

**2026-10-26更新：已扩展分类/发布账号/关键词三源。最新结果见 `reports/fiction_research/multisource-report.md`，v1.1可加载候选与复现步骤见 `research/v11-integration.md`。以下保留首轮v1.0研究说明，非当前生产验收结论。**

所有新增内容位于研究目录；未修改任务 A 的 App、Schema、演示词库或脚本。Schema 基准提交为 `9e908672b5ac6afe94a0f6ea4e5d0f31f66b7360`。

## 重现

从仓库根目录运行（Python 3.9+；jsonschema；macOS 使用系统 CoreFoundation 繁简转换，其他系统另需 opencc-python-reimplemented；跨平台归一化差异必须做 Swift 对照）：

```sh
python3 research/scripts/collect.py search --countries cn,tw
python3 research/scripts/collect.py normalize
python3 research/scripts/collect.py rss --limit-shows 1000
python3 research/scripts/prepare_labels.py
python3 research/scripts/analyze.py
python3 research/scripts/build_rules.py
python3 research/scripts/validate.py --split dev
python3 research/scripts/summarize.py
python3 -m unittest discover -s research/scripts -p 'test_*.py'
python3 Scripts/validate_rules.py rules/research/fiction-candidate.json
python3 research/scripts/check_contract.py
python3 research/scripts/swift_parity.py
python3 research/scripts/qa.py
python3 research/scripts/report.py
```

采集可中断重启，已有搜索和 RSS 文件跳过；错误 RSS 也保留，要重试应逐项检查原因后移走对应错误缓存，不自动绕过403。标准化重新合并搜索文件。查询词保存在采集脚本 GROUPS，原始节目发现来源与请求时间见 search/ 和 shows.json。不会请求音频 enclosure。

先按 labeling-guide.md 填写真实人工标签，再完成作品族去重与语言审核。独立测试首次使用：`python3 research/scripts/validate.py --split test --seal-test`。此后规则、语料或标签变化会拒绝独立测试，不能覆盖封存文件来刷结果。开发集可自由研究。正式报告必须分开列开发、独立测试、AI元数据判读和弱标签。

## 文件与状态

- datasets/fiction_research/search：公开 Apple 精简元数据缓存，按查询哈希命名。
- datasets/fiction_research/rss：节目元数据和最多8个分布式单集摘要，按 Apple ID 命名。
- shows.json：RSS/Apple ID 去重后候选，不是人工分类结果。
- annotation_tasks.json / labels.json：盲标任务 / 已完成标签。
- reports/fiction_research：采集日志、词频证据、模式、评分输出与真实分母。
- rules/research/fiction-candidate.json：与共享 Schema 兼容的 `status=example` 探索候选；不替换 App 内置资源。

## 接口与集成限制

按接口使用 `fiction-audiobooks`，不是最初建议的下划线 ID。字段映射：categoryId→id、weightedKeywords→keywords、keywordCombinations→combinationKeywords、exclusionRules→exclusions、regexPatterns→regexRules；每条规则的 id/note 对应单独报告中的 evidence。sources 只提供来源定位，不嵌入全部 RSS 文本。

节目身份使用源 RSS URL 规范形式，单集 SHA256(RSS ID + LF + GUID)，缺 GUID 回退 enclosure URL（只计算ID不下载）。未知准确身份时不填黑白名单。跨 HTTP/HTTPS 别名不强行合并，以免与 App 身份不一致。作者不计分；分类只做研究记录。通用词“故事/历史/文学/小说/第X期”不能独立触发封禁。单次元数据评分无法表达多单集一致性；v1 不新增字段，跨集分析仅输出研究报告。

候选文件采用普通关键词而非不可抵扣的强特征词，以研究书评/访谈误伤。分数尚未经过独立人工校准。Schema 合格只说明格式，不说明有效性。未来可复用采集、来源追踪、盲标、冻结、验证流程研究其他类别，但不可沿用 fiction 标签或阈值直接宣布准确率。
