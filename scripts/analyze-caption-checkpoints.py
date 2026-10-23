#!/usr/bin/env python3
"""Audit reference utterance endings against first interim source-text arrival."""
import argparse
from difflib import SequenceMatcher
import json
from pathlib import Path
import re
import runpy
import statistics

progress=runpy.run_path(str(Path(__file__).with_name("compare-caption-progress.py")))

def words(text):
    return [w.lower().replace("’", "'") for w in re.findall(r"[a-zA-Z0-9]+(?:['’][a-zA-Z0-9]+)*",text)]

def measure(heard,clips):
    reference=[];boundaries=[]
    for clip in clips:
        start=len(reference);reference.extend(words(clip["reference"]))
        boundaries.append((clip,start,len(reference)-1))
    matched={}
    for block in SequenceMatcher(None,reference,[w for w,t in heard],autojunk=False).get_matching_blocks():
        for offset in range(3,block.size):
            matched[block.a+offset]=(block.b+offset,block.a)
    checks=[];missing=[];duration=clips[-1]["end_seconds"]
    for clip,start,end in boundaries:
        if end not in matched or end-start<3:
            missing.append(clip["id"]);continue
        index,block_start=matched[end]
        # Require the exact final word and four consecutive matching words within
        # this utterance. A nearby earlier phrase cannot stand in for its ending.
        if end-max(start,block_start)<3:
            missing.append(clip["id"]);continue
        checks.append({"id":clip["id"],"audio_end_seconds":clip["end_seconds"],
                       "terminal_phrase":" ".join(reference[end-3:end+1]),
                       "first_visible_seconds":heard[index][1],
                       "lag_seconds":heard[index][1]-clip["end_seconds"]})
    first=[c["lag_seconds"] for c in checks if c["audio_end_seconds"]<=duration/4]
    last=[c["lag_seconds"] for c in checks if c["audio_end_seconds"]>=duration*3/4]
    lags=sorted(c["lag_seconds"] for c in checks)
    growth=statistics.median(last)-statistics.median(first) if first and last else None
    coverage=len(checks)/max(1,len(clips))
    p95=lags[min(len(lags)-1,int(.95*len(lags)))] if lags else None
    maximum=max(lags,default=None)
    enough=coverage>=.6 and bool(first) and bool(last)
    return {"measurement":"reference utterance audio-file ending to its exact terminal source phrase first appearing; not word alignment or audible translation delay",
            "utterance_count":len(clips),"measured_count":len(checks),"coverage":coverage,
            "missing_utterances":missing,"checkpoints":checks,
            "median_lag_seconds":statistics.median(lags) if lags else None,"p95_lag_seconds":p95,
            "maximum_lag_seconds":maximum,"last_minus_first_quarter_seconds":growth,
            "sufficient_coverage":enough,
            "accumulation_status":"insufficient_coverage" if not enough else ("observed" if growth>2 else "not_observed_at_measured_endings"),
            "success":enough and growth<=2 and p95<=5 and maximum<=5}

def audit(root,provenance):
    data=json.loads(provenance.read_text())
    if data.get("pcm_sha256")!=progress["pcm_digest"](root)[-1]:
        raise ValueError("Reference PCM differs from uploaded recording")
    result=measure(progress["source_words"](root),data["clips"])
    result.update(session=str(root),provenance=str(provenance),clock=progress["progress_clock"](progress["helpers"]["lines"](root/"events.jsonl")))
    return result

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("session",type=Path)
    p.add_argument("provenance",type=Path);p.add_argument("--output",type=Path,required=True)
    a=p.parse_args()
    try: result=audit(a.session,a.provenance)
    except (ValueError,KeyError,OSError) as error:result={"success":False,"error":str(error)}
    a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({k:v for k,v in result.items() if k!="checkpoints"},ensure_ascii=False))
    raise SystemExit(0 if result["success"] else 1)
