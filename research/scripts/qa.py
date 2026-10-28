#!/usr/bin/env python3
"""Verify data integrity and publish the actual gate status; never manufacture labels."""
import collections
import json
import subprocess
import sys
from collect import DATA, ROOT, write

def main():
    shows=json.loads((DATA/'shows.json').read_text())
    labels=json.loads((DATA/'labels.json').read_text())
    ids=[s['id'] for s in shows]
    assert len(ids)==len(set(ids)), 'duplicate show ID'
    by_id={s['id']:s for s in shows}
    feeds=[s['feed_url'] for s in shows if s['feed_url']]
    assert len(feeds)==len(set(feeds)), 'duplicate canonical feed'
    count=0
    for l in labels:
        s=by_id[l['show_id']]
        assert s['split']=='dev' or l['label_source']=='human', 'agent reading test set would contaminate it'
        if l['unit']=='episode':
            rss=json.loads((DATA/'rss'/(s['id']+'.json')).read_text())
            assert l['episode_id'] in {e['id'] for e in rss['episodes']}, 'episode label not in sampled RSS'
        count+=1
    completed=subprocess.run([sys.executable,'-m','unittest','discover','-s','research/scripts','-p','test_*.py'],cwd=ROOT,text=True,capture_output=True)
    if completed.returncode:
        raise RuntimeError(completed.stderr)
    # Test set cannot be evaluated accidentally without human labels and a freeze.
    test_guard=subprocess.run([sys.executable,'research/scripts/validate.py','--split','test'],cwd=ROOT,text=True,capture_output=True)
    assert test_guard.returncode!=0 and 'requires frozen matching' in test_guard.stderr
    human=[l for l in labels if l['label_source']=='human']
    result=dict(unique_show_ids='pass',unique_feed_ids='pass',label_references_checked=count,unit_tests=completed.stderr.strip(),unsealed_test_guard='pass',human_label_counts=dict(collections.Counter(l['unit']+'/'+l['label'] for l in human)),production_gate='not_ready_missing_human_gold_and_independent_test',no_app_files_modified_by_task_B=True)
    write(ROOT/'reports/fiction_research/qa.json',result)
    print(json.dumps(result,ensure_ascii=False,indent=2))

if __name__=='__main__':
    main()
