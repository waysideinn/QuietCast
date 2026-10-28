#!/usr/bin/env python3
"""Generate an honest research report from measured artifacts, with missing gates explicit."""
import json
from collect import ROOT

R=ROOT/'reports/fiction_research'

def rate(m):
    return '未测量（分母为0）' if m['value'] is None else f"{m['n']}/{m['d']} = {m['value']:.1%}"

def main():
    s=json.loads((R/'corpus-summary.json').read_text())
    v=json.loads((R/'dev-validation.json').read_text())
    f=json.loads((R/'features.json').read_text())
    parity=json.loads((R/'swift-parity.json').read_text()) if (R/'swift-parity.json').exists() else None
    lines=['# 中文播客小说类过滤研究：阶段报告','',
        '**状态：真实采样与探索规则已建立，未完成生产验收。人工标注金标准为0，独立测试尚未启动，不发布 production 词库。**','',
        'Schema 基准：`9e908672b5ac6afe94a0f6ea4e5d0f31f66b7360`。候选 JSON 遵循原始 Schema，不修改 A 的代码。日期：2026-10-25（香港时间）。','',
        '## 1. 真实采集规模与偏差','',
        f"完成 {s['search_requests']} 次 Apple CN/TW 搜索，共 {s['search_result_occurrences']} 条搜索结果出现，按 Apple ID/RSS 去重为 **{s['candidate_shows']} 档候选**。检索组候选（可交叉）为小说 {s['discovery_group_candidates']['fiction']}、正常 {s['discovery_group_candidates']['normal']}、边界 {s['discovery_group_candidates']['boundary']}。这些不是人工标注样本数量。",'',
        f"RSS 尝试 {s['rss_attempted']} 档，成功 {s['rss_success']}，失败 {s['rss_errors']}，尚未尝试 {s['rss_not_attempted']}；实际取到 **{s['sampled_episodes']} 个单集摘要**。每档最多8条，按整个当前 RSS 排序均匀取样；不下载音频，不保存完整 RSS 或小说全文。响应超过2MB会记录失败而不截断解析。",'',
        f"采集时间（UTC）：{s['source_first']} 至 {s['source_last']}。Apple 约20请求/分钟，采用串行≥3.2秒与缓存。RSS 同站串行并间隔1秒，有界下载及退避。来源和内容哈希逐查询/逐feed保留。",'',
        '来源：[Apple 官方公开 Search API 文档](https://performance-partners.apple.com/search-api)。检索 limit=200，media=podcast，entity=podcast；没有采集 Apple Books audiobooks。只搜索两个 storefront 和有限关键词，不能宣称覆盖全部中文播客。热门、关键词显式、存活 RSS 可能过采样。', '',
        '中文检索会得到外语节目。例如“末世”还召回 Moshi 系列，日语小王子 RSS 甚至自报 zh-cn。RSS language 只能辅助，不能代替内容语言复核。尚未完成全量语言和作品族审计。', '',
        '目标小说≥300、正常≥300、边界≥150 **尚未以人工标注口径达成**。候选数量足够，但公开摘要存在截断、失效、混合节目和错误语言标记，且没有人工复核者提供金标准。`annotation_tasks.json` 已输出去掉查询词和规则结果的标注包。','',
        '## 2. 开发集的实际规则表现','',
        '以下仅是 Codex 阅读真实元数据后给出的 agent_metadata_review 开发标签，不是人工金标准，不是独立测试准确率，不代表目录总体。规则已看过这些开发案例；不应把下表当作推广性能。','',
        '| 指标 | 节目级 | 单集级 |','|---|---:|---:|']
    for title,key in [('小说自动拦截召回','fiction_block_recall'),('非虚构误拦率','nonfiction_false_block_rate'),('已定性拦截精确率','precision'),('review比例','review_rate')]:
        lines.append('| '+title+' | '+rate(v['agent_exploratory']['show'][key])+' | '+rate(v['agent_exploratory']['episode'][key])+' |')
    lines += ['',f"节目标签 {v['agent_exploratory']['show']['count']} 条；单集标签 {v['agent_exploratory']['episode']['count']} 条。uncertain 被自动 block 的数量分别为 {v['agent_exploratory']['show']['uncertain_blocked']} / {v['agent_exploratory']['episode']['uncertain_blocked']}，它们不进入已定性 precision 分母，单独披露。所有分母、混淆矩阵、Wilson 95%区间和子类型结果见 `dev-validation.json`。例如0次误拦的小样本仍有很大的误拦率上界，不能证明≤3%。",'',
        '人工独立测试：小说召回、误拦、精确率、review全部为 **未测量**，不是0%。测试集按RSS哈希预分30%，未读取其内容进行选词。尚未进行作品族分组审计，因此暂存划分仍需锁定前核对。封存会锁定规则、标签、节目、RSS和评分引擎哈希；发生变化必须使用新的独立测试集。review不计作成功自动拦截。', '',
        '## 3. 哪些词最有区分度？','',
        '尚无充分人工正负标签，不能确认“最有区分度”。有声小说、小说朗读/演播、广播剧、多人有声剧是值得检验的候选；单纯高频不等于高精确率。下表是开发候选的出现频数与小规模AI判读命中，分母不是全目录。`features.json` 逐项列出字段、出现次数、样例ID；人工正/负命中率在无标签时保持 null。','',
        '| 词或组合 | 开发候选命中档数 | AI判读fiction命中 | AI判读nonfiction命中 |','|---|---:|---:|---:|']
    selected=[x for x in f['features'] if x['terms'] in [['有声小说'],['有声书'],['广播剧'],['多人有声剧'],['有声','小说'],['小说','播讲'],['悬疑','小说'],['总裁'],['故事'],['小说']]]
    for x in selected:
        a=x['agent_development_only']
        lines.append(f"| {' + '.join(x['terms'])} | {x['matched_shows']} | {a['fiction_hits']}/{a['fiction_total']} | {a['nonfiction_hits']}/{a['nonfiction_total']} |")
    lines += ['', '## 4. 哪些词容易误伤？','',
        '真实反例：`价值十亿总裁商战落地课堂`（1125953267）与`总裁陪你读书`（1462841121）不是总裁小说；`牛醫生與狗護士…2024年重生了`（1440580962）是节目恢复和生活聊天；`异能FM X 全球设计故事`（1031400642）讲设计；`穿越火线：第一次世界大战`（1241282365）以小说为参考讲解历史；`两小无才播客`（1091928630）有第001期而仍是聊天。故事、历史、文学、小说、期号均不独立封禁。', '',
        '“科普/课程/评论/文学史”也不能无条件放行：`颠覆性儿童益智心理学童话集`（1191410221）用认知教育措辞包装虚构童话；`蜀山剑侠传`（1449429752）在作者简介提文学史，但实际是章节演播；`归期`（1146322401）单集“欢迎评论”属于互动邀请，不能被当成文学评论证据。当前简单排除计分仍会漏拦这些情况。', '',
        '## 5. 哪些组合效果最好？如何找到不写小说的节目？','',
        '尚不能用独立测量选出最佳组合。已从实际元数据观察“有声 + 小说”（覆盖有声科幻小说等插词）、“小说 + 播讲/听书”、“多人 + 有声剧”等。组合采用sameField，避免把无关字段拼成证据；权重取单次命中的最高字段权重，每规则只加一次。', '',
        '不写小说的真例：`穿越搞笑-妖孽横行，狂妃祸江山`有作者、穿越嫡女的虚构情节和第71至408章；`媒丽山海`（1157803271）有科幻作品简介和多章；`儿童益智心理学童话集`有大灰狼、九头妖怪等具体虚构内容。可研究角色情节搭配、原著/演播组合和跨集章节比例。只有编号不能判小说。对纯书名、无简介、无章节标签的内容，关键词法仍会漏判。', '',
        '## 6. 节目级和单集级判断优缺点','',
        '节目级可利用节目简介、多个单集一致性发现隐蔽连载，也可能误伤混合内容。单集级能保留小说节目内的科学答疑，或拦截普通节目偶发的短篇小说朗读；但单集标题常省略原著和演播信息，脱离节目上下文会漏判。', '',
        '已观察实际误拦：`汪诘：科幻广播剧`的“答太阳帆船如何减速？”和“青少年科幻不必反思科学：叶李华新书推荐序”分别是科普和书序，当前会受节目字段影响而block。单集名单可按准确ID修正已知案例；本研究未把这些开发案例灌入名单来提高准确率。', '',
        'v1契约限制：不能表达跨多个单集的聚合评分、文本否定/引用关系、显式review名单，也不能根据单集上下文动态减掉节目分数。`serial-patterns.json` 只输出研究特征，不往JSON硬塞新字段。混合/未知节目需要进一步人工审核策略；当前评分落在allow并不意味着已证实非虚构。', '',
        '## 7. 类别覆盖与无法可靠识别的内容','',
        '种子覆盖玄幻、修仙、都市、穿越重生、末世、无限流、网游、赘婿、言情、悬疑恐怖、武侠、科幻、古典长篇、儿童故事和广播剧。检索覆盖不是各类已经达到召回率目标。小规模开发判读的类别分母见验证JSON，部分只有1个，不能作稳定类别结论。', '',
        '仍不能可靠判断：传记小说与史实讲解、纪实改编广播剧、情感夜读、短篇散文/虚构混合、儿童寓教于乐故事、只用书名且简介缺失的连载；媒体标题声称“真实”不一定排除虚构。AI判读中 uncertain 直接标明，不强行归正负。外语和版权许可不明的元数据不充当中文样本。', '',
        '## 8. 错误清单与下一步优化','',
        '全部已标注案例的误拦/漏拦（包含review未自动拦截）如下；unknown被block另在混淆矩阵披露。','',
        '| 层级 | Apple ID | 标题 | 标签 → 判定 |','|---|---|---|---|']
    for e in v['errors']:
        title=e['title'].replace('|','／').replace('\n',' ')
        lines.append(f"| {e['unit']} | {e['show_id']} | {title} | {e['label']} → {e['decision']} |")
    lines += ['',
        'v0.1和v0.2都是开发探索，v0.1快照另存；v0.2增加插词组合后不是独立准确率提升证据。建议先完成人工盲标和作品族去重，再用开发集校准阈值。排除语境应区分“欢迎评论”和“作品评论”，作者简介中的文学史也不应抵消演播。考虑在后续契约中增加节目跨集证据、明确review名单和单集上下文优先级，但由A/B另行协商版本，不能在本版私自扩展。', '',
        '## 9. 交付与复用','',
        '已提供采集/去重、盲标包、词频组合分析、规则构建、独立验证防泄漏、来源统计及Schema校验脚本；候选文件为 `rules/research/fiction-candidate.json`，`status=example`，不得冒充正式词库。契约校验和评分语义测试结果见 contract-check.json 与 qa.json。', '',
        (f"Swift交叉验证：直接编译A现有Models.swift和ContentFiltering.swift，完成 {parity['fixtures']} 条开发语料的真实加载、评分及归一化对照，差异 {parity['mismatch_count']} 条。只读取A源码，编译产物在临时目录。" if parity else 'Swift交叉验证尚未完成。'), '',
        '待完成：人工标注达到目标、中文范围审计、作品族分割、封存独立测试、性能目标评估。全部完成后才产出production规则；不直接改 App 资源。', '',
        '新增adult_content、horror、gambling可复用元数据采集、盲标、来源哈希、作品族隔离、字段分析、规则ID/evidence及分开计算review的验证流程；分类定义、标签、阈值和混淆边界必须重新研究。']
    (R/'research-report.md').write_text('\n'.join(lines)+'\n')
    print('Report regenerated from actual artifacts')

if __name__=='__main__':
    main()
