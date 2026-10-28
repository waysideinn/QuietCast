#!/usr/bin/env python3
"""JSON Schema, selected v1 semantic constraints and handoff provenance check."""
import hashlib
import json
import re
import subprocess
import jsonschema
from collect import ROOT, write
from engine import FIELDS, normalize

COMMIT='9e908672b5ac6afe94a0f6ea4e5d0f31f66b7360'
V11_COMMIT='b62212bdf9b36f0f90e2f7f3a8f0990bba6544b9'

def semantic(bundle):
    cat_ids=[]
    for c in bundle['categories']:
        cat_ids.append(c['id'])
        assert 0<c['thresholds']['review']<c['thresholds']['block'], 'invalid thresholds'
        ids=[]
        for array in ('strongKeywords','keywords','exclusions','combinationKeywords','regexRules'):
            for r in c[array]:
                ids.append(r['id'])
                if 'term' in r:
                    assert normalize(r['term']), 'normalized empty term'
                if 'terms' in r:
                    terms=list(map(normalize,r['terms']))
                    assert all(terms) and len(set(terms))==len(terms), 'normalized duplicate/empty terms'
                if 'pattern' in r:
                    pat=r['pattern']
                    assert not any(x in pat for x in ['(',')','|','*','+','?']), 'unsupported regex operator'
                    assert len(re.findall(r'\{',pat))<=1, 'more than one quantifier'
                    # Every escape must be one of the v1 permitted character classes.
                    assert not re.search(r'\\[^dDwWsS]',pat), 'unsupported escape'
                    braces=re.findall(r'\{([0-9]+)(?:,([0-9]+))?\}',pat)
                    assert pat.count('{')==len(braces), 'unsupported quantifier'
                    for lo,hi in braces:
                        assert 0<=int(lo)<=int(hi or lo)<=64, 'quantifier too large'
                    re.compile(pat)
        assert len(ids)==len(set(ids)), 'duplicate rule IDs'
    assert len(cat_ids)==len(set(cat_ids)), 'duplicate category IDs'

def main():
    paths=['schemas/content-filter.schema.json','schemas/content-filter-interface.md','rules/example-fiction.json']
    provenance={}
    for name in paths:
        revision=V11_COMMIT if name=='schemas/content-filter-interface.md' else COMMIT
        expected=subprocess.check_output(['git','show',revision+':'+name],cwd=ROOT)
        actual_path=ROOT/name
        if name=='schemas/content-filter.schema.json' and (ROOT/'schemas/content-filter.v1.0.schema.json').exists():
            actual_path=ROOT/'schemas/content-filter.v1.0.schema.json'
        actual=actual_path.read_bytes()
        if actual!=expected:
            raise ValueError('handoff file changed: '+name)
        provenance[str(actual_path.relative_to(ROOT))]=hashlib.sha256(actual).hexdigest()
    bundle=json.loads((ROOT/'rules/research/fiction-candidate.json').read_text())
    schema=json.loads((ROOT/'schemas/content-filter.schema.json').read_text())
    jsonschema.Draft202012Validator(schema,format_checker=jsonschema.FormatChecker()).validate(bundle)
    semantic(bundle)
    result=dict(schema_commit=COMMIT,v11_handoff_commit=V11_COMMIT,handoff_files=provenance,json_schema='pass',semantic_subset='pass',status=bundle['status'],production_ready=False,notes='The frozen v1.0 schema/example are checked against the initial commit; the updated interface Markdown is checked against the authorized v1.1 commit. Actual Swift loading/scoring parity is separately reported; production additionally requires human gold and independent test.')
    write(ROOT/'reports/fiction_research/contract-check.json',result)
    print(json.dumps(result,ensure_ascii=False,indent=2))

if __name__=='__main__':
    main()
