#!/usr/bin/env python3
"""Read-only verification of Apple's documented episode entity and exact public RSS identities.
No private endpoint, API key, audio download or subscription-library scan.
"""
import datetime, json, pathlib, time, urllib.parse, urllib.request, xml.etree.ElementTree as ET
OUT = pathlib.Path('build/delivery/public-episode-verification')
OUT.mkdir(parents=True, exist_ok=True)
report = {'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'documentation': 'https://performance-partners.apple.com/search-api', 'searches': [], 'rss': []}

def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'QuietCast/1.1.4 (public RSS verification)'})
    start = time.monotonic()
    with urllib.request.urlopen(req, timeout=25) as response:
        data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024: raise ValueError('response exceeds app RSS size limit')
        return data, response.status, response.url, round(time.monotonic() - start, 3)

for country, term in [('CN', '星际拓荒'), ('HK', '星际拓荒'), ('US', '星际拓荒'), ('US', 'black holes')]:
    url = 'https://itunes.apple.com/search?' + urllib.parse.urlencode(dict(term=term, media='podcast', entity='podcastEpisode', country=country, limit=20, version=2))
    record = dict(country=country, term=term, url=url)
    try:
        data, status, final, elapsed = fetch(url)
        filename = country + '-' + term.replace(' ', '-') + '.json'
        (OUT / filename).write_bytes(data)
        rows = json.loads(data)['results']
        matches = [r for r in rows if r.get('kind') == 'podcast-episode' and all(t.casefold() in (r.get('trackName', '') + '\n' + r.get('description', '')).casefold() for t in term.split())]
        record.update(status=status, elapsed=elapsed, returned=len(rows), ownTextMatches=len(matches), stableIDs=sum(bool(r.get('collectionId') and r.get('trackId') and (r.get('episodeGuid') or r.get('episodeUrl'))) for r in matches), response=filename)
        # Verify only one selected candidate for the two distinct queries, not every result's RSS.
        if country == 'US' and matches:
            row = matches[0]; rss_record = dict(collectionID=row['collectionId'], episodeID=row['trackId'], title=row['trackName'], feedURL=row['feedUrl'], guid=row.get('episodeGuid'))
            try:
                lookup = 'https://itunes.apple.com/lookup?' + urllib.parse.urlencode(dict(id=row['collectionId'], entity='podcast', country=country))
                time.sleep(3.3)
                lookup_data, _, _, _ = fetch(lookup)
                (OUT / (str(row['collectionId']) + '-lookup.json')).write_bytes(lookup_data)
                catalog_feed = json.loads(lookup_data)['results'][0]['feedUrl']
                rss_record['lookupFeedURL'] = catalog_feed
                assert catalog_feed == row['feedUrl'], 'Search/Lookup feed mismatch; app fails closed'
                rss, rss_status, rss_final, rss_time = fetch(catalog_feed)
                (OUT / (str(row['collectionId']) + '.xml')).write_bytes(rss)
                items = ET.fromstring(rss).findall('./channel/item')
                guid = row.get('episodeGuid')
                aligned = [i for i in items if (i.findtext('guid') == guid if guid else any(e.get('url') == row.get('episodeUrl') for e in i.findall('enclosure')))]
                rss_record.update(status=rss_status, finalURL=rss_final, elapsed=rss_time, rssItems=len(items), exactMatches=len(aligned), playableEnclosures=sum(bool(i.find('enclosure') is not None and i.find('enclosure').get('url')) for i in aligned))
            except Exception as error: rss_record['error'] = str(error)
            report['rss'].append(rss_record)
    except Exception as error: record['error'] = str(error)
    report['searches'].append(record)
    print(json.dumps(record, ensure_ascii=False), flush=True)
    time.sleep(3.3)
(OUT / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
print(json.dumps(report['rss'], indent=2, ensure_ascii=False))
