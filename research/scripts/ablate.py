#!/usr/bin/env python3
"""Same-snapshot ablations; human/AI labels and review kept separate."""
import copy
import hashlib
import json
from collect import DATA,ROOT,now,write,canonical
from engine_v11 import evaluate
from validate import metrics

def fixtures():
    observations=json.loads((DATA/'entities/observations.json').read_text())
    obs={o['show_id']:o for o in observations}
    labels=json.loads((DATA/'labels.json').read_text())
    if (DATA/'entities/labels-additions.json').exists():labels+=json.loads((DATA/'entities/labels-additions.json').read_text())
    rows=[]
    seen=set()
    for label in labels:
        sid=label['show_id'];key=(label['unit'],sid,label.get('episode_id'))
        assert key not in seen,'duplicate annotation';seen.add(key)
        if sid not in obs:continue
        o=obs[sid];extra=o['rss_enriched'];new=extra['data'] if extra else {};old=o['rss_baseline'] or {}
        episode=None
        if label['unit']=='episode':
            episode=next((e for e in old.get('episodes',[]) if e['id']==label['episode_id']),None)
            if not episode:continue
        raw=dict(showTitle=new.get('title',{}).get('text') or old.get('title',{}).get('text') or o['title'],showDescription=new.get('description',{}).get('text') or old.get('description',{}).get('text',''),showCategories='\n'.join(o['apple_genre_labels']),author=o['creator_display_name'],episodeTitle=episode['title']['text'] if episode else '',episodeDescription=episode['description']['text'] if episode else '',rssMetadata='\n'.join(str(v) for v in old.get('metadata',{}).values()))
        source=o['apple_source'];cs=[];ps=[]
        apple_source='appleLookup' if '/lookup?' in source['url'] else 'appleSearch'
        for i,gid in enumerate(o['apple_genre_ids']):
            cs.append(dict(namespace='apple.podcasts.genre',id=gid,name=o['apple_genre_labels'][i] if i<len(o['apple_genre_labels']) else gid,path=[],primary=i==0,source=apple_source,sourceURL=source['url'],observedAt=source['fetched_at']))
        ps.append(dict(namespace='apple.podcasts.artist',id=o['apple_artist_id'],name=o['creator_display_name'],role='unknown',source=apple_source,sourceURL=source['url'],observedAt=source['fetched_at']))
        if extra:
            source=extra['source']
            paths=new['itunes_category_paths'];first=paths[0][0] if paths else None
            for path in paths:
                cs.append(dict(namespace='rss.itunes.category',id=None,name=path[-1],path=path,primary=path[0]==first,source='rss',sourceURL=source['url'],observedAt=source['fetched_at']))
            for claim in new['credits']:
                namespace={'itunes_author_creator_claim':'rss.itunes.author','rss_owner_name_claim':'rss.itunes.owner','dc_publisher_claim':'rss.publisher','dc_creator_claim':'rss.dc.creator'}.get(claim['role'])
                if namespace:ps.append(dict(namespace=namespace,id=None,name=claim['value'],role='unknown',source='rss',sourceURL=source['url'],observedAt=source['fetched_at']))
        row=dict(show_id=sid,episode_id=label.get('episode_id'),unit=label['unit'],title=raw['episodeTitle'] if episode else raw['showTitle'],fields=raw,feed_url=canonical(o['rss_url']),guid=episode['guid'] if episode else None,rss_complete=bool(extra or old),classificationObservations=cs,publisherIdentities=ps,label=label['label'],label_source=label['label_source'],subtype=label.get('subtype'),boundary_type=label.get('boundary_type'),cohort=o['cohort'])
        rows.append(row)
    return rows

def variants(bundle):
    out={}
    for name,config in [('keywords_only',(False,False,True)),('publisher_only',(False,True,False)),('category_only_review',(True,False,False)),('category_only_block_diagnostic',(True,False,False)),('joint_v11_score',(True,True,True)),('joint_all_enabled_sources',(True,True,True))]:
        b=copy.deepcopy(bundle);c=b['categories'][0]
        c['recognition'].update(dict(zip(['appleCategories','publishers','keywords'],config)))
        if name=='category_only_block_diagnostic':
            for r in c['classificationRules']:r['action']='block'
        if name=='joint_all_enabled_sources':c['recognition']['combination']='allEnabledSources'
        out[name]=b
    return out

def main():
    rows=fixtures();at=now()
    bundle=json.loads((ROOT/'rules/research/fiction-multisource-candidate.json').read_text());models=variants(bundle)
    write(DATA/'entities/engine-fixtures.json',dict(evaluationTime=at,fixtures=rows))
    all_results={}
    for name,b in models.items():
        all_results[name]=[dict(unit=r['unit'],show_id=r['show_id'],episode_id=r['episode_id'],title=r['title'],label=r['label'],label_source=r['label_source'],subtype=r['subtype'],boundary_type=r['boundary_type'],**evaluate(b,r,at)) for r in rows]
    # A naive OR is intentionally a diagnostic: no claim that it is the release policy.
    naive=[];unsafe=[]
    for i,r in enumerate(rows):
        strategies=[all_results[n][i] for n in ('keywords_only','publisher_only','category_only_block_diagnostic')]
        decision=max((s['decision'] for s in strategies),key={'allow':0,'review':1,'block':2}.get)
        naive.append(dict(all_results['keywords_only'][i],decision=decision))
        # Falsify platform-wide blacklisting using an actually observed stable aggregate ID.
        matched=any(o.get('id')=='694593627' and o['namespace']=='apple.podcasts.artist' for o in r['publisherIdentities'])
        unsafe.append(dict(all_results['keywords_only'][i],decision='block' if matched else 'allow' if r['rss_complete'] else 'review'))
    all_results['naive_three_source_OR_diagnostic']=naive
    all_results['unsafe_aggregate_694593627_diagnostic']=unsafe
    report=dict(evaluationTime=at,status='exploratory_development_only',humanIndependentTest=False,sampleCounts=dict(show=sum(r['unit']=='show' for r in rows),episode=sum(r['unit']=='episode' for r in rows)),ruleSHA256=hashlib.sha256((ROOT/'rules/research/fiction-multisource-candidate.json').read_bytes()).hexdigest(),strategies={},notes=['No confirmed publisher block rules: publisher-only automatic recall can legitimately be zero.','review is never counted as an automatic block.','All strategies share identical input snapshot and labels.','AllEnabledSources is a separate experiment; pending publisher names are not an effective third signal.','Unsafe aggregate and category direct-block/OR diagnostics are not shipped policy.'])
    for name,results in all_results.items():
        human=[r for r in results if r['label_source']=='human'];agent=[r for r in results if r['label_source']=='agent_metadata_review']
        report['strategies'][name]=dict(formal={u:metrics([r for r in human if r['unit']==u]) for u in ('show','episode')},agentDevelopment={u:metrics([r for r in agent if r['unit']==u]) for u in ('show','episode')},protectedNonfictionGroups={t:metrics([r for r in agent if r['unit']=='show' and r['label']=='nonfiction' and (r['subtype']==t or r['boundary_type']==t)]) for t in ('interview','science','course','literary_review','business','history','philosophy')},errors=[r for r in agent if (r['label']=='fiction' and r['decision']!='block') or (r['label']=='nonfiction' and r['decision']=='block')])
    write(ROOT/'reports/fiction_research/ablation-results.json',report)
    write(ROOT/'reports/fiction_research/ablation-predictions.json',all_results)
    print('Ablations',len(models)+2,'strategies;',len(rows),'actual labeled development examples; human independent accuracy not measured')

if __name__=='__main__':main()
