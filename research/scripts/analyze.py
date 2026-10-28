#!/usr/bin/env python3
"""Development-only feature discovery. Discovery strata are NOT true labels."""
import collections
import itertools
import json
import re
from collect import DATA, ROOT, write
from engine import fields, normalize

TERMS = '有声小说 小说朗读 小说演播 有声书 广播剧 多人剧 多人有声剧 全文朗读 玄幻 修仙 重生 穿越 末世 无限流 系统 总裁 娇妻 甜宠 赘婿 逆袭 言情 武侠 科幻 悬疑 恐怖 完结 全集 连载 演播 播讲 作者 原著 小说 故事 历史 文学 第一期 书评 评论 解读 解析 访谈 讨论 创作 文学史 赏析 纪实 真实 科普 课程 读书 分享'.split()
COMBOS = [('小说','演播'), ('小说','全集'), ('小说','朗读'), ('小说','连载'), ('重生','都市'), ('系统','逆袭'), ('总裁','娇妻'), ('多人','有声剧'), ('原著','播讲'), ('完结','演播'), ('有声','小说'), ('小说','播讲'), ('小说','听书'), ('悬疑','小说'), ('科幻','小说'), ('武侠','小说')]

def main():
    shows = json.loads((DATA/'shows.json').read_text())
    labels = json.loads((DATA/'labels.json').read_text()) if (DATA/'labels.json').exists() else []
    gold = {l['show_id']:l['label'] for l in labels if l.get('unit')=='show' and l.get('label_source')=='human'}
    agent = {l['show_id']:l['label'] for l in labels if l.get('unit')=='show' and l.get('label_source')=='agent_metadata_review'}
    rows = []
    for s in shows:
        if s['split'] != 'dev':
            continue
        path = DATA/'rss'/(s['id']+'.json')
        r = json.loads(path.read_text()) if path.exists() else {}
        raw = fields(s, r)
        # Episode title evidence is recorded separately; never concatenate into show fields.
        title_seq = [normalize(e['title']['text']) for e in r.get('episodes', [])]
        rows.append((s, {k:normalize(v) for k,v in raw.items()}, title_seq))
    result = []
    for terms in [(t,) for t in TERMS] + COMBOS:
        hits = []
        per_field = collections.Counter()
        groups = collections.Counter()
        for s, f, episodes in rows:
            matched = [k for k,v in f.items() if all(normalize(t) in v for t in terms)]
            if any(all(normalize(t) in e for t in terms) for e in episodes):
                matched.append('sampledEpisodeTitle')
            if matched:
                hits.append(s['id'])
                per_field.update(matched)
                groups.update(set(d['group'] for d in s['discoveries']))
        positives = [s['id'] for s,_,_ in rows if gold.get(s['id']) == 'fiction']
        negatives = [s['id'] for s,_,_ in rows if gold.get(s['id']) == 'nonfiction']
        apos = [s['id'] for s,_,_ in rows if agent.get(s['id']) == 'fiction']
        aneg = [s['id'] for s,_,_ in rows if agent.get(s['id']) == 'nonfiction']
        result.append(dict(terms=list(terms), matched_shows=len(hits), fields=dict(per_field), discovery_groups=dict(groups), human_fiction_hit_rate=len(set(hits)&set(positives))/len(positives) if positives else None, human_nonfiction_hit_rate=len(set(hits)&set(negatives))/len(negatives) if negatives else None, agent_development_only=dict(fiction_hits=len(set(hits)&set(apos)),fiction_total=len(apos),nonfiction_hits=len(set(hits)&set(aneg)),nonfiction_total=len(aneg)), examples=hits[:8]))
    ngrams = collections.Counter()
    for s,f,eps in rows:
        # Show title document-frequency, no descriptions or long copyrighted excerpts.
        title = f['showTitle']
        ngrams.update({title[i:i+n] for n in (2,3,4,5) for i in range(len(title)-n+1) if re.fullmatch(r'[\u3400-\u9fff]+', title[i:i+n])})
    output = dict(development_shows=len(rows), human_labels=len(gold), caveat='Search discovery group is not ground truth; null rates mean not measured.', features=result, title_ngrams=[dict(term=k,document_frequency=v) for k,v in ngrams.most_common(250)])
    write(ROOT/'reports/fiction_research/features.json', output)
    print(f'Features: {len(result)}; development shows: {len(rows)}; human show labels: {len(gold)}')

if __name__ == '__main__':
    main()
