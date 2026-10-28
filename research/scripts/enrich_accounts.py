#!/usr/bin/env python3
"""Supplement failed/missing storefront lookups, public channel rosters and public account probes."""
import argparse
import collections
import json
import re
import urllib.parse
from collect import DATA,write
from collect_entities import OUT,cached_json,lookup_records,parse_page,parse_rss

def parse_album_page(body):
    # Only explicit public profile links count as candidate account IDs.
    # Do not extract arbitrary uid values from recommendations or tracking scripts.
    text=body.decode('utf-8','replace')
    links=sorted(set(re.findall(r'href=["\'](?:https?://www\.ximalaya\.com)?(/zhubo/[0-9]+)["\']',text)))
    return dict(profile_links=links,identity_status='ambiguous_multiple_public_profile_links' if len(links)>1 else 'single_public_profile_link_candidate' if links else 'not_available_in_public_profile_links',note='A linked profile is not yet verified as album owner. No regex over arbitrary uid scripts.')

def main():
    p=argparse.ArgumentParser();p.add_argument('--rss-limit',type=int,default=35);a=p.parse_args()
    pages=json.loads((OUT/'page-index.json').read_text())
    channel_rows={}
    for result in pages.values():
        requested=urllib.parse.urlsplit(result['source']['url'])
        actual=urllib.parse.urlsplit(result['source'].get('final_url',result['source']['url']))
        if not requested.path.startswith('/cn/') or requested.path!=actual.path:
            continue  # Redirected storefront pages are not the requested taxonomy.
        for c in result.get('data',{}).get('channels',[]):channel_rows[c['apple_channel_id']]=c
    channel_results={}
    for key,row in sorted(channel_rows.items()):
        channel_results[key]=cached_json('channels',row['url'],parse_page)
        print('CHANNEL',key,channel_results[key]['status'],flush=True)
    write(OUT/'channel-index.json',channel_results)
    records=json.loads((OUT/'apple-enriched.json').read_text())
    base=json.loads((DATA/'shows.json').read_text());labels=json.loads((DATA/'labels.json').read_text())
    target={r['show_id'] for r in labels if r['unit']=='show'}
    discovered=json.loads((OUT/'curated-discoveries.json').read_text())
    target.update(r['apple_id'] for r in discovered)
    missing=sorted(target-set(records))
    # Some original shows were found only in TW; absence in CN is not deletion.
    for i in range(0,len(missing),20):
        url='https://itunes.apple.com/lookup?'+urllib.parse.urlencode(dict(id=','.join(missing[i:i+20]),country='tw'))
        result=cached_json('lookup-fallback',url,lookup_records)
        for row in result.get('data',[]):records.setdefault(str(row['collectionId']),dict(record=row,source=result['source']))
        print('TW FALLBACK',i,len(missing),len(result.get('data',[])),flush=True)
    write(OUT/'apple-enriched.json',records)
    # Prioritize real border cases by ID obtained from Apple public page/lookup;
    # page link text may be only a category label, so use lookup titles.
    border=[key for key,row in records.items() if any(t in row['record'].get('collectionName','') for t in ['不止读书','蒙曼讲红楼梦','野地电波','文化有限','北大教授','人生书单','解读','纪实','知识','有声杂志'])]
    border+= [r['show_id'] for r in labels if r['unit']=='show']
    attempts=[]
    for key in list(dict.fromkeys(border))[:a.rss_limit]:
        if key not in records:continue
        url=records[key]['record'].get('feedUrl')
        if not url:continue
        result=cached_json('rss',url,parse_rss)
        attempts.append(dict(show_id=key,rss_url=url,status=result['status'],source=result['source']))
    write(OUT/'supplemental-rss-manifest.json',attempts)
    # Probe a few high-frequency creator clusters. No private account API.
    authors=collections.Counter(s['author'] for s in base if s['split']=='dev')
    probes=[]
    for name,_ in authors.most_common(6):
        row=next((s for s in base if s['split']=='dev' and s['author']==name and 'ximalaya.com/album/' in s['feed_url']),None)
        if row:
            url=row['feed_url'].replace('http:','https:').removesuffix('.xml')
            result=cached_json('account-probes',url,parse_album_page)
            probes.append(dict(creator_name=name,show_id=row['id'],result=result))
    write(OUT/'account-probes.json',probes)
    print('DONE supplement',len(records),'lookups',len(attempts),'RSS',len(probes),'public profile probes',flush=True)

if __name__=='__main__':main()
