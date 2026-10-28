import copy
import unittest
from release_audit import release_blockers

class ReleaseEvidence(unittest.TestCase):
    def test_promoting_status_does_not_create_human_gold(self):
        b=dict(status='production',categories=[dict(publisherRules=[])])
        labels=[dict(label_source='agent_metadata_review',label='fiction')]
        self.assertTrue(any('No human labels' in s for s in release_blockers(labels,{},b)))

    def test_human_label_does_not_certify_leakage_audit(self):
        b=dict(categories=[dict(publisherRules=[])])
        self.assertTrue(any('audit is incomplete' in s for s in release_blockers([dict(label_source='human')],dict(status='complete'),b)))

    def test_pending_stable_id_not_eligible_for_default_block(self):
        r=dict(enabled=True,action='block',confirmation=dict(status='pending'),identities=[dict(namespace='apple.podcasts.artist',id='123')])
        b=dict(categories=[dict(publisherRules=[r])])
        self.assertTrue(any('lacks confirmed stable identity' in s for s in release_blockers([],{},b)))

if __name__=='__main__':unittest.main()
