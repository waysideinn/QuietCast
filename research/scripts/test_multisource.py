"""Safety/semantic regressions for v1.1 research adapter, using synthetic fixtures only."""
import copy
import unittest
from engine_v11 import evaluate,identity_name
from test_engine import bundle

NOW='2026-10-26T08:00:00Z'

def fixture():
    return dict(fields=dict(showTitle='知识访谈',showDescription='',showCategories='',author='甲',episodeTitle='',episodeDescription='',rssMetadata=''),feed_url='https://example.invalid/feed',rss_complete=True,classificationObservations=[],publisherIdentities=[])

def package():
    b=bundle();c=b['categories'][0]
    c.update(recognition=dict(appleCategories=True,publishers=True,keywords=True,combination='score',metadataMaxAgeDays=30),classificationRules=[],publisherRules=[])
    return b

def category_rule():return dict(id='cat',enabled=True,match=dict(ids=['1483','1484'],names=['Fiction'],paths=[['Fiction','Drama']],primaryOnly=False),action='score',score=4)

def pub_rule():return dict(id='pub',enabled=True,identities=[dict(namespace='apple.podcasts.artist',id='123')],names=['甲'],role='publisher',scope='allShows',showIDs=[],action='block',score=10,confirmation=dict(status='pending',at='2026-10-26T00:00:00Z'),expiresAt='2026-11-25T00:00:00Z')

class MultisourceSemantics(unittest.TestCase):
    def test_identity_preserves_punctuation_and_internal_spaces(self):
        self.assertNotEqual(identity_name('甲.乙'),identity_name('甲乙'))
        self.assertNotEqual(identity_name('A B'),identity_name('AB'))
        self.assertEqual(identity_name(' 小說 '),identity_name('小说'))

    def test_pending_stable_identity_cannot_block(self):
        b=package();b['categories'][0]['publisherRules']=[pub_rule()];f=fixture()
        f['publisherIdentities']=[dict(namespace='apple.podcasts.artist',id='123',name='甲',role='unknown',source='appleLookup',observedAt=NOW)]
        self.assertEqual(evaluate(b,f,NOW)['decision'],'review')

    def test_name_only_confirmed_rule_still_cannot_block(self):
        b=package();r=pub_rule();r['confirmation']['status']='confirmed';b['categories'][0]['publisherRules']=[r]
        self.assertEqual(evaluate(b,fixture(),NOW)['decision'],'review')

    def test_same_family_parent_child_do_not_stack(self):
        b=package();c=b['categories'][0];c['classificationRules']=[category_rule(),dict(category_rule(),id='child',score=5)];f=fixture()
        f['classificationObservations']=[dict(namespace='apple.podcasts.genre',id=i,name=n,path=[],primary=True,source='appleLookup',observedAt=NOW) for i,n in [('1483','Fiction'),('1484','Drama')]]
        r=evaluate(b,f,NOW);self.assertEqual(r['score'],5);self.assertEqual(r['decision'],'review')

    def test_generic_rss_category_is_not_itunes_fiction(self):
        b=package();b['categories'][0]['classificationRules']=[category_rule()];f=fixture()
        f['classificationObservations']=[dict(namespace='rss.category',id='1483',name='Fiction',path=[],source='rss',observedAt=NOW)]
        self.assertEqual(evaluate(b,f,NOW)['decision'],'allow')

    def test_pending_is_not_third_source(self):
        b=package();c=b['categories'][0];c['recognition']['combination']='allEnabledSources';c['publisherRules']=[pub_rule()]
        f=fixture();r=evaluate(b,f,NOW)
        self.assertFalse(r['jointReady']);self.assertEqual(r['decision'],'review')

    def test_stale_category_requires_review_without_score(self):
        b=package();b['categories'][0]['classificationRules']=[category_rule()];f=fixture()
        f['classificationObservations']=[dict(namespace='apple.podcasts.genre',id='1483',name='Fiction',path=[],source='appleLookup',observedAt='2025-01-01T00:00:00Z')]
        r=evaluate(b,f,NOW);self.assertEqual(r['decision'],'review');self.assertEqual(r['score'],0)

    def test_aggregator_allshows_not_authoritative_even_if_confirmed(self):
        b=package();r=pub_rule();r['role']='aggregator';r['confirmation']['status']='confirmed';b['categories'][0]['publisherRules']=[r];f=fixture()
        f['publisherIdentities']=[dict(namespace='apple.podcasts.artist',id='123',name='甲',role='aggregator',source='appleLookup',observedAt=NOW)]
        self.assertEqual(evaluate(b,f,NOW)['decision'],'review')

    def test_active_confirmed_restriction_unknown_identity_requires_review(self):
        b=package();r=pub_rule();r['confirmation']['status']='confirmed';b['categories'][0]['publisherRules']=[r];f=fixture();f['fields']['author']='无关显示名称'
        result=evaluate(b,f,NOW)
        self.assertEqual(result['decision'],'review')
        self.assertFalse(result['signals']['publishers'])
        self.assertIn('publisher-identity-required',[e['ruleID'] for e in result['evidence']])

    def test_pending_rule_does_not_review_every_unknown_account(self):
        b=package();b['categories'][0]['publisherRules']=[pub_rule()];f=fixture();f['fields']['author']='无关显示名称'
        self.assertEqual(evaluate(b,f,NOW)['decision'],'allow')

    def test_structured_category_removes_derived_keyword_points(self):
        b=package();c=b['categories'][0];c['classificationRules']=[category_rule()];c['keywords']=[dict(id='derived',term='Fiction',fields=['showCategories'],score=10)];f=fixture();f['fields']['showCategories']='Fiction'
        f['classificationObservations']=[dict(namespace='apple.podcasts.genre',id='1483',name='Fiction',path=[],source='appleLookup',observedAt=NOW)]
        result=evaluate(b,f,NOW)
        self.assertEqual(result['keywordScore'],0);self.assertEqual(result['score'],4)

    def test_effective_publisher_removes_author_keyword_points(self):
        b=package();c=b['categories'][0];r=pub_rule();r['confirmation']['status']='confirmed';r['action']='score';r['score']=4;c['publisherRules']=[r];c['keywords']=[dict(id='derived',term='甲',fields=['author'],score=10)];f=fixture()
        f['publisherIdentities']=[dict(namespace='apple.podcasts.artist',id='123',name='甲',role='unknown',source='appleLookup',observedAt=NOW)]
        result=evaluate(b,f,NOW);self.assertEqual(result['keywordScore'],0);self.assertEqual(result['score'],4)

if __name__=='__main__':unittest.main()
