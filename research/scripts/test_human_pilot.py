import json
import unittest
from evaluate_human_pilot import OUT, scope, expected
from validate import metrics

class HumanPilotSemantics(unittest.TestCase):
    def test_english_fiction_is_allow_without_relabeling_nonfiction(self):
        label=dict(label='fiction',filter_decision='allow')
        self.assertEqual(expected(label),'allow')
        self.assertEqual(label['label'],'fiction')
        self.assertEqual(scope('1251826993'),'english_fiction_exemption')

    def test_language_scope_is_separate_from_content_class(self):
        self.assertEqual(scope('1234086160'),'foreign_metadata')
        self.assertEqual(scope('1125959192'),'chinese_candidate')

    def test_pilot_excludes_preidentified_family_overlap(self):
        audit=json.loads((OUT/'prescore-audit.json').read_text())
        row=next(x for x in audit['rows'] if x['show_id']=='1489176388')
        self.assertFalse(row['eligibleForScreenedPilot'])
        self.assertTrue(any(x['show_id']=='1533775577' for x in row['work_title_overlap']))
        self.assertEqual(audit['status'],'screened_not_independence_certified')

    def test_review_never_counts_as_automatic_block(self):
        result=metrics([dict(label='fiction',decision='review')])
        self.assertEqual(result['fiction_block_recall']['value'],0)
        self.assertEqual(result['review_rate']['value'],1)

    def test_no_episode_gold_inferred_from_show_judgments(self):
        doc=json.loads((OUT/'fixtures.json').read_text())
        self.assertTrue(all(r['unit']=='show' and r['episode_id'] is None for r in doc['fixtures']))

if __name__=='__main__':unittest.main()
