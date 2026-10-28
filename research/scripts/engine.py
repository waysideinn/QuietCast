"""Schema v1 research reference implementation; no Swift/App source modifications."""
import ctypes
import functools
import html
import re
import sys
import unicodedata
from urllib.parse import urlsplit, urlunsplit

FIELDS = ['showTitle', 'showDescription', 'showCategories', 'author', 'episodeTitle', 'episodeDescription', 'rssMetadata']

if sys.platform == 'darwin':
    CF = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    CF.CFStringCreateWithCString.restype = ctypes.c_void_p
    CF.CFStringCreateMutableCopy.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
    CF.CFStringCreateMutableCopy.restype = ctypes.c_void_p
    CF.CFStringTransform.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_bool]
    CF.CFStringTransform.restype = ctypes.c_bool
    CF.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    CF.CFStringGetCString.restype = ctypes.c_bool
    CF.CFRelease.argtypes = [ctypes.c_void_p]
    CF.CFStringFold.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p]
    CF.CFStringFold.restype = None
    CF.CFLocaleCreate.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    CF.CFLocaleCreate.restype = ctypes.c_void_p
    CF.CFCharacterSetGetPredefined.argtypes=[ctypes.c_long]
    CF.CFCharacterSetGetPredefined.restype=ctypes.c_void_p
    CF.CFCharacterSetIsLongCharacterMember.argtypes=[ctypes.c_void_p,ctypes.c_uint32]
    CF.CFCharacterSetIsLongCharacterMember.restype=ctypes.c_bool
    WHITESPACE=CF.CFCharacterSetGetPredefined(3)
    PUNCTUATION=CF.CFCharacterSetGetPredefined(11)
    TRANSFORM = CF.CFStringCreateWithCString(None, b'Traditional-Simplified', 0x08000100)
    LOCALE_NAME = CF.CFStringCreateWithCString(None,b'zh_CN',0x08000100)
    LOCALE = CF.CFLocaleCreate(None,LOCALE_NAME)
    CF.CFRelease(LOCALE_NAME)

@functools.lru_cache(maxsize=16000)
def removed_character(c):
    if sys.platform=='darwin':
        return bool(CF.CFCharacterSetIsLongCharacterMember(WHITESPACE,ord(c)) or CF.CFCharacterSetIsLongCharacterMember(PUNCTUATION,ord(c)))
    return c.isspace() or unicodedata.category(c).startswith('P')

@functools.lru_cache(maxsize=16000)
def normalize(text):
    # Match v1 Swift contract's two explicit HTML entity replacements.
    text = re.sub('<[^>]+>', ' ', text[:20000]).replace('&nbsp;', ' ').replace('&amp;', '&')
    if sys.platform == 'darwin':
        original = CF.CFStringCreateWithCString(None, text.encode(), 0x08000100)
        mutable = CF.CFStringCreateMutableCopy(None, 0, original)
        try:
            if not CF.CFStringTransform(mutable, None, TRANSFORM, False):
                raise RuntimeError('Traditional-Simplified transform failed')
            # Foundation's width/case/diacritic folding is intentionally narrower
            # than Unicode NFKC/NFKD (e.g. enclosed numerals and Japanese kana).
            CF.CFStringFold(mutable, 1 | 128 | 256, LOCALE)
            buf = ctypes.create_string_buffer(len(text.encode()) * 4 + 256)
            if not CF.CFStringGetCString(mutable, buf, len(buf), 0x08000100):
                raise RuntimeError('Unicode conversion failed')
            text = buf.value.decode()
        finally:
            CF.CFRelease(original)
            CF.CFRelease(mutable)
    else:
        # Explicit dependency on non-macOS rather than silently skipping traditional Chinese.
        from opencc import OpenCC
        text = OpenCC('t2s').convert(text)
        text = ''.join(c for c in unicodedata.normalize('NFKD',unicodedata.normalize('NFKC',text)) if not unicodedata.category(c).startswith('M'))
    text=text.lower()
    return ''.join(c for c in text if not removed_character(c))

def fields(show, rss=None, episode=None):
    rss = rss or {}
    episode = episode or {}
    return dict(showTitle=rss.get('title', {}).get('text') or show['title'], showDescription=rss.get('description', {}).get('text', ''), showCategories='\n'.join(show['genres']), author=show['author'], episodeTitle=episode.get('title', {}).get('text', ''), episodeDescription=episode.get('description', {}).get('text', ''), rssMetadata='\n'.join(str(v) for v in rss.get('metadata', {}).values()))

def evaluate(bundle, raw, show_id='', episode_id='', rss_complete=True):
    texts = {f: normalize(raw.get(f, '')) for f in FIELDS}
    cats = [c for c in bundle['categories'] if c['enabled']]
    # More-specific episode layer precedes show layer across all categories.
    for layer, identity in [('episode', episode_id), ('show', show_id)]:
        if identity:
            for action in ('block', 'allow'):
                matched = [c['id'] for c in cats if identity in c[layer + action.title() + 'list']]
                if matched:
                    return dict(decision=action, score=0, categoryIDs=matched, evidence=[dict(kind=layer+'List', action=action)], reason='curated-list')
    results = []
    for cat in cats:
        sums = dict(strong=0, normal=0, exclusion=0)
        evidence = []
        weights = cat['fieldWeights']
        for name, kind in [('strongKeywords','strong'), ('keywords','normal'), ('combinationKeywords','normal'), ('regexRules','normal'), ('exclusions','exclusion')]:
            for rule in cat[name]:
                fs = rule['fields']
                if name == 'combinationKeywords':
                    terms = list(map(normalize, rule['terms']))
                    if rule['scope'] == 'sameField':
                        hits = [f for f in fs if all(t in texts[f] for t in terms)]
                        weight = max((weights[f] for f in hits), default=0)
                    else:
                        per = [[f for f in fs if t in texts[f]] for t in terms]
                        hits = sorted(set(f for h in per for f in h)) if all(per) else []
                        weight = min((max(weights[f] for f in h) for h in per), default=0) if all(per) else 0
                else:
                    hits = [f for f in fs if (re.search(rule['pattern'], texts[f]) if name == 'regexRules' else normalize(rule['term']) in texts[f])]
                    weight = max((weights[f] for f in hits), default=0)
                if hits and weight:
                    contribution = rule['score'] * weight
                    sums[kind] += contribution
                    evidence.append(dict(ruleID=rule['id'], kind={'strongKeywords':'strong','keywords':'keyword','combinationKeywords':'combination','regexRules':'regex','exclusions':'exclusion'}[name], fields=hits, contribution=-contribution if kind=='exclusion' else contribution, expression=rule.get('term', rule.get('terms', rule.get('pattern')))))
        score = sums['strong'] + max(0, sums['normal'] - sums['exclusion'])
        decision = 'block' if score >= cat['thresholds']['block'] else 'review' if score >= cat['thresholds']['review'] or not rss_complete else 'allow'
        results.append(dict(decision=decision, score=score, categoryIDs=[cat['id']] if score>=cat['thresholds']['review'] else [], evidence=evidence, reason='score' if rss_complete else 'rss-incomplete'))
    if not results:
        return dict(decision='allow' if rss_complete else 'review',score=0,categoryIDs=[],evidence=[],reason='no-enabled-category')
    strictest=max(results,key=lambda r:{'allow':0,'review':1,'block':2}[r['decision']])
    return dict(decision=strictest['decision'],score=max(r['score'] for r in results),categoryIDs=[c for r in results for c in r['categoryIDs']],evidence=[e for r in results for e in r['evidence']],reason=strictest['reason'])
