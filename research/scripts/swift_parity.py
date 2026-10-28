#!/usr/bin/env python3
"""Compare actual A Swift loader/scorer with research Python on development data only."""
import hashlib
import json
import subprocess
import tempfile
import sys
from pathlib import Path
from collect import DATA, ROOT, write
from engine import evaluate, fields, normalize
from swift_support import compile_probe

def main():
    rules=ROOT/'rules/research/fiction-candidate.json'
    bundle=json.loads(rules.read_text())
    fixtures=[]
    diagnose='--diagnose' in sys.argv
    target_ids={m['show_id'] for m in json.loads((ROOT/'reports/fiction_research/swift-parity.json').read_text())['mismatches']} if diagnose else None
    for s in json.loads((DATA/'shows.json').read_text()):
        if s['split']!='dev' or not s['feed_url']:
            continue
        if target_ids is not None and s['id'] not in target_ids:
            continue
        p=DATA/'rss'/(s['id']+'.json')
        r=json.loads(p.read_text()) if p.exists() else {}
        for e in [None]+r.get('episodes',[]):
            fixtures.append(dict(show_id=s['id'],feed_url=s['feed_url'],guid=e.get('guid') if e else None,fields=fields(s,r,e),rss_complete=r.get('status')=='ok'))
    with tempfile.TemporaryDirectory(prefix='fiction-parity-') as folder:
        folder=Path(folder);input_file=folder/'input.json'
        write(input_file,fixtures)
        exe,source_hashes=compile_probe(folder)
        result=json.loads(subprocess.check_output([str(exe),str(rules),str(input_file)]))
    mismatches=[]
    for i,(fixture,swift) in enumerate(zip(fixtures,result)):
        raw=fixture['fields']
        py=evaluate(bundle,raw,fixture['feed_url'],'',fixture['rss_complete'])
        different=[k for k,v in raw.items() if normalize(v)!=swift['normalization'][k]]
        if different or py['decision']!=swift['decision'] or abs(py['score']-swift['score'])>1e-7:
            delta=[]
            for k in different:
                x=normalize(raw[k]);y=swift['normalization'][k]
                first=next((j for j,(a,b) in enumerate(zip(x,y)) if a!=b),min(len(x),len(y)))
                delta.append(dict(field=k,python=x[max(0,first-4):first+10],swift=y[max(0,first-4):first+10]))
            mismatches.append(dict(fixture=i,show_id=fixture['show_id'],normalization_fields=different,normalization_delta=delta,python_decision=py['decision'],swift_decision=swift['decision'],python_score=py['score'],swift_score=swift['score']))
    report=dict(fixtures=len(fixtures),swift_results=len(result),mismatch_count=len(mismatches),mismatches=mismatches,source_hashes=source_hashes,rule_sha256=hashlib.sha256(rules.read_bytes()).hexdigest(),notes='Development-only scoring/normalization parity. No private parent policy or playback operation exercised.')
    write(ROOT/('reports/fiction_research/swift-diagnostic.json' if diagnose else 'reports/fiction_research/swift-parity.json'),report)
    print(json.dumps({k:v for k,v in report.items() if k not in ('mismatches','source_hashes')},indent=2))
    if mismatches or len(fixtures)!=len(result):
        raise SystemExit(1)

if __name__=='__main__':
    main()
