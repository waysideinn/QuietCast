#!/usr/bin/env python3
"""Build user-approved production trial data; preserve frozen research baseline."""
import copy
import hashlib
import json
import jsonschema
from collect import ROOT, now, write

OUTPUT=ROOT/'rules/fiction-audiobooks.json'

def build():
    base=ROOT/'rules/research/fiction-multisource-candidate.json'
    b=copy.deepcopy(json.loads(base.read_text()))
    b.update(status='production',ruleVersion='fiction-zh-2026-10-27-v1',updatedAt=now())
    b['sources']+=['datasets/fiction_research/release/human-labels.json','research/production-trial-acceptance.md','reports/fiction_research/release/human-pilot/report.md']
    c=b['categories'][0]
    c['name']='中文小说与虚构剧情音频'
    c['description']='用户接受试用标准的正式本地词库：拦截中文小说演播、广播剧及虚构故事有声书；英文小说、评论和教学课程原则上保留。尚未通过独立准确率验证。'
    fs=['showTitle','showDescription','episodeTitle','episodeDescription']
    for term in ['神魔小说','仙侠小说']:
        c['keywords'].append(dict(id='trial-fiction-'+hashlib.sha256(term.encode()).hexdigest()[:10],term=term,score=15,fields=fs,note='人工复核发现明确题材自述的漏判；普通计分，可被上下文排除抵扣，不声称独立验证通过。'))
    for terms in [['双播','玄幻'],['玄幻','仙侠小说']]:
        c['combinationKeywords'].append(dict(id='trial-combo-'+hashlib.sha256('/'.join(terms).encode()).hexdigest()[:10],terms=terms,scope='sameField',score=7,fields=fs,note='来自人工复核玄幻演播案例；须同字段组合，单独双播或玄幻不作为高置信依据。'))
    for term in ['英文有声小说','英语有声小说','如何演播']:
        c['exclusions'].append(dict(id='trial-context-'+hashlib.sha256(term.encode()).hexdigest()[:10],term=term,score=60,fields=['showTitle','episodeTitle'],note='用户确认的英文小说豁免或演播教学语境，限标题明确短语；仅抵扣普通分，不能覆盖名单/分类直接block/家长限制；不能保证双语和误标内容。'))
    # No pending name-only account claims in the shipped default library.
    c['publisherRules']=[]
    c['notes']='2026-10-27用户接受大致拦截、实际试用后迭代，批准结束独立验证等待。production为发布状态，不代表准确率认证。没有已确认发布账号黑名单；不对平台品牌/托管商封禁。章节编号仍只弱计分。英文豁免仅明确标题短语，未识别实际音频语言。'
    schema=json.loads((ROOT/'schemas/content-filter.schema.json').read_text())
    jsonschema.Draft202012Validator(schema,format_checker=jsonschema.FormatChecker()).validate(b)
    assert len(json.dumps(b,ensure_ascii=False).encode())<2*1024*1024
    return b

def main():
    write(OUTPUT,build());print(OUTPUT)

if __name__=='__main__':main()
