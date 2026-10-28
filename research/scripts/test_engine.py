"""Meaningful contract checks for research scores/identity/combinations, no App edits."""
import copy
import unittest
from engine import evaluate, normalize, FIELDS

def bundle():
    return {'categories':[dict(id='fiction-audiobooks',enabled=True,thresholds={'review':4,'block':10},fieldWeights={f:1 for f in FIELDS},strongKeywords=[],keywords=[],combinationKeywords=[],exclusions=[],regexRules=[],showAllowlist=[],showBlocklist=[],episodeAllowlist=[],episodeBlocklist=[])]}

def keyword(term,score=10,fields=None):
    return dict(id=term,term=term,score=score,fields=fields or ['showTitle','showDescription'])

class Contract(unittest.TestCase):
    def test_chinese_width_and_diacritics(self):
        self.assertEqual(normalize('《繁體小說》 第００１章 Café！'),'繁体小说第001章cafe')

    def test_foundation_zero_width_space(self):
        self.assertEqual(normalize('有声\u200b小说'),'有声小说')

    def test_missing_rss_requires_review(self):
        self.assertEqual(evaluate(bundle(),{},rss_complete=False)['decision'],'review')

    def test_repeat_does_not_stack_and_uses_max_weight(self):
        b=bundle(); c=b['categories'][0]; c['keywords']=[keyword('小说',2)];c['fieldWeights']['showTitle']=1.5
        self.assertEqual(evaluate(b,{'showTitle':'小说小说小说','showDescription':'小说'})['score'],3)

    def test_exclusion_cannot_cancel_strong(self):
        b=bundle(); c=b['categories'][0];c['strongKeywords']=[keyword('演播')];c['exclusions']=[keyword('书评',100)]
        self.assertEqual(evaluate(b,{'showTitle':'演播书评'})['decision'],'block')

    def test_exclusion_can_cancel_normal(self):
        b=bundle();c=b['categories'][0];c['keywords']=[keyword('小说')];c['exclusions']=[keyword('书评',100)]
        self.assertEqual(evaluate(b,{'showTitle':'小说书评'})['decision'],'allow')

    def test_same_field_combination(self):
        b=bundle();c=b['categories'][0];c['combinationKeywords']=[dict(id='pair',terms=['小说','演播'],score=10,fields=['showTitle','showDescription'],scope='sameField')]
        self.assertEqual(evaluate(b,{'showTitle':'小说','showDescription':'演播'})['decision'],'allow')
        self.assertEqual(evaluate(b,{'showTitle':'小说演播'})['decision'],'block')

    def test_any_field_combination_weakest_max_weight(self):
        b=bundle();c=b['categories'][0];c['combinationKeywords']=[dict(id='pair',terms=['小说','演播'],score=10,fields=['showTitle','showDescription'],scope='anyField')]; c['fieldWeights']['showTitle']=2;c['fieldWeights']['showDescription']=0.5
        self.assertEqual(evaluate(b,{'showTitle':'小说','showDescription':'演播'})['score'],5)

    def test_episode_allow_over_show_block(self):
        b=bundle();c=b['categories'][0];c['showBlocklist']=['rss'];c['episodeAllowlist']=['episode']
        self.assertEqual(evaluate(b,{},'rss','episode')['decision'],'allow')

    def test_cross_category_block_wins_at_same_level(self):
        b=bundle(); other=copy.deepcopy(b['categories'][0]);other['id']='other';other['showAllowlist']=['rss']; b['categories'][0]['showBlocklist']=['rss'];b['categories'].append(other)
        self.assertEqual(evaluate(b,{},'rss')['decision'],'block')

    def test_generic_weak_marker_cannot_block(self):
        b=bundle();c=b['categories'][0];c['regexRules']=[dict(id='chapter',score=1,fields=['episodeTitle'],pattern='第[0-9]{1,8}章')]
        self.assertEqual(evaluate(b,{'episodeTitle':'课程第10章'})['decision'],'allow')

if __name__=='__main__':
    unittest.main()
