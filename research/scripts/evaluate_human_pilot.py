#!/usr/bin/env python3
"""Frozen-rule, human metadata pilot. No tuning or production promotion."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
from collect import DATA, ROOT, now, write, canonical
from engine import fields, normalize
from engine_v11 import evaluate, identity_name
from ablate import variants
from release_audit import prepare_review_pack, authoritative_labels, sha
from validate import metrics

OUT=ROOT/'reports/fiction_research/release/human-pilot'
FOREIGN={'1234086160':'ja','1474474297':'nl','1490476655':'en','1494068599':'ja'}
ENGLISH_FICTION={'1251826993','1262978649'}
WORKS={'1125959192':['女仙外史'],'1128284503':['战争与和平'],'1181770436':['乱世为媒'],'1268501410':['山海经新说'],'1271272846':['缥缈','提灯卷'],'1321229059':['战争风云'],'1358251055':['今生亦何欢'],'1462843777':['第十八个盛夏'],'1489176388':['经典101','皇帝与夜莺','小锡兵']}


def scope(sid):
    if sid in FOREIGN:return 'foreign_metadata'
    if sid in ENGLISH_FICTION:return 'english_fiction_exemption'
    return 'chinese_candidate'


def expected(label):
    # Old batches predate explicit filter_decision. Exemptions remain fiction.
    return label.get('filter_decision') or ('block' if label['label']=='fiction' else 'allow')


def data():
    labels=[l for l in authoritative_labels() if l['label_source']=='human']
    assert all(l['unit']=='show' for l in labels),'Episode cohort needs separate preparation'
    manifest=prepare_review_pack(authoritative_labels())
    shows={s['id']:s for s in json.loads((DATA/'shows.json').read_text())}
    dev=[s for s in shows.values() if s['split']=='dev']
    extra=json.loads((DATA/'entities/observations.json').read_text())
    dev_ids={s['id'] for s in dev}|{o['show_id'] for o in extra}
    dev_names=collections.defaultdict(list)
    for s in dev:dev_names[identity_name(s['author'])].append(s['id'])
    for o in extra:dev_names[identity_name(o['creator_display_name'])].append(o['show_id'])
    search={}
    for path in sorted((DATA/'search').glob('*.json')):
        d=json.loads(path.read_text())
        for rec in d.get('records',[]):
            sid=str(rec.get('collectionId') or rec.get('trackId'))
            search.setdefault(sid,[]).append((rec,d['source']))
    out=[];audit=[]
    for l in labels:
        sid=l['show_id'];s=shows[sid];rss=json.loads((DATA/'rss'/(sid+'.json')).read_text())
        aliases={s['id'],*s['apple_ids']}
        candidates=[(rec,source) for aid in aliases for rec,source in search.get(aid,[])]
        assert candidates,'Missing original Apple evidence'
        rec,source=candidates[0]
        cs=[]
        for i,gid in enumerate(rec.get('genreIds',[])):
            cs.append(dict(namespace='apple.podcasts.genre',id=str(gid),name=rec.get('genres',[])[i] if i<len(rec.get('genres',[])) else str(gid),path=[],primary=i==0,source='appleSearch',sourceURL=source['url'],observedAt=source['fetched_at']))
        ps=[dict(namespace='apple.podcasts.artist',id=str(rec['artistId']) if rec.get('artistId') else None,name=rec.get('artistName',s['author']),role='unknown',source='appleSearch',sourceURL=source['url'],observedAt=source['fetched_at'])]
        overlap=[]
        for w in WORKS.get(sid,[]):
            for other in dev:
                if normalize(w) in normalize(other['title']):overlap.append(dict(token=w,show_id=other['id'],title=other['title']))
        name_overlap=sorted(set(dev_names.get(identity_name(s['author']),[])))
        scoped=scope(sid)
        excluded=scoped!='chinese_candidate' or bool(overlap or name_overlap)
        audit.append(dict(show_id=sid,title=s['title'],scope=scoped,rss_language=rss.get('metadata',{}).get('language'),stable_artist_id=ps[0]['id'],normalized_display_name_overlap=name_overlap,work_title_overlap=overlap,eligibleForScreenedPilot=not excluded,accountIndependenceCertified=False,workFamilyIndependenceCertified=False))
        out.append(dict(unit='show',show_id=sid,episode_id=None,title=s['title'],fields=fields(s,rss),feed_url=canonical(s['feed_url']),guid=None,rss_complete=rss.get('status')=='ok',classificationObservations=cs,publisherIdentities=ps,label=l['label'],label_source='human',subtype=l.get('subtype'),expectedFilterDecision=expected(l),scope=scoped,eligibleForScreenedPilot=not excluded))
    return out,audit,manifest


def main():
    p=argparse.ArgumentParser();p.add_argument('--score',action='store_true');a=p.parse_args()
    rows,audit,manifest=data()
    bundle_path=ROOT/'rules/research/fiction-multisource-candidate.json'
    snapshot=dict(candidateSHA256=sha(bundle_path),humanLabelsSHA256=sha(DATA/'release/human-labels.json'),holdoutManifestSHA256=sha(DATA/'release/holdout-preparation.json'),engineSHA256={p.name:sha(p) for p in [Path(__file__),ROOT/'research/scripts/engine.py',ROOT/'research/scripts/engine_v11.py']},fixtureSHA256=hashlib.sha256(json.dumps(rows,ensure_ascii=False,sort_keys=True).encode()).hexdigest())
    OUT.mkdir(parents=True,exist_ok=True)
    audit_path=OUT/'prescore-audit.json'
    if not a.score:
        if audit_path.exists():raise ValueError('Do not overwrite sealed pilot audit')
        write(audit_path,dict(status='screened_not_independence_certified',preparedAt=now(),snapshot=snapshot,rows=audit,notes=['All 50 chat labels preserved; work and name overlaps excluded before model scoring.','Title/name non-overlap cannot certify account ownership, aliases, adaptations or work-family independence.','English fiction decisions are language policy exceptions, not nonfiction labels.','Chat clarification on items 37/38 supplied factual reminders; not an unassisted blind annotation.','No audio language verification performed.','Original Apple cache has no retained stable artist IDs; publisher-only coverage cannot be reliably assessed.','The screened pilot remains a convenience sample, not a representative independent test.']))
        write(OUT/'fixtures.json',dict(evaluationTime=now(),fixtures=rows))
        print('Prepared prescore audit:',len(rows),'human shows;',sum(r['eligibleForScreenedPilot'] for r in rows),'screened Chinese candidates; no scoring yet')
        return
    seal=json.loads(audit_path.read_text());assert seal['snapshot']==snapshot,'Pilot input changed after prescore seal'
    document=json.loads((OUT/'fixtures.json').read_text());assert document['fixtures']==rows
    bundle=json.loads(bundle_path.read_text());all_variants=variants(bundle)
    results={}
    for name in ['keywords_only','publisher_only','category_only_review','joint_v11_score']:
        predictions=[dict(show_id=r['show_id'],title=r['title'],label=r['label'],expectedFilterDecision=r['expectedFilterDecision'],scope=r['scope'],eligibleForScreenedPilot=r['eligibleForScreenedPilot'],**evaluate(all_variants[name],r,document['evaluationTime'])) for r in rows]
        screened=[r for r in predictions if r['eligibleForScreenedPilot']]
        chinese=[r for r in predictions if r['scope']=='chinese_candidate']
        out_of_scope=[r for r in predictions if r['scope']!='chinese_candidate']
        results[name]=dict(screenedChinesePilot=metrics(screened),allChineseBeforeOverlapExclusion=metrics(chinese),outOfScopePolicyRegression=dict(count=len(out_of_scope),confusion=dict(collections.Counter(r['expectedFilterDecision']+'/'+r['decision'] for r in out_of_scope))),errors=[r for r in predictions if r['expectedFilterDecision']=='block' and r['decision']!='block' or r['expectedFilterDecision']=='allow' and r['decision']=='block'],predictions=predictions)
    write(OUT/'results.json',dict(status='provisional_human_metadata_pilot_not_certified_independent',evaluationTime=document['evaluationTime'],snapshot=snapshot,showCount=len(rows),episodeHumanLabels=0,independentTestCertified=False,productionEligible=False,strategies=results))
    for name,r in results.items():print(name,json.dumps(r['screenedChinesePilot'],ensure_ascii=False))

if __name__=='__main__':main()
