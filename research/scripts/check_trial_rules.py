#!/usr/bin/env python3
"""Release-trial compatibility and exposed-sample regression, not independent accuracy."""
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path
from collect import ROOT, DATA, now, write
from engine_v11 import evaluate
from swift_support import compile_probe
from validate import metrics

OUT=ROOT/'reports/fiction_research/release/production-trial'

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    rule_path=ROOT/'rules/fiction-audiobooks.json';bundle=json.loads(rule_path.read_text())
    human=json.loads((ROOT/'reports/fiction_research/release/human-pilot/fixtures.json').read_text())['fixtures']
    dev=json.loads((DATA/'entities/engine-fixtures.json').read_text())['fixtures']
    at=now();rows=human+dev
    document=dict(evaluationTime=at,fixtures=rows)
    predictions=[dict(show_id=r['show_id'],unit=r['unit'],title=r['title'],label=r['label'],label_source=r['label_source'],expectedFilterDecision=r.get('expectedFilterDecision'),scope=r.get('scope'),**evaluate(bundle,r,at)) for r in rows]
    with tempfile.TemporaryDirectory(prefix='quietcast-trial-check-') as temp:
        temp=Path(temp);exe,hashes=compile_probe(temp)
        f=temp/'fixtures.json';write(f,document)
        actual=json.loads(subprocess.check_output([str(exe),str(rule_path),str(f)]))
    assert len(actual)==len(predictions)
    differences=[dict(index=i,show_id=r['show_id'],reference=p,swift=a) for i,(r,p,a) in enumerate(zip(rows,predictions,actual)) if p['decision']!=a['decision'] or abs(p['score']-a['score'])>1e-7]
    hp=predictions[:len(human)]
    failures=[p for p in hp if p['decision']!=p['expectedFilterDecision']]
    result=dict(status='pass' if not differences and not failures else 'needs_attention',evaluationTime=at,ruleSHA256=hashlib.sha256(rule_path.read_bytes()).hexdigest(),sourceHashes=hashes,independentTest=False,releaseBasis='user_approved_practical_trial_without_independent_accuracy_gate',humanRegression=dict(count=len(hp),matches=sum(p['decision']==p['expectedFilterDecision'] for p in hp),expectedConfusion=dict(__import__('collections').Counter(p['expectedFilterDecision']+'/'+p['decision'] for p in hp)),failures=failures),aiDevelopment={u:metrics([p for p in predictions[len(human):] if p['unit']==u]) for u in ['show','episode']},swiftComparisons=len(actual),swiftDifferences=differences,notes=['Human 50 and AI 112 are exposed regression/development cases, not independent test accuracy.','Current App module source SHA recorded; no App source edits performed by this check.','No unreviewed holdout scored. No publisher identities promoted.'])
    write(OUT/'checks.json',result);write(OUT/'predictions.json',predictions)
    print(json.dumps({k:v for k,v in result.items() if k not in ['sourceHashes','aiDevelopment']},ensure_ascii=False,indent=2))
    if differences:raise SystemExit('Swift/reference mismatch')

if __name__=='__main__':main()
