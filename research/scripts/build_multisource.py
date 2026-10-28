#!/usr/bin/env python3
"""Map research evidence to A's v1.1 contract; pending accounts never become blocks."""
import copy
import datetime as dt
import hashlib
import json
import jsonschema
from collect import ROOT,now,write

def main():
    registry=json.loads((ROOT/'rules/research/publisher-accounts.research.json').read_text())
    base=json.loads((ROOT/'rules/research/fiction-candidate.json').read_text())
    schema=json.loads((ROOT/'schemas/content-filter.schema.json').read_text())
    bundle=copy.deepcopy(base);bundle.update(schemaVersion='1.1',ruleVersion='research-multisource-2026-10-26-v0.1',updatedAt=now(),status='example')
    bundle['sources']+=['schemas/content-filter-v1.1.md','rules/research/publisher-accounts.research.json','reports/fiction_research/multisource-report.md']
    cat=bundle['categories'][0]
    cat['description']='分类、发布账号、关键词三类元数据证据探索；未完成人工独立测试。'
    cat['recognition']=dict(appleCategories=True,publishers=True,keywords=True,combination='score',metadataMaxAgeDays=30)
    cat['classificationRules']=[dict(id='b-category-fiction-family',enabled=True,match=dict(ids=['1483','1484','1485','1486'],names=['Fiction','Drama','Science Fiction','Comedy Fiction','小说','小說','剧情','劇情','科幻小说','科幻小說','喜剧小说','喜劇小說'],paths=[['Fiction'],['Fiction','Drama'],['Fiction','Science Fiction'],['Fiction','Comedy Fiction']],primaryOnly=False),action='score',score=4,note='标准分类族仅贡献4分，单独到review，不单独封禁。父子/目录RSS去重；Books和推荐grouping不匹配。',sources=['https://podcasters.apple.com/support/1691-apple-podcasts-categories','https://podcasts.apple.com/cn/genre/1483','datasets/fiction_research/entities/observations.json'])]
    rules=[]
    confirmation_at=bundle['updatedAt'];expiry=(dt.datetime.fromisoformat(confirmation_at)+dt.timedelta(days=30)).isoformat()
    for entity in registry['nameClusters']:
        counts=entity['statistics']['agent_metadata_review']
        pending_review=counts.get('fiction',0)>=3 and counts.get('nonfiction',0)==0
        # A name cluster is not an authenticated publisher identity.
        names=[entity['name']]+[x['name'] for x in entity['aliases']]
        if any(len(n)>256 for n in names):continue
        rules.append(dict(id='b-pub-'+entity['id'],enabled=pending_review,identities=[],names=names,role='unknown',scope='allShows',showIDs=[],action='review',score=1,confirmation=dict(status='pending',by='Codex metadata research; no human confirmation',at=confirmation_at,evidence=['rules/research/publisher-accounts.research.json#'+entity['id']]),expiresAt=expiry,note=f"显示名检索簇，非认证账号；AI已判读小说{counts.get('fiction',0)}、非虚构{counts.get('nonfiction',0)}，未标注{entity['statistics']['unlabeled_show_count']}。仅复核，0贡献；不能据此确认纯小说账号。"))
    for entity in registry['appleArtistEntities']:
        aid=entity['stableIDs'][0]['id']
        rules.append(dict(id='b-pub-artist-'+aid,enabled=False,identities=[dict(namespace='apple.podcasts.artist',id=aid)],names=[entity['name']],role='aggregator' if aid=='694593627' else 'unknown',scope='allShows',showIDs=[],action='review',score=1,confirmation=dict(status='pending',by='Codex metadata research; no human confirmation',at=confirmation_at,evidence=['rules/research/publisher-accounts.research.json#'+entity['id']]),expiresAt=expiry,note='稳定artist记录不等于纯小说账号，聚合平台整体规则保持disabled；没有真实账号黑名单。'))
    cat['publisherRules']=rules
    cat['notes']='v1.1探索包；分类最高贡献4，pending名称账号仅review不加分。没有人工确认账号封禁；父子分类不重复加分。独立测试未完成，不用于生产承诺。'
    publisher_only=copy.deepcopy(bundle);publisher_only['ruleVersion']='research-publisher-only-2026-10-26-v0.1'
    publisher_only['categories'][0]['recognition'].update(appleCategories=False,keywords=False)
    for path,obj in [('rules/research/fiction-multisource-candidate.json',bundle),('rules/research/publisher-accounts.json',publisher_only)]:
        jsonschema.Draft202012Validator(schema,format_checker=jsonschema.FormatChecker()).validate(obj)
        encoded=json.dumps(obj,ensure_ascii=False).encode()
        assert len(encoded)<2*1024*1024, 'App resource exceeds 2MiB'
        write(ROOT/path,obj)
    write(ROOT/'reports/fiction_research/v11-format-check.json',dict(jsonSchema='pass',schemaSHA256=hashlib.sha256((ROOT/'schemas/content-filter.schema.json').read_bytes()).hexdigest(),interfaceSHA256=hashlib.sha256((ROOT/'schemas/content-filter-v1.1.md').read_bytes()).hexdigest(),publisherRules=len(rules),enabledPendingReviewRules=sum(r['enabled'] for r in rules),confirmedPublisherRules=0,enabledPublisherBlockRules=0,status='example'))
    print('v1.1 JSON Schema passed;',len(rules),'publisher candidates;',sum(r['enabled'] for r in rules),'pending review enabled; no publisher blocks')

if __name__=='__main__':main()
