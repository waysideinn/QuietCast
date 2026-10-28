#!/usr/bin/env python3
"""Role-aware publisher registry and exact-category observations. No production account blocks."""
import collections
import hashlib
import json
import re
import unicodedata
from urllib.parse import urlsplit
from collect import DATA,ROOT,write
from collect_entities import OUT
from engine_v11 import identity_name

FICTION_IDS={'1483','1484','1485','1486'}
TAXONOMY=[('1483','Fiction','小说',None),('1484','Drama','剧情','1483'),('1485','Science Fiction','科幻小说','1483'),('1486','Comedy Fiction','喜剧小说','1483')]

def name_key(s):
    # Formatting equivalence, not identity proof; do not remove punctuation.
    return identity_name(s)

def count_labels(ids,labels):
    agent=collections.Counter();human=collections.Counter()
    for sid in set(ids):
        for label in labels.get(sid,[]):
            if label.get('label_source')=='human':human[label['label']]+=1
            elif label.get('label_source')=='agent_metadata_review':agent[label['label']]+=1
    labelled=sum(agent.values())+sum(human.values())
    # A single sample of fiction is not proof of a pure fiction account.
    total=agent+human
    state='observed_mixed' if total['fiction'] and total['nonfiction'] else 'observed_fiction_only_unverified' if total['fiction'] else 'no_fiction_verified_in_labeled_sample'
    return dict(discovered_show_count=len(set(ids)),agent_metadata_review=dict(agent),human=dict(human),unlabeled_show_count=len(set(ids))-labelled,portfolio_state=state,catalog_complete=False)

def main():
    shows=json.loads((DATA/'shows.json').read_text());original={s['id']:s for s in shows}
    labels=json.loads((DATA/'labels.json').read_text())
    overrides=json.loads((OUT/'development-overrides.json').read_text()) if (OUT/'development-overrides.json').exists() else {}
    if (OUT/'labels-additions.json').exists():labels+=json.loads((OUT/'labels-additions.json').read_text())
    show_labels=collections.defaultdict(list)
    for label in labels:
        if label['unit']=='show':show_labels[label['show_id']].append(label)
    records=json.loads((OUT/'apple-enriched.json').read_text())
    cached=collections.defaultdict(list)
    for file in sorted((DATA/'search').glob('*.json')):
        batch=json.loads(file.read_text())
        for row in batch['records']:cached[str(row['collectionId'])].append(dict(record=row,source=batch['source']))
    rss={}
    for file in (OUT/'rss').glob('*.json'):
        result=json.loads(file.read_text())
        if result['status']=='ok':rss[result['source']['url']]=result
    observations=[];excluded_test=[]
    ids=sorted(set(original)|set(records))
    for sid in ids:
        base=original.get(sid)
        if base and base['split']=='test' and sid not in overrides:excluded_test.append(sid);continue
        fresh=records.get(sid)
        entry=fresh or (cached[sid][0] if cached.get(sid) else None)
        if not entry:continue
        row=entry['record'];feed=row.get('feedUrl') or (base or {}).get('feed_url','')
        extra=rss.get(feed)
        old_path=DATA/'rss'/(sid+'.json')
        old=json.loads(old_path.read_text()) if old_path.exists() else {}
        observations.append(dict(show_id=sid,cohort=overrides[sid]['cohort'] if sid in overrides else 'original_dev' if base else 'curated_development_expansion',title=row.get('collectionName') or base['title'],creator_display_name=row.get('artistName') or (base or {}).get('author',''),creator_name_role='apple_artistName_display_claim_not_account_owner',apple_artist_id=str(row['artistId']) if row.get('artistId') else None,apple_artist_url=row.get('artistViewUrl'),apple_genre_ids=list(map(str,row.get('genreIds',[]))),apple_genre_labels=row.get('genres',[]),original_genre_id_snapshots=[list(map(str,x['record'].get('genreIds',[]))) for x in cached.get(sid,[])],apple_source=entry['source'],rss_url=feed,rss_endpoint_host=urlsplit(feed).hostname,rss_redirect_host=urlsplit(extra['source'].get('final_url','')).hostname if extra else None,rss_enriched=extra,rss_baseline=old if old.get('status')=='ok' else None))
    write(OUT/'observations.json',observations)
    named=collections.defaultdict(list);artists=collections.defaultdict(list);rights=collections.defaultdict(list)
    for o in observations:
        if o['creator_display_name']:named[name_key(o['creator_display_name'])].append(o)
        if o['apple_artist_id']:artists[o['apple_artist_id']].append(o)
        for claim in (o.get('rss_enriched') or {}).get('data',{}).get('credits',[]):
            if claim['role'] in ('dc_publisher_claim','copyright_notice_claim'):
                rights[(claim['role'],name_key(claim['value']))].append((o,claim))
    entities=[]
    for key,members in sorted(named.items(),key=lambda kv:(-len(kv[1]),kv[0])):
        member_ids=[o['show_id'] for o in members]
        stats=count_labels(member_ids,show_labels)
        # Keep multi-show clusters and all explicitly labeled show clusters.
        if len(members)<2 and not any(sid in show_labels for sid in member_ids):continue
        rid='name-'+hashlib.sha256(key.encode()).hexdigest()[:16]
        names=sorted(set(o['creator_display_name'] for o in members))
        affiliated=sorted(set(o['apple_artist_id'] for o in members if o['apple_artist_id']))
        entities.append(dict(id=rid,name=names[0],aliases=[dict(name=n,basis='format_equivalence_only',identityConfirmed=False) for n in names[1:]],role='creator_display_name_cluster',identityVerified=False,stableIDs=[],observedArtistAffiliations=[dict(namespace='apple.podcasts.artist',id=x,role='affiliation_not_creator_identity') for x in affiliated],showIDs=member_ids,statistics=stats,categoryFictionCount=sum(bool(FICTION_IDS&set(o['apple_genre_ids'])) for o in members),evidence=[dict(showID=o['show_id'],field='apple.artistName',value=o['creator_display_name'],source=o['apple_source']) for o in members[:5]],manualConfirmation=dict(status='pending',confirmedBy=None,confirmedAt=None),recommendedAction='review',blockEligible=False,enabled=False))
    artist_entities=[]
    for aid,members in sorted(artists.items(),key=lambda kv:-len(kv[1])):
        names=sorted(set(o['creator_display_name'] for o in members));stats=count_labels([o['show_id'] for o in members],show_labels)
        known_aggregate=aid=='694593627'
        role='aggregated_provider' if known_aggregate else 'multi_name_artist_identity_unresolved' if len(names)>1 else 'artist_account_role_unverified'
        artist_entities.append(dict(id='apple-artist-'+aid,name='听喜马拉雅' if known_aggregate else names[0],aliases=[],namespace='apple.podcasts.artist',stableIDs=[dict(namespace='apple.podcasts.artist',id=aid,scope='apple_artist_record_only')],role=role,creatorDisplayNames=names,statistics=stats,showIDs=[o['show_id'] for o in members],sourceURLs=sorted(set(o['apple_artist_url'] for o in members if o['apple_artist_url'])),evidence=[dict(showID=o['show_id'],artistName=o['creator_display_name'],source=o['apple_source']) for o in members[:8]],manualConfirmation=dict(status='pending',confirmedBy=None,confirmedAt=None),recommendedAction='review',blockEligible=False,enabled=False))
    rights_entities=[]
    for (role,key),members in sorted(rights.items()):
        rights_entities.append(dict(id='rights-'+hashlib.sha256((role+key).encode()).hexdigest()[:16],name=members[0][1]['value'],role=role,identityVerified=False,stableIDs=[],statistics=count_labels([o['show_id'] for o,_ in members],show_labels),evidence=[dict(showID=o['show_id'],field=c['field'],value=c['value'],source=o['rss_enriched']['source']) for o,c in members[:3]],manualConfirmation=dict(status='pending'),enabled=False))
    pages=json.loads((OUT/'page-index.json').read_text());channel_file=OUT/'channel-index.json'
    channels=json.loads(channel_file.read_text()) if channel_file.exists() else {}
    channel_entities=[]
    for cid,result in channels.items():
        d=result.get('data',{});members=[x['apple_id'] for x in d.get('shows',[]) if x['apple_id'] not in excluded_test]
        channel_entities.append(dict(id='apple-channel-'+cid,name=d.get('heading',''),role='apple_channel_collection_not_legal_owner',stableIDs=[dict(namespace='apple.podcasts.channel',id=cid)],showIDs=members,statistics=count_labels(members,show_labels),source=result['source'],manualConfirmation=dict(status='pending'),enabled=False))
    alias_candidates=[]
    for o in observations:
        for claim in (o.get('rss_enriched') or {}).get('data',{}).get('credits',[]):
            if claim['role']=='copyright_notice_claim' and '公司' in claim['value']:
                holder=claim['value'].split('@')[0].strip()
                alias_candidates.append(dict(displayName=o['creator_display_name'],claimedRightsHolder=holder,relationship='same_RSS_credit_cooccurrence_not_verified_alias',showID=o['show_id'],source=o['rss_enriched']['source'],manualConfirmation='pending'))
    registry=dict(artifactKind='publisher_account_research_registry',researchVersion='2026-10-26.1',appCompatibility='Research registry, not App import. v1.1 exports: publisher-accounts.json and fiction-multisource-candidate.json',status='research',schemaProposal='research/schema-extension-proposal.md',nameClusters=entities,appleArtistEntities=artist_entities,rightsClaims=rights_entities,appleChannelEntities=channel_entities,aliasAssociationCandidates=alias_candidates,enabledBlockRules=[],notes=['Name clusters are discovery buckets, not verified accounts.','Shared aggregated artist ID is not alias proof.','Hosting and CDN observations never produce publisher block rules.','Fiction counts come only from labeled samples, not search queries or genres.'])
    write(ROOT/'rules/research/publisher-accounts.research.json',registry)
    taxonomy=dict(artifactKind='classification_evidence_research',appCompatibility='Research only; classificationRules mapped into v1.1 candidate',status='research',sources=['https://podcasters.apple.com/support/1691-apple-podcasts-categories'],standardCategories=[dict(id=i,name=n,cnLabel=cn,parentID=parent) for i,n,cn,parent in TAXONOMY],nonFictionSpecificCategories=[dict(id='1482',name='Books',reason='Books includes commentary and nonfiction; not a fiction block category')],curatedCollections=[dict(name='有声图书',url='https://podcasts.apple.com/cn/grouping/197714',role='discovery_only'),dict(name='网络文学',url='https://podcasts.apple.com/cn/grouping/197716',role='discovery_only')],pageObservations={k:dict(source=v['source'],heading=v.get('data',{}).get('heading'),showLinkCount=len(v.get('data',{}).get('shows',[]))) for k,v in pages.items()},enabledBlockRules=[])
    write(ROOT/'rules/research/classification-evidence.research.json',taxonomy)
    drift=sum(any(set(old)!=set(o['apple_genre_ids']) for old in o['original_genre_id_snapshots']) for o in observations if o['original_genre_id_snapshots'])
    summary=dict(observationShows=len(observations),excludedOriginalTestShows=len(excluded_test),nameClusterCount=len(named),retainedNameClusters=len(entities),appleArtistEntityCount=len(artist_entities),freshLookupShows=sum(o['show_id'] in records for o in observations),showsWithArtistID=sum(bool(o['apple_artist_id']) for o in observations),rssEnrichedShows=sum(bool(o['rss_enriched']) for o in observations),rightsNoticeClusters=len(rights_entities),channelCount=len(channel_entities),categoryDifferencesAcrossSnapshots=drift,hostCounts=dict(collections.Counter(o['rss_endpoint_host'] for o in observations)),topNameClusters=[dict(name=e['name'],**e['statistics']) for e in entities[:30]],artistEntities=artist_entities,enabledPublisherBlockRules=0,humanConfirmedPublisherAccounts=0,artistIDMissingCaveat='Baseline search cache did not retain artistId. Missing in a baseline-only row is not proof that the API omitted it.')
    write(ROOT/'reports/fiction_research/entity-summary.json',summary)
    print('Entities',len(observations),'shows;',len(entities),'name clusters;',len(artist_entities),'Apple artist identities; no enabled publisher blocks')

if __name__=='__main__':main()
