#!/usr/bin/env python3
"""Compare human pilot to A's committed v1.1 engine, without compiling dirty App sources."""
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path
from collect import ROOT, write
from ablate import variants
from engine_v11 import evaluate
import swift_support

REVISION='b62212bdf9b36f0f90e2f7f3a8f0990bba6544b9'
OUT=ROOT/'reports/fiction_research/release/human-pilot'

def main():
    doc=json.loads((OUT/'fixtures.json').read_text())
    bundle=json.loads((ROOT/'rules/research/fiction-multisource-candidate.json').read_text())
    names=['keywords_only','publisher_only','category_only_review','joint_v11_score']
    bundles=variants(bundle);results={}
    with tempfile.TemporaryDirectory(prefix='quietcast-human-pilot-') as temp:
        temp=Path(temp);source=temp/'source';build=temp/'build';build.mkdir()
        files=subprocess.check_output(['git','ls-tree','-r','--name-only',REVISION,'--','Sources/PodcastModels','Sources/ContentFiltering'],cwd=ROOT,text=True).splitlines()
        for name in files:
            if not name.endswith('.swift'):continue
            p=source/name;p.parent.mkdir(parents=True,exist_ok=True)
            p.write_bytes(subprocess.check_output(['git','show',REVISION+':'+name],cwd=ROOT))
        p=source/'research/scripts/SwiftProbe.swift';p.parent.mkdir(parents=True,exist_ok=True)
        p.write_bytes((ROOT/'research/scripts/SwiftProbe.swift').read_bytes())
        swift_support.ROOT=source
        exe,hashes=swift_support.compile_probe(build)
        input_path=build/'fixtures.json';write(input_path,doc)
        for name in names:
            rule=build/(name+'.json');write(rule,bundles[name])
            actual=json.loads(subprocess.check_output([str(exe),str(rule),str(input_path)]))
            assert len(actual)==len(doc['fixtures'])
            differences=[]
            for row,got in zip(doc['fixtures'],actual):
                want=evaluate(bundles[name],row,doc['evaluationTime'])
                if want['decision']!=got['decision'] or abs(want['score']-got['score'])>1e-7:
                    differences.append(dict(show_id=row['show_id'],python=want,swift=got))
            results[name]=dict(compared=len(actual),differences=differences)
            print(name,len(actual),'compared;',len(differences),'differences',flush=True)
    report=dict(sourceRevision=REVISION,sourceHashes=hashes,fixtureSHA256=hashlib.sha256((OUT/'fixtures.json').read_bytes()).hexdigest(),rulesSHA256=hashlib.sha256((ROOT/'rules/research/fiction-multisource-candidate.json').read_bytes()).hexdigest(),strategies=results,status='pass' if not any(r['differences'] for r in results.values()) else 'fail',note='Frozen committed v1.1 engine. Concurrent working-tree App changes were not used or modified. Not a current iOS build/device test.')
    write(OUT/'swift-parity.json',report)
    if report['status']!='pass':raise SystemExit(1)

if __name__=='__main__':main()
