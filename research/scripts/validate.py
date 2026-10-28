#!/usr/bin/env python3
"""Separate show/episode evaluation; only human test labels enter formal metrics."""
import argparse
import collections
import hashlib
import json
import math
from collect import DATA, ROOT, write
from engine import evaluate, fields

def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()

def ratio(n, d):
    if not d:
        return dict(n=n,d=d,value=None,wilson95=None)
    z=1.959963984540054
    p=n/d
    center=(p+z*z/(2*d))/(1+z*z/d)
    half=z*math.sqrt(p*(1-p)/d+z*z/(4*d*d))/(1+z*z/d)
    return dict(n=n,d=d,value=p,wilson95=[max(0,center-half),min(1,center+half)])

def metrics(rows):
    pos=[r for r in rows if r['label']=='fiction']
    neg=[r for r in rows if r['label']=='nonfiction']
    determinate=[r for r in rows if r['label'] in ('fiction','nonfiction')]
    blocked=[r for r in determinate if r['decision']=='block']
    return dict(count=len(rows), confusion=dict(collections.Counter(r['label']+'/'+r['decision'] for r in rows)),fiction_block_recall=ratio(sum(r['decision']=='block' for r in pos),len(pos)),nonfiction_false_block_rate=ratio(sum(r['decision']=='block' for r in neg),len(neg)),precision=ratio(sum(r['label']=='fiction' for r in blocked),len(blocked)),review_rate=ratio(sum(r['decision']=='review' for r in rows),len(rows)),uncertain_blocked=sum(r['label']=='uncertain' and r['decision']=='block' for r in rows),subtype={t:ratio(sum(r['decision']=='block' for r in pos if (r.get('subtype') or 'unspecified')==t),sum((r.get('subtype') or 'unspecified')==t for r in pos)) for t in sorted({r.get('subtype') or 'unspecified' for r in pos})})

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--split',choices=['dev','test'],default='dev')
    p.add_argument('--seal-test',action='store_true',help='Freeze corpus and rules before first independent test')
    p.add_argument('--rules',default='rules/research/fiction-candidate.json')
    p.add_argument('--output-prefix',default=None)
    a=p.parse_args()
    shows=json.loads((DATA/'shows.json').read_text())
    bundle=json.loads((ROOT/a.rules).read_text())
    labels=json.loads((DATA/'labels.json').read_text()) if (DATA/'labels.json').exists() else []
    override_path=DATA/'entities/development-overrides.json'
    quarantined=json.loads(override_path.read_text()) if override_path.exists() else {}
    if a.split=='test' and any(l['show_id'] in quarantined for l in labels):
        raise ValueError('exposed/quarantined development challenge cannot re-enter independent test labels')
    by_id={s['id']:s for s in shows}
    seen=set()
    family_splits=collections.defaultdict(set)
    for label in labels:
        key=(label['unit'], label['show_id'],label.get('episode_id'))
        if key in seen:
            raise ValueError(f'duplicate label {key}')
        seen.add(key)
        if label['label'] not in ('fiction','nonfiction','uncertain') or label.get('label_source') not in ('human','agent_metadata_review','weak'):
            raise ValueError('invalid label or label_source')
        if not all(label.get(k) for k in ('rationale','annotator','labeled_at')):
            raise ValueError('missing annotation provenance')
        s=by_id[label['show_id']]
        family_splits[label.get('family_id') or s['feed_url']].add(s['split'])
    if any(len(v)>1 for v in family_splits.values()):
        raise ValueError('family appears in both dev and test: reconcile family split before evaluation')
    rss_digest=digest({p.name:digest(json.loads(p.read_text())) for p in sorted((DATA/'rss').glob('*.json'))})
    engine_digest=hashlib.sha256((ROOT/'research/scripts/engine.py').read_bytes()).hexdigest()
    snapshot=dict(rules=digest(bundle),corpus=digest(shows),rss=rss_digest,labels=digest(labels),engine=engine_digest,quarantined=digest(quarantined))
    lock=DATA/'test-lock.json'
    if a.split=='test':
        if a.seal_test:
            if lock.exists():
                raise ValueError('test already sealed; do not overwrite')
            if not any(l.get('label_source')=='human' and by_id[l['show_id']]['split']=='test' for l in labels):
                raise ValueError('cannot seal independent test without human test labels')
            write(lock,snapshot)
        if not lock.exists() or json.loads(lock.read_text()) != snapshot:
            raise ValueError('independent test requires frozen matching corpus, labels and rules')
    labeled={(l['unit'],l['show_id'],l.get('episode_id')):l for l in labels}
    predictions=[]
    for s in shows:
        if s['split'] != a.split:
            continue
        if a.split=='test' and s['id'] in quarantined:
            continue
        path=DATA/'rss'/(s['id']+'.json')
        r=json.loads(path.read_text()) if path.exists() else {}
        complete=r.get('status')=='ok'
        units=[('show',None)]+[('episode',e) for e in r.get('episodes',[]) if e['id']]
        for unit,e in units:
            eid=e['id'] if e else None
            result=evaluate(bundle,fields(s,r,e),s['feed_url'],eid or '',complete)
            label=labeled.get((unit,s['id'],eid),{})
            predictions.append(dict(unit=unit,show_id=s['id'],episode_id=eid,title=e['title']['text'] if e else s['title'],rss_complete=complete,label=label.get('label'),label_source=label.get('label_source'),subtype=label.get('subtype'),**result))
    formal=[r for r in predictions if r.get('label_source')=='human']
    agent=[r for r in predictions if r.get('label_source')=='agent_metadata_review']
    report=dict(split=a.split,status='measured' if formal else 'not_measured_no_human_labels',independent=a.split=='test',snapshot=snapshot,formal={u:metrics([r for r in formal if r['unit']==u]) for u in ('show','episode')},agent_exploratory={u:metrics([r for r in agent if r['unit']==u]) for u in ('show','episode')},all_predictions=dict(collections.Counter(r['unit']+'/'+r['decision'] for r in predictions)),errors=[r for r in formal+agent if (r['label']=='fiction' and r['decision']!='block') or (r['label']=='nonfiction' and r['decision']=='block')])
    prefix=a.output_prefix or a.split
    write(ROOT/f'reports/fiction_research/{prefix}-validation.json',report)
    write(ROOT/f'reports/fiction_research/{prefix}-predictions.json',predictions)
    print(json.dumps({k:v for k,v in report.items() if k not in ('errors','snapshot')},ensure_ascii=False,indent=2))

if __name__=='__main__':
    main()
