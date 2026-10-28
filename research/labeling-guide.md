# 标注指南

`datasets/fiction_research/annotation_tasks.json` 是去掉查询词和规则结果的盲标任务；正式标签写入 `labels.json`，不覆盖待标任务。合法 label：fiction / nonfiction / uncertain；label_source：human / agent_metadata_review / weak。记录 unit、show_id、episode_id、label、subtype、boundary_type、rationale、annotator、label_source、labeled_at、family_id。人工复核以 `human` 标明；AI 判读不能填写 human。

fiction：以虚构文本朗读、演播为主要内容，包含传统小说、儿童童话、广播剧及单集短篇小说朗读。nonfiction：访谈、评论、科普、真实事件、知识课程、历史讲解；文学讨论虽可引用片段，不能因此判小说全文朗读。uncertain：简介和单集标题不足、虚构与纪实混合或无法判断主要内容。不要因为 query、作者名或分类“小说”直接定性。

节目和单集独立标注；单集朗读不能自动把读书讨论节目整档封禁。标节目时看多个不相邻单集。边界标签可填 literary_review/history_vs_historical_fiction/true_crime/film_review/children/biography/course/reading_share/short_fiction；边界不表示一定不拦截。

同一个 RSS 不跨 dev/test。相同作品不同主播、同一网络重复 feed、同作者高度重叠节目以相同 family_id 聚类，在验证前冻结划分。若规则开发人员已经阅读某节目以选词，应将该样本归为开发集，不能继续宣称测试独立。测试标签需要独立复核，测试不得用于反复调参后宣称独立准确率。
