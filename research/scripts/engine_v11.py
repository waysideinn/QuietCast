"""Research reference for A's v1.1 semantics; no parent-policy simulation."""
import ctypes
import datetime as dt
import functools
import sys
from engine import evaluate as keyword_evaluate,CF,TRANSFORM,LOCALE,WHITESPACE

@functools.lru_cache(maxsize=16000)
def identity_name(text):
    # Same punctuation-preserving Foundation transform/folding as A IdentityName.
    original=CF.CFStringCreateWithCString(None,text.encode(),0x08000100)
    mutable=CF.CFStringCreateMutableCopy(None,0,original)
    try:
        if not CF.CFStringTransform(mutable,None,TRANSFORM,False):raise ValueError('name transform failed')
        CF.CFStringFold(mutable,1|256,LOCALE)
        buffer=ctypes.create_string_buffer(len(text.encode())*4+256)
        if not CF.CFStringGetCString(mutable,buffer,len(buffer),0x08000100):raise ValueError('name conversion failed')
        result=buffer.value.decode().lower()
    finally:
        CF.CFRelease(original);CF.CFRelease(mutable)
    def ws(c):return CF.CFCharacterSetIsLongCharacterMember(WHITESPACE,ord(c))
    while result and ws(result[0]):result=result[1:]
    while result and ws(result[-1]):result=result[:-1]
    return result

def date(value):return dt.datetime.fromisoformat(value.replace('Z','+00:00'))

def category_match(rule,o):
    if o['namespace'] not in ('apple.podcasts.genre','rss.itunes.category'):return False
    m=rule['match']
    if m['primaryOnly'] and o.get('primary') is not True:return False
    return (o['namespace']=='apple.podcasts.genre' and o.get('id') in m['ids']) or identity_name(o['name']) in list(map(identity_name,m['names'])) or [identity_name(x) for x in o.get('path',[])] in [[identity_name(x) for x in p] for p in m['paths']]

def evaluate(bundle,fixture,at):
    now=date(at);c=bundle['categories'][0]
    config=c.get('recognition',dict(appleCategories=True,publishers=True,keywords=True,combination='score',metadataMaxAgeDays=30))
    raw=fixture['fields'];complete=fixture['rss_complete'];show_id=fixture['feed_url']
    category_score=0;publisher_score=0
    signals=dict(appleCategories=False,publishers=False,keywords=False)
    review=False;direct=False;evidence=[]
    def fresh(o):return -300<=(now-date(o['observedAt'])).total_seconds()<=config['metadataMaxAgeDays']*86400
    if config['appleCategories']:
        for rule in c.get('classificationRules',[]):
            if not rule['enabled']:continue
            matches=[o for o in fixture['classificationObservations'] if category_match(rule,o)]
            if not matches:continue
            o=next((o for o in matches if fresh(o)),matches[0])
            stale=not fresh(o)
            if not stale:signals['appleCategories']=True
            if stale or rule['action']=='review':review=True
            else:
                signals['appleCategories']=True
                if rule['action']=='block':direct=True
                else:category_score=max(category_score,rule['score'])
            evidence.append(dict(ruleID=rule['id'],family='appleCategories',kind='staleMetadata' if stale else 'classification',source=o['source'],namespace=o['namespace'],matchedIdentity=o.get('id')))
    if config['publishers']:
        for rule in c.get('publisherRules',[]):
            confirmation=rule['confirmation']
            if not rule['enabled'] or confirmation['status']=='rejected' or date(rule['expiresAt'])<=now or date(confirmation['at'])>now:continue
            if rule['scope']=='selectedShows' and show_id not in rule['showIDs']:continue
            identities=fixture['publisherIdentities']
            stable=[o for o in identities if o['namespace']=='apple.podcasts.artist' and o['source']!='rss' and any(i['namespace']==o['namespace'] and i['id']==o.get('id') for i in rule['identities'])]
            names=list(map(identity_name,rule['names']))
            named=next((o for o in identities if identity_name(o['name']) and identity_name(o['name']) in names),None)
            fallback=dict(namespace='rss.itunes.author',name=raw['author'],role='unknown',source='rss',sourceURL=show_id,observedAt=at) if raw['author'] and identity_name(raw['author']) in names else None
            match=next((o for o in stable if fresh(o)),None) or next(iter(stable),None) or named or fallback
            if not match:continue
            stable_match=match in stable
            role_safe=rule['scope']=='selectedShows' or (rule['role'] in ('publisher','creator') and match['role']!='aggregator')
            authoritative=stable_match and fresh(match) and confirmation['status']=='confirmed' and role_safe
            if authoritative:signals['publishers']=True
            kind='staleMetadata' if not fresh(match) else 'identityUnavailable' if not stable_match else 'publisherReview' if not authoritative else 'publisher'
            if not authoritative or rule['action']=='review':review=True
            else:
                signals['publishers']=True
                if rule['action']=='block':direct=True
                else:publisher_score=max(publisher_score,rule['score'])
            evidence.append(dict(ruleID=rule['id'],family='publishers',kind=kind,namespace=match['namespace'],matchedIdentity=match.get('id'),confirmation=confirmation['status']))
        identity_required=any(r['enabled'] and r['action']!='review' and r['confirmation']['status']=='confirmed' and date(r['expiresAt'])>now and date(r['confirmation']['at'])<=now and (r['scope']=='allShows' or show_id in r['showIDs']) for r in c.get('publisherRules',[]))
        fresh_stable=any(o['namespace']=='apple.podcasts.artist' and o['source']!='rss' and o.get('id') and str(o['id']).isnumeric() and fresh(o) for o in fixture['publisherIdentities'])
        if identity_required and not fresh_stable:
            review=True
            if not any(e['family']=='publishers' and e['kind']=='identityUnavailable' for e in evidence):
                evidence.append(dict(ruleID='publisher-identity-required',family='publishers',kind='identityUnavailable',namespace='apple.podcasts.artist',matchedIdentity=None,confirmation='unavailable'))
    keyword_fields=dict(raw)
    if any(e['family']=='appleCategories' and e['kind']!='staleMetadata' for e in evidence):keyword_fields['showCategories']=''
    if any(e['family']=='publishers' and e['kind']=='publisher' for e in evidence):keyword_fields['author']=''
    kw=keyword_evaluate(dict(categories=[c]),keyword_fields,show_id,fixture.get('episode_id') or '',True) if config['keywords'] else dict(score=0,evidence=[])
    keyword_score=kw['score'];signals['keywords']=keyword_score>0
    enabled=[key for key in signals if config[key]]
    joint_ready=config['combination']=='score' or (bool(enabled) and all(signals[k] for k in enabled))
    score=keyword_score+category_score+publisher_score if joint_ready else 0
    decision='block' if (joint_ready and direct) or score>=c['thresholds']['block'] else 'review' if review or score>=c['thresholds']['review'] or not complete else 'allow'
    return dict(decision=decision,score=score,signals=signals,jointReady=joint_ready,evidence=evidence,keywordScore=keyword_score,categoryScore=category_score,publisherScore=publisher_score)
