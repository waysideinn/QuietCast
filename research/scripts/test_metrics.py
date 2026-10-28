import unittest
from validate import metrics

class MetricSemantics(unittest.TestCase):
    def test_review_is_not_recall_credit(self):
        r=metrics([dict(label='fiction',decision='block',subtype='a'),dict(label='fiction',decision='review',subtype='a')])
        self.assertEqual(r['fiction_block_recall']['value'],0.5)
        self.assertEqual(r['review_rate']['value'],0.5)

    def test_unknown_block_disclosed_not_silent_precision_credit(self):
        r=metrics([dict(label='uncertain',decision='block'),dict(label='fiction',decision='block'),dict(label='nonfiction',decision='block')])
        self.assertEqual(r['precision']['value'],0.5)
        self.assertEqual(r['uncertain_blocked'],1)

    def test_zero_denominator_is_missing(self):
        r=metrics([])
        self.assertIsNone(r['fiction_block_recall']['value'])
        self.assertIsNone(r['precision']['wilson95'])

if __name__=='__main__':
    unittest.main()
