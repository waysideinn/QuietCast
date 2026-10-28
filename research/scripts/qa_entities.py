#!/usr/bin/env python3
import hashlib
import json
import subprocess
import sys
import jsonschema
from collect import DATA,ROOT,write

def main():
    schema=json.loads((ROOT/'schemas/content-filter.schema.json').read_text())
    packages=['rules/research/fiction-multisource-candidate.json','rules/research/publisher-accounts.json']
    counts={}
    for path in packages:
        obj=json.loads((ROOT/path).read_text())
        jsonschema.Draft202012Validator(schema,format_checker=jsonschema.FormatChecker()).validate(obj)
        assert obj['schemaVersion']=='1.1' and obj['status']=='example'
        assert len((ROOT/path).read_bytes())<=2*1024*1024
        for cat in obj['categories']:
            all_ids=[r['id'] for field in ['strongKeywords','keywords','exclusions','combinationKeywords','regexRules','classificationRules','publisherRules'] for r in cat[field]]
            assert len(all_ids)==len(set(all_ids))
            assert 0<cat['thresholds']['review']<cat['thresholds']['block']
            for r in cat['publisherRules']:
                assert r['confirmation']['status']=='pending'
                assert r['action']=='review','No account allowed to silently become a block'
                assert all(i['namespace']=='apple.podcasts.artist' and i['id'].isdigit() for i in r['identities'])
                if any(i['id']=='694593627' for i in r['identities']):assert not r['enabled']
            counts[path]=dict(publisherRules=len(cat['publisherRules']),enabledPendingReview=sum(r['enabled'] for r in cat['publisherRules']),enabledPublisherBlockRules=0)
    obs=json.loads((DATA/'entities/observations.json').read_text())
    by_id={o['show_id']:o for o in obs};assert len(by_id)==len(obs)
    originals={s['id']:s for s in json.loads((DATA/'shows.json').read_text())}
    overrides=json.loads((DATA/'entities/development-overrides.json').read_text())
    for o in obs:
        if originals.get(o['show_id'],{}).get('split')=='test':
            assert o['show_id'] in overrides and o['cohort']=='quarantined_original_test_boundary_challenge'
    labels=json.loads((DATA/'labels.json').read_text())+json.loads((DATA/'entities/labels-additions.json').read_text())
    keys=[(l['unit'],l['show_id'],l.get('episode_id')) for l in labels]
    assert len(keys)==len(set(keys))
    assert all(l['show_id'] in by_id for l in labels)
    assert all(l['label_source']=='agent_metadata_review' and l.get('rationale') and l.get('annotator') and l.get('labeled_at') for l in labels)
    parity=json.loads((ROOT/'reports/fiction_research/swift-multisource-parity.json').read_text())
    assert parity['status']=='pass'
    assert parity['ruleSHA256']==hashlib.sha256((ROOT/packages[0]).read_bytes()).hexdigest()
    assert parity['publisherRuleSHA256']==hashlib.sha256((ROOT/packages[1]).read_bytes()).hexdigest()
    for path,sha in parity['sourceHashes'].items():
        assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==sha,'A source changed: rerun Swift parity'
    unit=subprocess.run([sys.executable,'-m','unittest','discover','-s','research/scripts','-p','test_*.py'],cwd=ROOT,text=True,capture_output=True)
    assert unit.returncode==0,unit.stderr
    result=dict(status='pass',packages=counts,uniqueObservations=len(obs),agentReviewedLabels=len(labels),humanLabels=0,quarantinedTestCandidates=len(overrides),schema='pass',unitTests=unit.stderr.strip(),swiftCompared=sum(s['fixtures'] for s in parity['strategies'].values()),swiftMismatches=sum(s['mismatchCount'] for s in parity['strategies'].values()),productionReady=False,reason='Human gold and independent testing incomplete; account identity confirmation absent')
    write(ROOT/'reports/fiction_research/multisource-qa.json',result)
    print(json.dumps(result,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
