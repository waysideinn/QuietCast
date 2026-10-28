#!/usr/bin/env python3
"""Audit release evidence; never relabel AI as human or promote an untested package."""
import collections
import hashlib
import json
from pathlib import Path
from collect import DATA,ROOT,write
from validate import metrics

RELEASE=DATA/'release'
REPORT=ROOT/'reports/fiction_research/release'
CANDIDATE=ROOT/'rules/research/fiction-multisource-candidate.json'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def authoritative_labels():
    paths=[DATA/'labels.json',DATA/'entities/labels-additions.json',RELEASE/'human-labels.json']
    labels=[]
    for path in paths:
        if path.exists():labels+=json.loads(path.read_text())
    keys=[(l['unit'],l['show_id'],l.get('episode_id')) for l in labels if l.get('label')]
    if len(keys)!=len(set(keys)):raise ValueError('Duplicate authoritative label; reconcile rather than count twice')
    return [l for l in labels if l.get('label')]

def prepare_review_pack(labels):
    RELEASE.mkdir(parents=True,exist_ok=True)
    candidate_sha=sha(CANDIDATE)
    manifest_path=RELEASE/'holdout-preparation.json'
    if manifest_path.exists():
        manifest=json.loads(manifest_path.read_text())
        if manifest['candidateSHA256']!=candidate_sha:raise ValueError('Candidate changed after holdout preparation; create a new documented cohort version')
        for path,digest in manifest['files'].items():
            if sha(ROOT/path)!=digest:raise ValueError('Prepared holdout artifact changed: '+path)
        current_shows={s['id']:s for s in json.loads((DATA/'shows.json').read_text())}
        member_ids={m['show_id'] for m in manifest['members']}
        if any(l['show_id'] in member_ids and l.get('label_source')!='human' for l in labels):
            raise ValueError('Prepared held-out show was exposed to AI/development labeling; quarantine it before independent testing')
        for member in manifest['members']:
            if sha(ROOT/member['rss_path'])!=member['rss_sha256']:raise ValueError('Prepared RSS snapshot changed')
            digest=hashlib.sha256(json.dumps(current_shows[member['show_id']],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
            if digest!=member['show_record_sha256']:raise ValueError('Prepared show metadata changed')
        return manifest
    shows=json.loads((DATA/'shows.json').read_text())
    dev_names={s['author'] for s in shows if s['split']=='dev'}
    seen_ids={l['show_id'] for l in labels}
    quarantined=json.loads((DATA/'entities/development-overrides.json').read_text())
    rows=[];eligible_before_name_exclusion=0
    for s in shows:
        if s['split']!='test' or s['id'] in seen_ids or s['id'] in quarantined:continue
        path=DATA/'rss'/(s['id']+'.json')
        if not path.exists():continue
        r=json.loads(path.read_text())
        if r.get('status')!='ok':continue
        eligible_before_name_exclusion+=1
        if s['author'] in dev_names:continue
        rows.append((s,r,path))
    # No predictions, search terms, genre labels or author clusters in the blind tasks.
    tasks=[];template=[];members=[]
    for s,r,path in rows:
        shared=dict(show_id=s['id'],source_url=s['feed_url'])
        sample=[dict(episode_id=e['id'],title=e['title'],description=e['description']) for e in r.get('episodes',[])]
        tasks.append(dict(**shared,unit='show',episode_id=None,title=r['title'],description=r['description'],sampled_episodes=sample))
        template.append(dict(unit='show',show_id=s['id'],episode_id=None,label=None,label_source=None,annotator=None,labeled_at=None,rationale=None,subtype=None,boundary_type=None,family_id=None,account_group_id=None))
        episodes=r.get('episodes',[])
        chosen=[episodes[i] for i in sorted({0,len(episodes)-1})] if episodes else []
        for e in chosen:
            if not e['id']:continue
            tasks.append(dict(**shared,unit='episode',episode_id=e['id'],show_title=r['title'],title=e['title'],description=e['description']))
            template.append(dict(unit='episode',show_id=s['id'],episode_id=e['id'],label=None,label_source=None,annotator=None,labeled_at=None,rationale=None,subtype=None,boundary_type=None,family_id=None,account_group_id=None))
        members.append(dict(show_id=s['id'],rss_path=str(path.relative_to(ROOT)),rss_sha256=sha(path),show_record_sha256=hashlib.sha256(json.dumps(s,sort_keys=True,ensure_ascii=False).encode()).hexdigest()))
    task_path=RELEASE/'blind-holdout-tasks.json';template_path=RELEASE/'human-labels.template.json'
    write(task_path,tasks);write(template_path,template)
    if not (RELEASE/'human-labels.json').exists():write(RELEASE/'human-labels.json',[])
    audit_path=RELEASE/'independence-audit.json'
    if not audit_path.exists():write(audit_path,dict(status='pending',reviewedBy=None,reviewedAt=None,workFamilyLeakageChecked=False,verifiedAccountLeakageChecked=False,languageScopeChecked=False,notes='Name non-overlap is only a screening heuristic; it is not verified account or work-family independence.'))
    manifest=dict(state='prepared_not_independence_certified',candidatePath=str(CANDIDATE.relative_to(ROOT)),candidateSHA256=candidate_sha,unlabeledTestShowsWithRSS=eligible_before_name_exclusion,selectedShows=len(rows),tasks=len(tasks),episodeTasks=sum(t['unit']=='episode' for t in tasks),selection='Original test candidates with successful RSS, excluding exposed IDs and exact display names present in development; no model scoring performed',members=members,files={str(task_path.relative_to(ROOT)):sha(task_path),str(template_path.relative_to(ROOT)):sha(template_path)},independentMetricsAvailable=False)
    write(manifest_path,manifest)
    return manifest

def release_blockers(labels,independence,bundle):
    human=[l for l in labels if l.get('label_source')=='human']
    blockers=[]
    if not human:blockers.append('No human labels: AI metadata judgments cannot be substituted for a human gold standard')
    if independence.get('status')!='complete' or not all(independence.get(k) is True for k in ('workFamilyLeakageChecked','verifiedAccountLeakageChecked','languageScopeChecked')):
        blockers.append('Held-out work-family/account/language audit is incomplete; independent test not certified')
    for c in bundle['categories']:
        for r in c.get('publisherRules',[]):
            if r['enabled'] and r['action'] in ('score','block') and (r['confirmation']['status']!='confirmed' or not r['identities']):
                blockers.append('An enabled scoring/blocking publisher rule lacks confirmed stable identity')
    # Changing the package status alone never supplies missing evidence.
    return blockers

def main():
    REPORT.mkdir(parents=True,exist_ok=True)
    labels=authoritative_labels();manifest=prepare_review_pack(labels)
    bundle=json.loads(CANDIDATE.read_text());cat=bundle['categories'][0]
    human=[l for l in labels if l.get('label_source')=='human']
    independence=json.loads((RELEASE/'independence-audit.json').read_text())
    blockers=release_blockers(labels,independence,bundle)
    # A human file alone is insufficient: only certified held-out members qualify.
    member_ids={m['show_id'] for m in manifest['members']}
    human_holdout=[l for l in human if l['show_id'] in member_ids]
    # This command audits evidence, not a scorer. Never invent test predictions
    # merely because someone later fills a label file or toggles an audit flag.
    blockers.append('No certified human independent-test predictions; keyword/category release validity remains unestablished')
    publisher_review=[]
    for r in cat['publisherRules']:
        reasons=[]
        if r['confirmation']['status']!='confirmed':reasons.append('confirmation_not_confirmed')
        if not r['identities']:reasons.append('no_stable_identity')
        if r['role'] in ('unknown','aggregator') and r['scope']=='allShows':reasons.append('whole_account_role_not_eligible_for_block')
        publisher_review.append(dict(ruleID=r['id'],names=r['names'],stableIdentities=r['identities'],eligibleForDefaultBlock=not reasons,reasons=reasons,enabledInResearch=r['enabled'],researchAction=r['action']))
    write(REPORT/'publisher-eligibility.json',publisher_review)
    counts={k:len(cat[k]) for k in ('strongKeywords','keywords','combinationKeywords','regexRules','exclusions','classificationRules','publisherRules')}
    corpus=json.loads((ROOT/'reports/fiction_research/corpus-summary.json').read_text())
    ablation=json.loads((ROOT/'reports/fiction_research/ablation-results.json').read_text())
    report=dict(releaseState='blocked_evidence_incomplete',productionRuleFile=None,productionEligible=False,formalRuleCounts=dict(keywords=0,combinations=0,publisherBlockAccounts=0),candidatePath=str(CANDIDATE.relative_to(ROOT)),candidateStatus=bundle['status'],candidateSHA256=sha(CANDIDATE),candidateCounts=counts,authoritativeLabelCounts=dict(collections.Counter(l['label_source'] for l in labels)),uniqueHumanLabels=len(human),humanHoldoutLabels=len(human_holdout),humanConfirmedPublisherBlockAccounts=sum(p['eligibleForDefaultBlock'] for p in publisher_review),sampling=dict(baseCandidates=corpus['candidate_shows'],baseRSSSuccess=corpus['rss_success'],baseEpisodeExcerpts=corpus['sampled_episodes'],note='Entity enrichment overlaps the baseline; counts are not added together'),holdout=dict(selectedShows=manifest['selectedShows'],episodeTasks=manifest['episodeTasks'],state=manifest['state']),independentTest=dict(measured=False,show=metrics([]),episode=metrics([]),reason='No certified human labels; null metrics are not zero error or zero recall'),exploratoryDevelopment=ablation['strategies']['joint_v11_score']['agentDevelopment'],blockers=blockers,notes=['No production JSON emitted; example status was not renamed to production.','No account or brand was added to a default blacklist.','No test-set predictions were generated while the human/family audit is pending.'])
    pilot_path=REPORT/'human-pilot/results.json'
    if pilot_path.exists():
        pilot=json.loads(pilot_path.read_text())
        report['provisionalHumanPilot']=dict(path=str(pilot_path.relative_to(ROOT)),status=pilot['status'],showCount=pilot['showCount'],independentTestCertified=False,metrics=pilot['strategies']['joint_v11_score']['screenedChinesePilot'])
        report['notes'][-1]='A separate provisional human metadata pilot was scored; account/work-family independence remains uncertified and pilot results are not formal release metrics.'
    trial_path=REPORT/'production-trial/release-manifest.json'
    if trial_path.exists():
        trial=json.loads(trial_path.read_text())
        production=ROOT/trial['rulesPath']
        app_resource=ROOT/trial['appResourcePath']
        checks=json.loads((REPORT/'production-trial/checks.json').read_text())
        if not (trial['status']=='production_trial_user_accepted' and trial['researchEvidenceGateWaivedByUser'] is True and (ROOT/trial['approvalRecord']).exists() and sha(production)==trial['ruleSHA256']==sha(app_resource)==checks['ruleSHA256'] and checks['status']=='pass'):
            raise ValueError('Production trial acceptance, checked artifact or App resource is inconsistent')
        released=json.loads(production.read_text())['categories'][0]
        report.update(releaseState=trial['status'],productionRuleFile=trial['rulesPath'],productionEligible=True,productionSHA256=trial['ruleSHA256'],appResource=trial['appResourcePath'],releaseBasis='Explicit user acceptance of approximate filtering and practical trial; independent validation gate waived',researchEvidenceGatePassed=False,formalRuleCounts=dict(keywords=len(released['keywords']),combinations=len(released['combinationKeywords']),publisherBlockAccounts=0))
        report['outstandingResearchLimitations']=report.pop('blockers')
        report['notes'].append('Production denotes a user-approved practical release, not independent accuracy certification. Frozen baseline and all previous measurements remain unchanged.')
    write(REPORT/'release-readiness.json',report)
    print(json.dumps({k:v for k,v in report.items() if k not in ('exploratoryDevelopment','independentTest')},ensure_ascii=False,indent=2))

if __name__=='__main__':main()
