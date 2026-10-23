#!/usr/bin/env python3
"""Audit observable decisions and publish a local, source-faithful bilingual comparison."""
import collections
import hashlib
import html
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
project = Path(__file__).resolve().parent.parent
def read_events(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
def trace_metrics(log):
    events = read_events(log/'reflow-decisions.jsonl')
    responses = [e for e in events if e['event_type'] == 'caption.reflow.response']
    return {'trace_events':len(events), 'responses':len(responses),
            'api_cost_usd':sum((e.get('usage') or {}).get('cost',0) for e in responses),
            'request_seconds':[e['elapsed_seconds'] for e in responses],
            'question_counts':[e['question_count'] for e in events if e['event_type']=='caption.reflow.request'],
            'actual_models':sorted({e['model'] for e in responses}),
            'retained_reasons':[e['reason'] for e in events if e['event_type']=='caption.reflow.retained'],
            'failures':[e for e in events if e['event_type'] in ['caption.reflow.failed','caption.reflow.request_failed']],
            'decisions':sum(len(e.get('blocks',[])) for e in events if e['event_type']=='caption.reflow.selection')}
def semantic_constraints(sample):
    text=sample.get('input_source','');ends=[];offset=0
    for row in sample.get('rows',[])[:-1]:
        offset+=len(row['source']);ends.append(offset)
    checks=[]
    for span in sample.get('expected_unsplit_source_spans',[]):
        begin=text.find(span)
        checks.append({'span':span,'present':begin>=0,'not_cut_inside':begin>=0 and not any(begin<e<begin+len(span) for e in ends)})
    return checks

offline=[]
for file in sorted(root.glob('*/results.json')):
    for sample in json.loads(file.read_text()):
        item=dict(sample);item['run']=file.parent.name;item['trace']=trace_metrics(Path(sample['log_path']))
        rows=sample.get('rows',[])
        item['verified_source_bytes']=''.join(r['source'] for r in rows).encode()==sample['input_source'].encode() if rows else False
        item['verified_translation_bytes']=''.join(r['translation'] for r in rows).encode()==sample['input_translation'].encode() if rows else False
        item['constraints']=semantic_constraints(sample)
        offline.append(item)
audio=[]
manifest=root/'audio-runs.json'
for run in json.loads(manifest.read_text()) if manifest.exists() else []:
    file=Path(run['result_path']);result=json.loads(file.read_text());item=dict(run)
    item.update(result);item['trace']=trace_metrics(Path(result['log_path']))
    events=read_events(Path(result['log_path'])/'events.jsonl')
    segments=collections.OrderedDict()
    for e in events:
        if e['event_type'] in ['text.append','text.replace']:
            key=(e['connection_epoch'],e['track'],e['segment_id'])
            segments[key]=('' if e['event_type']=='text.replace' else segments.get(key,''))+e['text']
    epoch=max((k[0] for k in segments),default=0)
    item['lossless_current_epoch']={t:''.join(v for (ep,tr,_),v in segments.items() if ep==epoch and tr==t).encode()==''.join(r[t] for r in result.get('caption_rows',[])).encode() for t in ['source','translation']}
    item['gaps']=[{k:e[k] for k in ['event_type','received_at','message'] if k in e} for e in events if e['event_type']=='gap']
    item['first_projection_ms']=[e['projection_ms'] for e in events if e['event_type']=='caption.first_projected']
    item['reflows_before_journal_close']=sum(e['event_type']=='caption.layout.applied' for e in events)
    audio.append(item)
summary={'offline':offline,'audio':audio,'scope':'Runtime/byte integrity and explicit unsplit-span constraints are separate from human semantic alignment review. Held-out failures are retained.'}
(root/'audit.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
escape=lambda x:html.escape(str(x))
def link(path,label):
    import os
    return f'<a href="{escape(os.path.relpath(str(path),str(root)))}">{escape(label)}</a>'
def groups(rows):
    return ''.join(f'<div class="block"><div class="en">{escape(row["source"])}</div><div class="zh">{escape(row["translation"])}</div></div>' for row in rows)
parts=['''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>JEV 双语段落实测</title><style>
body{font:16px/1.65 system-ui,sans-serif;max-width:1120px;margin:36px auto;padding:0 22px;background:#f5f4ef;color:#222}
h1{font-size:28px}h2{font-size:22px;margin-top:38px}table{border-collapse:collapse;width:100%;background:white;font-size:14px}td,th{border:1px solid #ddd;padding:8px;text-align:left}details{background:#fff;padding:14px 18px;margin:14px 0;border-radius:10px}summary{cursor:pointer;font-weight:650}.block{padding:14px 0;border-bottom:1px solid #ddd;white-space:pre-wrap}.en{color:#22354b}.zh{margin-top:6px}.meta{color:#596168;font-size:14px}.bad{color:#a33}.good{color:#17674b}a{color:#145c8b}audio{max-width:100%}</style>
<h1>JEV 双语段落实测</h1><p>阅读标准：B 完整意思块优先，C 连贯段落可接受。每批双语正常调用两次：Choice 找对应，Noul＋Score 判断分块。正文由程序切取，原始字幕先显示。</p>
<p>自动检查证明运行、字节保真和列明的不可拆范围；中英含义是否对应仍需看实际段落。全部 API 选项、概率、评分、门槛、采用及拒绝原因均可从详细判断日志查看。</p>''']
native=root/'native-view-final/result.json'
if native.exists():
    n=json.loads(native.read_text());passed=sum(n['checks'].values())
    parts.append(f'<p>原生显示与设置检查：{passed}/{len(n["checks"])}。'+link(native,'验证明细')+' · '+link(root/'native-view-final/model-settings.png','分段设置截图')+' · '+link(root/'native-view-final/sample-2-after.png','实际字幕截图')+'</p>')
parts.append('<h2>真人录音与真实应用</h2><table><tr><th>说话人／用途</th><th>应用结果</th><th>输入／收尾</th><th>运行中整理</th><th>分段 API 费用</th></tr>')
for r in audio:
    parts.append(f'<tr><td>{escape(r["speaker"])} / {escape(r["split"])} / {escape(r.get("label",""))}</td><td>{"通过" if r["success"] else "未通过"}</td><td>逐字节：{r["input_pcm_byte_identical"]}；收尾：{r["tail_confirmed"]}</td><td>{r["reflow_applied_count"]}</td><td>${r["trace"]["api_cost_usd"]:.6f}</td></tr>')
parts.append('</table>')
for r in audio:
    log=Path(r['log_path']);parts.append(f'<details><summary>说话人 {escape(r["speaker"])} · {escape(r.get("label",""))} · {"通过" if r["success"] else "未通过"}</summary>')
    parts.append('<p class="meta">'+link(r['result_path'],'应用验收结果')+' · '+link(log/'reflow-decisions.jsonl','完整分段判断')+' · '+link(log/'events.jsonl','会话事件')+' · '+link(log/'audio/uploaded.wav','实际上传轨')+'</p>')
    if r.get('error'):parts.append('<p class="bad">'+escape(r['error'])+'</p>')
    for g in r['gaps']:parts.append('<p class="bad">'+escape(g)+'</p>')
    parts.append(groups(r.get('caption_rows',[]))+'</details>')
parts.append('<h2>冻结提示词后的留出文本</h2>')
for r in offline:
    if r['run']!='frozen-held-out-text-quote-fix':continue
    parts.append(f'<details open><summary>{escape(r["id"])} · {len(r.get("rows",[]))} 块</summary><p class="meta">'+link(Path(r['log_path'])/'reflow-decisions.jsonl','全部选项与判断')+'</p>'+groups(r.get('rows',[])))
    parts.append('<p class="meta">指定不可拆范围：'+escape([(c['present'],c['not_cut_inside']) for c in r['constraints']])+'</p></details>')
parts.append('<h2>开发样本与提示词对照</h2><table><tr><th>运行版本</th><th>样本</th><th>块数</th><th>两轨字节保真</th><th>总耗时</th></tr>')
for r in offline:
    parts.append(f'<tr><td>{escape(r["run"])}</td><td>{escape(r["id"])}</td><td>{len(r.get("rows",[]))}</td><td>{r["verified_source_bytes"] and r["verified_translation_bytes"]}</td><td>{r["elapsed_seconds"]:.3f}s</td></tr>')
parts.append('</table>')
for r in offline:
    if r['run']=='frozen-held-out-text-quote-fix':continue
    parts.append(f'<details><summary>{escape(r["run"])} · {escape(r["id"])}</summary><p class="meta">'+link(Path(r['log_path'])/'reflow-decisions.jsonl','完整请求、回答与选择')+'</p>')
    if not r['success']:parts.append('<p class="bad">'+escape(r.get('failure','未完成'))+'</p>')
    parts.append(groups(r.get('rows',[]))+'</details>')
parts.append('<p>录音来源：<a href="https://www.openslr.org/12/">OpenSLR LibriSpeech test-clean</a>，CC BY 4.0。来源、所选片段、PCM 哈希和开发／留出划分在各录音 provenance 中。虚构文本单独标注，不作为语音证据。整堂课、远场麦克风与物理扬声器未在这些文件回放中验证。</p></html>')
(root/'report.html').write_text('\n'.join(parts))
print(root/'report.html')
print('offline runs',len(offline),'audio runs',len(audio))
