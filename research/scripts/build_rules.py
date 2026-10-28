#!/usr/bin/env python3
"""Build Schema-compatible EXPLORATORY rules; production promotion is deliberately absent."""
import hashlib
import json
from collect import ROOT, write

def main():
    features = json.loads((ROOT/'reports/fiction_research/features.json').read_text())
    by_terms = {tuple(r['terms']):r for r in features['features']}
    fields = ['showTitle', 'showDescription', 'episodeTitle', 'episodeDescription']
    category = dict(id='fiction-audiobooks',name='小说与虚构故事音频',description='真实公开元数据支持的探索规则；未经人工独立测试，不作为生产词库。', enabled=True, thresholds=dict(review=4,block=10),fieldWeights=dict(showTitle=1.5,showDescription=0.7,showCategories=0,author=0,episodeTitle=1.5,episodeDescription=0.7,rssMetadata=0),strongKeywords=[],keywords=[],combinationKeywords=[],exclusions=[],regexRules=[],showBlocklist=[],episodeBlocklist=[],showAllowlist=[],episodeAllowlist=[],notes='status=example；查询组并非真实标签。未实现跨单集连续性评分，Schema v1 仅支持单次字段匹配。作者和目录分类权重为0。描述截断会影响召回。')
    evidence = {}
    def add(array, terms, score, fs=fields):
        observed = by_terms.get(tuple(terms))
        if not observed or not observed['matched_shows']:
            return
        rid = 'b-' + hashlib.sha256(('|'.join(terms)+'|'+array).encode()).hexdigest()[:12]
        rule = dict(id=rid,score=score,fields=fs,note=f"开发候选元数据命中{observed['matched_shows']}档；非人工正样本命中率。证据见 reports/fiction_research/rule-evidence.json。")
        if array == 'combinationKeywords':
            rule.update(terms=terms,scope='sameField')
        else:
            rule['term'] = terms[0]
        category[array].append(rule)
        evidence[rid] = observed
    # Evidence supports presence only, not discriminative power: retain ordinary
    # keyword scores so commentary exclusions can offset audiobook mentions.
    for term in ['有声小说','小说朗读','小说演播','有声书','广播剧','多人有声剧']:
        add('keywords',[term],7)
    for term in ['玄幻','修仙','重生','末世','无限流','总裁','甜宠','赘婿','言情']:
        add('keywords',[term],2)
    for term in ['完结','全集','连载','演播','播讲']:
        add('keywords',[term],1)
    for terms in [('小说','演播'),('小说','全集'),('小说','朗读'),('小说','连载'),('重生','都市'),('系统','逆袭'),('总裁','娇妻'),('多人','有声剧'),('原著','播讲'),('完结','演播')]:
        add('combinationKeywords',list(terms),5)
    for terms in [('有声','小说'),('小说','播讲'),('小说','听书'),('悬疑','小说'),('科幻','小说'),('武侠','小说')]:
        add('combinationKeywords',list(terms),7)
    for term in ['书评','评论','解读','解析','访谈','讨论','文学史','赏析','纪实','科普','课程','读书']:
        add('exclusions',[term],6)
    category['regexRules']=[dict(id='b-chapter-marker',pattern='第[0-9一二三四五六七八九十百千万零〇两]{1,8}[章回集]',score=1,fields=['episodeTitle'],note='仅弱特征，不会单独触发 review/block；不把第X期视为小说。')]
    bundle=dict(schemaVersion='1.0',ruleVersion='research-2026-10-25-v0.2',updatedAt='2026-10-25T00:00:00Z',status='example',sources=['https://performance-partners.apple.com/search-api','datasets/fiction_research/shows.json','datasets/fiction_research/rss/','schema commit 9e908672b5ac6afe94a0f6ea4e5d0f31f66b7360'],categories=[category])
    write(ROOT/'rules/research/fiction-candidate.json',bundle)
    write(ROOT/'reports/fiction_research/rule-evidence.json',evidence)
    import jsonschema
    jsonschema.Draft202012Validator(json.loads((ROOT/'schemas/content-filter.schema.json').read_text()), format_checker=jsonschema.FormatChecker()).validate(bundle)
    print('Candidate generated; JSON Schema validated; status=example')

if __name__ == '__main__':
    main()
