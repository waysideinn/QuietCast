#!/usr/bin/env python3
import collections
import json
import re
from urllib.parse import urlsplit
from collect import DATA, ROOT, write

def main():
    shows=json.loads((DATA/'shows.json').read_text())
    rfiles=list((DATA/'rss').glob('*.json'))
    rss={r['show_id']:r for f in rfiles for r in [json.loads(f.read_text())]}
    ok=[r for r in rss.values() if r['status']=='ok']
    searches=[json.loads(p.read_text()) for p in (DATA/'search').glob('*.json')]
    labels=json.loads((DATA/'labels.json').read_text()) if (DATA/'labels.json').exists() else []
    stamps=[q['source']['fetched_at'] for q in searches]+[r['source']['fetched_at'] for r in ok]+[r['fetched_at'] for r in rss.values() if r.get('fetched_at')]
    chapter=re.compile(r'第[0-9一二三四五六七八九十百千万零〇两]{1,8}[章回集]')
    serial=[]
    for s in shows:
        r=rss.get(s['id'],{})
        es=r.get('episodes',[])
        hits=sum(bool(chapter.search(e['title']['text'])) for e in es)
        if es:
            serial.append(dict(show_id=s['id'],sampled_episodes=len(es),chapter_marker_count=hits,chapter_ratio=hits/len(es),split=s['split']))
    summary=dict(candidate_shows=len(shows),search_requests=len(searches),search_result_occurrences=sum(q['result_count'] for q in searches),discovery_group_candidates={g:sum(any(d['group']==g for d in s['discoveries']) for s in shows) for g in ('fiction','normal','boundary')},storefronts=dict(collections.Counter(q['country'] for q in searches)),rss_attempted=len(rss),rss_success=len(ok),rss_errors=len(rss)-len(ok),rss_not_attempted=len(shows)-len(rss),sampled_episodes=sum(len(r['episodes']) for r in ok),episodes_without_identity=sum(e['id'] is None for r in ok for e in r['episodes']),feed_hosts=dict(collections.Counter(urlsplit(s['feed_url']).hostname for s in shows)),rss_languages=dict(collections.Counter(r['metadata'].get('language','missing') for r in ok)),rss_errors_by_reason=dict(collections.Counter(r.get('error') for r in rss.values() if r['status']!='ok')),annotation_counts=dict(collections.Counter(f"{l.get('label_source')}/{l.get('unit')}/{l.get('label')}" for l in labels)),source_first=min((q['source']['fetched_at'] for q in searches),default=None),source_last=max((q['source']['fetched_at'] for q in searches),default=None),caveats=['Discovery-group counts overlap and are not labeled sample counts.','Chinese-query results can include foreign-language content.','RSS excerpts are bounded; feed item count is not historical total.','No human-label accuracy can be claimed until human labels exist.'])
    summary['source_first']=min(stamps,default=None)
    summary['source_last']=max(stamps,default=None)
    write(ROOT/'reports/fiction_research/corpus-summary.json',summary)
    write(ROOT/'reports/fiction_research/serial-patterns.json',serial)
    print(json.dumps(summary,ensure_ascii=False,indent=2))

if __name__=='__main__':
    main()
