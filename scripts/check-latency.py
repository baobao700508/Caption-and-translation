#!/usr/bin/env python3
"""Check initial speech-to-text timing. Does not claim word-aligned translation lag."""
import argparse, json, sys, wave, array, math, statistics
from pathlib import Path
from datetime import datetime
p=argparse.ArgumentParser();p.add_argument('session',type=Path)
p.add_argument('--max-first-text-seconds',type=float,default=5.0)
p.add_argument('--speech-onset',action='store_true');p.add_argument('--report',type=Path)
a=p.parse_args()
def seconds(x): return datetime.fromisoformat(x.replace('Z','+00:00')).timestamp()
def percentile(xs,n): return sorted(xs)[min(len(xs)-1,int((len(xs)-1)*n))] if xs else None
sends=[json.loads(x) for x in (a.session/'audio/upload-index.jsonl').read_text().splitlines()]
events=[json.loads(x) for x in (a.session/'events.jsonl').read_text().splitlines()]
onset=None
if a.speech_onset:
 with wave.open(str(a.session/'audio/uploaded.wav'),'rb') as w:
  pcm=array.array('h',w.readframes(w.getnframes()));rate=w.getframerate()
 for i in range(0,len(pcm),160):
  block=pcm[i:i+160]
  if math.sqrt(sum(x*x for x in block)/len(block))/32768>0.01:
   row=next((r for r in sends if r['sample_offset']<=i<r['sample_offset']+r['sample_count']),None)
   if row and 'capture_started_at' in row: onset=seconds(row['capture_started_at'])+(i-row['sample_offset'])/rate
   break
checks=[];rows=[]
for epoch in sorted({r['connection_epoch'] for r in sends}):
 sent=[r for r in sends if r['connection_epoch']==epoch]
 first=onset if onset is not None else min(seconds(r['submitted_at']) for r in sent)
 for track in ['source','translation']:
  texts=[r for r in events if r.get('connection_epoch')==epoch and r['event_type'].startswith('text.') and r.get('track')==track and r.get('text','').strip()]
  delay=min((seconds(r['received_at'])-first for r in texts),default=None)
  passed=delay is not None and delay<=a.max_first_text_seconds and (not a.speech_onset or onset is not None)
  checks.append(passed);row={'epoch':epoch,'track':track,'initial_delay_seconds':None if delay is None else round(delay,3),'pass':passed};rows.append(row)
  print(('PASS' if passed else 'FAIL'),row)
send_times=[seconds(r['send_completed_at'])-seconds(r['submitted_at']) for r in sends]
queue_times=[seconds(r['submitted_at'])-seconds(r['prepared_at']) for r in sends if 'prepared_at' in r]
front_times=[seconds(r['prepared_at'])-seconds(r['capture_ended_at']) for r in sends if 'prepared_at' in r]
report={'scope':'Initial voice-onset-to-first-text timing, estimated capture clock; not per-word p50/p95 or compositor rendering time.','speech_onset_found':onset is not None,'checks':rows,'success':bool(checks) and all(checks),
 'send_p95_seconds':percentile(send_times,.95),'send_max_seconds':max(send_times,default=None),
 'queue_p95_seconds':percentile(queue_times,.95),'queue_max_seconds':max(queue_times,default=None),
 'frontend_p95_seconds':percentile(front_times,.95),'gap_events':[r.get('message') for r in events if r['event_type']=='gap']}
print(json.dumps({k:v for k,v in report.items() if k!='checks'},ensure_ascii=False,indent=2))
if a.report:a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2))
sys.exit(0 if report['success'] else 1)
