#!/usr/bin/env python3
"""Public Apple metadata + bounded RSS sampling; no audio requests. Python 3.9+."""
import argparse
import concurrent.futures
import datetime as dt
import hashlib
import html
import ipaddress
import json
import random
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'datasets/fiction_research'
GROUPS = {
    'fiction': '有声小说 小说演播 广播剧 玄幻 修仙 都市爽文 重生 穿越 言情 总裁 甜宠 末世 无限流 网游 赘婿 悬疑小说 恐怖小说 武侠 科幻小说 三体 红楼梦 西游记 三国演义 童话连载 有声书 多人剧 完结小说 盗墓 斗罗大陆 凡人修仙传'.split(),
    'normal': '科技播客 历史播客 人文播客 商业播客 教育播客 访谈 新闻 心理学 科学播客 生活播客 电影评论 读书播客 哲学 旅行 经济 编程 女性 健康 文化 艺术'.split(),
    'boundary': '小说评论 文学赏析 历史故事 穿越宇宙 章节课程 有声杂志 第001期 犯罪纪实 电影解析 儿童科普 人物传记 读书分享 小说创作 推理评论 故事FM 文学史 真实故事'.split(),
}

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding='utf-8')
    tmp.replace(path)

def public_url(url):
    p = urllib.parse.urlsplit(url)
    if p.scheme not in ('http', 'https') or not p.hostname or p.username or p.password:
        raise ValueError('nonpublic URL scheme or credentials')
    for addr in socket.getaddrinfo(p.hostname, p.port or (443 if p.scheme == 'https' else 80)):
        if not ipaddress.ip_address(addr[4][0]).is_global:
            raise ValueError('nonpublic address')
    return url

class PublicRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        public_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)

OPENER = urllib.request.build_opener(PublicRedirect())

def fetch(url, cap=2_000_000):
    public_url(url)
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'QuietCastMetadataResearch/0.1 (public metadata only)', 'Accept': 'application/json, application/rss+xml, application/xml, text/xml'})
            with OPENER.open(req, timeout=18) as r:
                body = r.read(cap + 1)
                if len(body) > cap:
                    raise ValueError('response exceeds bounded metadata limit')
                return body, {'url': url, 'final_url': r.url, 'fetched_at': now(), 'status': r.status, 'sha256': hashlib.sha256(body).hexdigest()}
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == 2:
                raise
            retry = e.headers.get('Retry-After', '')
            try:
                delay = float(retry)
            except ValueError:
                try:
                    import email.utils
                    delay = max(0, email.utils.parsedate_to_datetime(retry).timestamp() - time.time())
                except (ValueError, TypeError):
                    delay = 4 * 2 ** attempt
            time.sleep(min(max(delay, 3.2), 300))
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt == 2:
                raise
            time.sleep(4 * 2 ** attempt + random.random())

def canonical(url):
    p = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((p.scheme.lower(), p.netloc.lower(), p.path, p.query, ''))

def search(args):
    keep = ('collectionId', 'trackId', 'collectionName', 'artistName', 'artistId', 'artistViewUrl', 'feedUrl', 'collectionViewUrl', 'genres', 'genreIds', 'trackCount', 'releaseDate', 'country', 'primaryGenreName', 'copyright')
    tasks = [(g, term, country) for g, terms in GROUPS.items() for term in terms for country in args.countries.split(',')]
    if args.limit_queries:
        tasks = tasks[:args.limit_queries]
    for i, (group, term, country) in enumerate(tasks):
        key = hashlib.sha256(f'{country}:{term}'.encode()).hexdigest()[:20]
        path = DATA / 'search' / (key + '.json')
        if path.exists() and not args.refresh:
            continue
        url = 'https://itunes.apple.com/search?' + urllib.parse.urlencode(dict(term=term, media='podcast', entity='podcast', country=country, limit=200))
        start = time.monotonic()
        try:
            body, source = fetch(url)
            obj = json.loads(body)
            records = [{k: r[k] for k in keep if k in r} for r in obj.get('results', []) if r.get('kind') == 'podcast']
            write(path, dict(group=group, term=term, country=country, source=source, result_count=len(records), records=records))
            print(f'{i+1}/{len(tasks)} {country} {group} {term}: {len(records)}', flush=True)
        except Exception as e:
            write(DATA / 'errors' / (key + '.json'), dict(url=url, fetched_at=now(), error=str(e)))
            print(f'{term}: ERROR {e}', flush=True)
        time.sleep(max(0, 3.2 - (time.monotonic() - start)))
    normalize()

def normalize():
    records = {}
    aliases = {}
    for file in sorted((DATA / 'search').glob('*.json')):
        batch = json.loads(file.read_text())
        for r in batch['records']:
            apple_id = str(r.get('collectionId') or r.get('trackId'))
            feed = canonical(r.get('feedUrl', ''))
            key = aliases.get(feed, apple_id) if feed else apple_id
            if key not in records:
                records[key] = dict(apple_ids=[], title=r.get('collectionName', ''), author=r.get('artistName', ''), feed_url=feed, genres=r.get('genres', []), apple_episode_count=r.get('trackCount'), apple_url=r.get('collectionViewUrl'), discoveries=[])
            row = records[key]
            if apple_id not in row['apple_ids']:
                row['apple_ids'].append(apple_id)
            if feed:
                aliases[feed] = key
            row['discoveries'].append(dict(term=batch['term'], group=batch['group'], country=batch['country'], source=batch['source']))
    rows = []
    for key, row in sorted(records.items()):
        row['id'] = key
        # Discovery only; labels must be supplied by a human/explicit metadata review.
        row['split'] = 'test' if int(hashlib.sha256((row['feed_url'] or key).encode()).hexdigest()[:8], 16) % 10 < 3 else 'dev'
        rows.append(row)
    write(DATA / 'shows.json', rows)
    print(f'Unique candidate shows: {len(rows)}', flush=True)

def local(tag):
    return tag.rsplit('}', 1)[-1]

def plain(text, limit=600):
    text = re.sub(r'(?is)<script[^>]*>.*?</script>|<style[^>]*>.*?</style>', '', text or '')
    text = html.unescape(re.sub('<[^>]+>', ' ', text))
    # Remove email addresses in public descriptions; no contact data needed.
    text = re.sub(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}', '[email removed]', text)
    text = re.sub(r'(?i)(微信号|微信公众号|公众号|QQ群|粉丝群|交流群|群号|QQ号|微博|V博|微信)\s*[:：]?\s*[A-Za-z0-9_-]{5,}', r'\1[contact removed]', text)
    text = re.sub(r'(?<!\d)1[3-9]\d{9}(?!\d)', '[phone removed]', text)
    text = re.sub(r'\s+', ' ', text).strip()
    return {'text': text[:limit], 'truncated': len(text) > limit}

def child(node, names):
    for name in names:
        for c in node:
            if local(c.tag) == name and c.text:
                return c.text
    return ''

def rss_one(row):
    path = DATA / 'rss' / (row['id'] + '.json')
    if path.exists():
        return 'cached'
    if not row['feed_url']:
        return 'no-feed'
    try:
        body, source = fetch(row['feed_url'])
        if b'<!DOCTYPE' in body.upper() or b'<!ENTITY' in body.upper():
            raise ValueError('DTD/entity rejected')
        root = ET.fromstring(body)
        channel = root.find('channel')
        if channel is None:
            raise ValueError('not RSS 2.0 channel')
        items = [n for n in channel if local(n.tag) == 'item']
        # Deterministic spread across feed ordering, not only latest episodes.
        indices = sorted({round(i * (len(items) - 1) / 7) for i in range(8)}) if items else []
        episodes = []
        for idx in indices:
            n = items[idx]
            guid = child(n, ['guid'])
            enclosure = next((c.attrib.get('url', '') for c in n if local(c.tag) == 'enclosure'), '')
            identity = guid or enclosure
            episodes.append(dict(id=hashlib.sha256((row['feed_url']+'\n'+identity).encode()).hexdigest() if identity else None, guid=guid[:2000], title=plain(child(n, ['title']), 400), description=plain(child(n, ['description', 'summary', 'encoded'])), published_at=child(n, ['pubDate']), feed_index=idx))
        metadata = {local(c.tag): (c.text or '')[:200] for c in channel if local(c.tag) in ('language', 'type', 'explicit', 'medium', 'keywords')}
        write(path, dict(show_id=row['id'], feed_url=row['feed_url'], source=source, status='ok', title=plain(child(channel, ['title']), 400), description=plain(child(channel, ['description', 'summary'])), metadata=metadata, feed_item_count=len(items), episodes=episodes))
        return 'ok'
    except Exception as e:
        write(path, dict(show_id=row['id'], feed_url=row['feed_url'], fetched_at=now(), status='error', error=str(e)))
        return 'error'

def rss(args):
    rows = json.loads((DATA / 'shows.json').read_text())
    # Round-robin across discovery groups and stable ID ordering.
    grouped = {g: [] for g in GROUPS}
    for row in rows:
        groups = {d['group'] for d in row['discoveries']}
        g = 'boundary' if 'boundary' in groups else ('normal' if 'normal' in groups else 'fiction')
        grouped[g].append(row)
    selected = []
    for group in grouped.values():
        # Prioritize Chinese-titled discovery without silently excluding English
        # show names; language eligibility still requires metadata review.
        group.sort(key=lambda row: (not bool(re.search(r'[\u3400-\u9fff]', row['title'])), row['id']))
    for i in range(max(map(len, grouped.values()), default=0)):
        for group in grouped.values():
            if i < len(group):
                selected.append(group[i])
    if args.limit_shows:
        selected = selected[:args.limit_shows]
    counts = {}
    # Three workers max, but serialize all requests to the same hostname.
    import threading
    locks = {}
    def run(row):
        host = urllib.parse.urlsplit(row['feed_url']).hostname or ''
        with locks[host]:
            result = rss_one(row)
            if result != 'cached':
                time.sleep(1)
            return result
    for row in selected:
        host = urllib.parse.urlsplit(row['feed_url']).hostname or ''
        locks.setdefault(host, threading.Lock())
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for i, status in enumerate(pool.map(run, selected)):
            counts[status] = counts.get(status, 0) + 1
            if (i+1) % 25 == 0:
                print(f'RSS {i+1}/{len(selected)} {counts}', flush=True)
    print(counts, flush=True)

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['search', 'normalize', 'rss'])
    p.add_argument('--countries', default='cn,tw')
    p.add_argument('--limit-queries', type=int, default=0)
    p.add_argument('--limit-shows', type=int, default=0)
    p.add_argument('--refresh', action='store_true')
    a = p.parse_args()
    DATA.mkdir(parents=True, exist_ok=True)
    {'search': lambda: search(a), 'normalize': normalize, 'rss': lambda: rss(a)}[a.command]()
