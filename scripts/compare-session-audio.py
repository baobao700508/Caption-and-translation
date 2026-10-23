#!/usr/bin/env python3
import argparse,wave,array,math,json,statistics
from pathlib import Path
from datetime import datetime
p=argparse.ArgumentParser();p.add_argument('session',type=Path);p.add_argument('--report',type=Path);a=p.parse_args()
def time(s):return datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()
report={'session':str(a.session),'tracks':{}}
for f in (a.session/'audio').glob('*.wav'):
 with wave.open(str(f),'rb') as w:rate=w.getframerate();pcm=array.array('h',w.readframes(w.getnframes()))
 rms=math.sqrt(sum(x*x for x in pcm)/max(1,len(pcm)))/32768
 blocks=[math.sqrt(sum(x*x for x in pcm[i:i+rate//10])/max(1,len(pcm[i:i+rate//10])))/32768 for i in range(0,len(pcm),rate//10)]
 z=[i for i,x in enumerate(pcm) if x!=0]; longest=0; previous=-1; periodic=[]
 for pos in z:
  run=pos-previous-1
  if run>=rate*.02: periodic.append((previous+1,run))
  previous=pos
 patterned=sum(1 for left,right in zip(periodic,periodic[1:]) if .095<=(right[0]-left[0])/rate<=.105)
 report['tracks'][f.stem]={'periodic_100ms_zero_gaps':patterned,'rate':rate,'samples':len(pcm),'seconds':len(pcm)/rate,'rms_dbfs':20*math.log10(max(rms,1e-12)),'peak':max(map(abs,pcm),default=0)/32768,'digital_zero_fraction':sum(x==0 for x in pcm)/max(1,len(pcm)),'quiet_blocks_below_minus60db_fraction':sum(x<.001 for x in blocks)/max(1,len(blocks)),'block_rms_dbfs':[round(20*math.log10(max(x,1e-12)),1) for x in blocks]}
rows=[json.loads(x) for x in (a.session/'audio/upload-index.jsonl').read_text().splitlines()]
events=[json.loads(x) for x in (a.session/'events.jsonl').read_text().splitlines()]
report['gaps']=[{'at':r['received_at'],'message':r.get('message')} for r in events if r['event_type']=='gap']
report['processing']=[{k:v for k,v in r.items() if k not in ['text']} for r in events if r['event_type']=='audio.processing']
if rows:
 send=[time(r['send_completed_at'])-time(r['submitted_at']) for r in rows]
 report['send_seconds']={'max':max(send),'p50':statistics.median(send),'p95':sorted(send)[max(0,math.ceil(.95*len(send))-1)]}
 for k1,k2,name in [('prepared_at','submitted_at','queue'),('capture_ended_at','prepared_at','frontend')]:
  vals=[time(r[k2])-time(r[k1]) for r in rows if k1 in r]
  if vals:report[name+'_seconds']={'max':max(vals),'p50':statistics.median(vals),'p95':sorted(vals)[max(0,math.ceil(.95*len(vals))-1)]}
report['capture_timeline_pass']=bool(report['tracks']) and all(t['periodic_100ms_zero_gaps']==0 for t in report['tracks'].values())
report['scope']='本机PCM周期性缺口分析；不代表上传完整性、翻译或端到端延迟通过'
report['percentile_method']='nearest_rank'
if a.report:a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({**report,'tracks':{k:{i:j for i,j in v.items() if i!='block_rms_dbfs'} for k,v in report['tracks'].items()}},ensure_ascii=False,indent=2))
raise SystemExit(0 if report['capture_timeline_pass'] else 1)
