#!/usr/bin/env python3
import copy
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path
from collect import DATA,ROOT,write
from swift_support import compile_probe
from ablate import variants
from engine_v11 import evaluate

def main():
    document=json.loads((DATA/'entities/engine-fixtures.json').read_text())
    bundle=json.loads((ROOT/'rules/research/fiction-multisource-candidate.json').read_text())
    publisher=json.loads((ROOT/'rules/research/publisher-accounts.json').read_text())
    models=variants(bundle);models['publisher_library_export']=publisher
    results={}
    with tempfile.TemporaryDirectory(prefix='fiction-v11-probe-') as folder:
        folder=Path(folder);exe,hashes=compile_probe(folder)
        input_file=folder/'input.json';write(input_file,document)
        for name,b in models.items():
            path=folder/(name+'.json');write(path,b)
            swift=json.loads(subprocess.check_output([str(exe),str(path),str(input_file)]))
            mismatches=[]
            for i,(fixture,actual) in enumerate(zip(document['fixtures'],swift)):
                predicted=evaluate(b,fixture,document['evaluationTime'])
                if actual['decision']!=predicted['decision'] or abs(actual['score']-predicted['score'])>1e-7:
                    mismatches.append(dict(index=i,show_id=fixture['show_id'],python=predicted,swift=actual))
            results[name]=dict(fixtures=len(document['fixtures']),swiftResults=len(swift),mismatchCount=len(mismatches),mismatches=mismatches)
            print(name,len(swift),'fixtures;',len(mismatches),'differences',flush=True)
    report=dict(schemaVersion='1.1',status='pass' if all(not x['mismatchCount'] and x['fixtures']==x['swiftResults'] for x in results.values()) else 'fail',evaluationTime=document['evaluationTime'],sourceHashes=hashes,ruleSHA256=hashlib.sha256((ROOT/'rules/research/fiction-multisource-candidate.json').read_bytes()).hexdigest(),publisherRuleSHA256=hashlib.sha256((ROOT/'rules/research/publisher-accounts.json').read_bytes()).hexdigest(),strategies=results,notes='Actual A RulesLoader and ContentFilter; one content category, no parent policies. Diagnostic OR and unsafe aggregate are analytical comparisons, not exported packages.')
    write(ROOT/'reports/fiction_research/swift-multisource-parity.json',report)
    if report['status']!='pass':raise SystemExit(1)

if __name__=='__main__':main()
