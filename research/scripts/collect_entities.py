#!/usr/bin/env python3
"""Public classification/publisher enrichment sidecars; baseline data remains unchanged."""
import argparse
import collections
import hashlib
import html
import json
import re
import time
import urllib.parse
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from collect import DATA, ROOT, fetch, write, local, child, plain, now

OUT=DATA/'entities'
ITUNES='http://www.itunes.com/dtds/podcast-1.0.dtd'
PAGES={
 'audiobooks':'https://podcasts.apple.com/cn/grouping/197714',
 'web-literature':'https://podcasts.apple.com/cn/grouping/197716',
 'fiction-cn':'https://podcasts.apple.com/cn/genre/1483',
 'drama-cn':'https://podcasts.apple.com/cn/genre/1484',
 'scifi-cn':'https://podcasts.apple.com/cn/genre/1485',
 'comedy-fiction-cn':'https://podcasts.apple.com/cn/genre/1486',
 'books-cn':'https://podcasts.apple.com/cn/genre/1482',
 'fiction-us':'https://podcasts.apple.com/us/genre/1483',
 'drama-us':'https://podcasts.apple.com/us/genre/1484',
 'scifi-us':'https://podcasts.apple.com/us/genre/1485',
 'comedy-fiction-us':'https://podcasts.apple.com/us/genre/1486',
}

def cached_json(folder,url,loader):
    path=OUT/folder/(hashlib.sha256(url.encode()).hexdigest()[:24]+'.json')
    if path.exists():
        return json.loads(path.read_text())
    start=time.monotonic()
    try:
        body,source=fetch(url,cap=4_000_000)
        result=dict(source=source,status='ok',data=loader(body))
    except Exception as e:
        result=dict(source=dict(url=url,fetched_at=now()),status='error',error=str(e))
    write(path,result)
    # One global process, conservative pacing for Apple and all other sources.
    time.sleep(max(0,3.2-(time.monotonic()-start)))
    return result

class Links(HTMLParser):
    def __init__(self):
        super().__init__();self.links=[];self.href=None;self.parts=[];self.h1=False;self.heading=[]
    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs)
        if tag=='a':self.href=attrs.get('href');self.parts=[]
        if tag=='h1':self.h1=True
    def handle_data(self,text):
        if self.href:self.parts.append(text)
        if self.h1:self.heading.append(text)
    def handle_endtag(self,tag):
        if tag=='h1':self.h1=False
        if tag=='a' and self.href:
            self.links.append((self.href,' '.join(self.parts).strip()));self.href=None

def parse_page(body):
    parser=Links();parser.feed(body.decode('utf-8','replace'))
    shows={};channels={}
    for url,title in parser.links:
        url=urllib.parse.urljoin('https://podcasts.apple.com',html.unescape(url))
        if urllib.parse.urlsplit(url).hostname!='podcasts.apple.com':continue
        found=re.search(r'/podcast/[^?#]*?/id([0-9]+)',url)
        if found:shows.setdefault(found[1],dict(apple_id=found[1],url=url,title=plain(title,240)['text']))
        found=re.search(r'/channel/[^?#]*?/id([0-9]+)',url)
        if found:channels.setdefault(found[1],dict(apple_channel_id=found[1],url=url,name=plain(title,160)['text']))
    return dict(heading=' '.join(parser.heading).strip(),shows=list(shows.values()),channels=list(channels.values()))

def lookup_records(body):
    keys=('collectionId','trackId','artistId','artistName','artistViewUrl','collectionName','collectionViewUrl','feedUrl','genreIds','genres','primaryGenreName','country','trackCount','releaseDate','copyright')
    return [{k:r[k] for k in keys if k in r} for r in json.loads(body).get('results',[]) if r.get('kind')=='podcast']

def parse_rss(body):
    if b'<!DOCTYPE' in body.upper() or b'<!ENTITY' in body.upper() or b'\x00' in body:
        raise ValueError('unsupported DTD/entities/UTF16')
    channel=ET.fromstring(body).find('channel')
    if channel is None:raise ValueError('not RSS 2.0')
    def paths(node,path=()):
        result=[]
        for n in node:
            if n.tag=='{'+ITUNES+'}category':
                branch=path+(n.attrib.get('text',''),)
                if branch[-1]:result.append(list(branch))
                result+=paths(n,branch)
        return result
    credits=[]
    for c in channel:
        role=None
        if c.tag=='{'+ITUNES+'}author':role='itunes_author_creator_claim'
        elif c.tag=='{'+ITUNES+'}owner':
            # Owner email is deliberately not collected.
            for n in c:
                if local(n.tag)=='name' and n.text:credits.append(dict(field='itunes:owner/name',role='rss_owner_name_claim',value=plain(n.text,200)['text']))
        elif c.tag.endswith('}publisher'):role='dc_publisher_claim'
        elif c.tag.endswith('}creator'):role='dc_creator_claim'
        elif c.tag=='copyright':role='copyright_notice_claim'
        if role and c.text:credits.append(dict(field=c.tag,role=role,value=plain(c.text,240)['text']))
    episodes=[];items=channel.findall('item')
    indices=sorted({round(i*(len(items)-1)/7) for i in range(8)}) if items else []
    cdn=collections.Counter()
    for idx in indices:
        n=items[idx]
        enclosure=next((c.attrib.get('url','') for c in n if local(c.tag)=='enclosure'),'')
        if enclosure:cdn[urllib.parse.urlsplit(enclosure).hostname]+=1
        episodes.append(dict(title=plain(child(n,['title']),300),description=plain(child(n,['description','summary','encoded'])),feed_index=idx,guid=child(n,['guid'])[:2000]))
    return dict(title=plain(child(channel,['title']),300),description=plain(child(channel,['description','summary'])),language=child(channel,['language']),credits=credits,itunes_category_paths=paths(channel),channel_link=child(channel,['link']),generator=plain(child(channel,['generator']),200)['text'],sampled_audio_endpoint_hosts=dict(cdn),feed_item_count=len(items),episodes=episodes)

def main():
    p=argparse.ArgumentParser();p.add_argument('--rss-limit',type=int,default=160);a=p.parse_args()
    shows=json.loads((DATA/'shows.json').read_text());labels=json.loads((DATA/'labels.json').read_text())
    labeled={r['show_id'] for r in labels if r['unit']=='show'}
    dev=[s for s in shows if s['split']=='dev']
    selected=[s for s in dev if s['id'] in labeled]
    counts=collections.Counter(s['author'] for s in dev)
    # Discover account portfolios independently of whether a query says fiction.
    for name,_ in counts.most_common(12):
        selected += [s for s in dev if s['author']==name][:5]
    page_results={}
    for key,url in PAGES.items():
        result=cached_json('pages',url,parse_page);page_results[key]=result
        print('PAGE',key,result['status'],result.get('data',{}).get('heading'),flush=True)
    write(OUT/'page-index.json',page_results)
    # New curated-page shows are an explicitly developmental expansion.
    pageshows={}
    for key,result in page_results.items():
        if not key.endswith('-us'):
            for row in result.get('data',{}).get('shows',[]):
                pageshows.setdefault(row['apple_id'],dict(row,discovered_pages=[]))['discovered_pages'].append(key)
    write(OUT/'curated-discoveries.json',list(pageshows.values()))
    ids=list(dict.fromkeys([s['id'] for s in selected]+list(pageshows)))
    write(OUT/'selection.json',dict(original_development_show_ids=[s['id'] for s in selected],requested_lookup_ids=ids,rss_limit=a.rss_limit))
    # Multi-ID lookup; 20 IDs per request. Keep responses/source snapshots separate.
    for i in range(0,len(ids),20):
        url='https://itunes.apple.com/lookup?'+urllib.parse.urlencode(dict(id=','.join(ids[i:i+20]),country='cn'))
        result=cached_json('lookup',url,lookup_records)
        print('LOOKUP',i,len(ids),result['status'],len(result.get('data',[])),flush=True)
    records={}
    for file in sorted((OUT/'lookup').glob('*.json')):
        cache=json.loads(file.read_text())
        for r in cache.get('data',[]):
            key=str(r['collectionId']);records[key]=dict(record=r,source=cache['source'])
    write(OUT/'apple-enriched.json',records)
    selected_ids=list(dict.fromkeys([s['id'] for s in selected]+list(pageshows)))[:a.rss_limit]
    selected_manifest=[]
    for i,key in enumerate(selected_ids):
        entry=records.get(key)
        if not entry:continue
        record=entry['record'];url=record.get('feedUrl')
        if not url:continue
        result=cached_json('rss',url,parse_rss)
        selected_manifest.append(dict(show_id=key,rss_url=url,status=result['status'],cohort='original_dev' if key in {s['id'] for s in dev} else 'curated_development_expansion',source=result['source']))
        if (i+1)%10==0:print('RSS',i+1,len(selected_ids),flush=True)
    write(OUT/'rss-manifest.json',selected_manifest)
    print('DONE',len(records),'lookup records',len(selected_manifest),'RSS attempts',flush=True)

if __name__=='__main__':main()
