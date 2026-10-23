#!/usr/bin/env python3
"""Compare source-caption progress for byte-identical realtime audio, including interim text."""
import argparse
from difflib import SequenceMatcher
import hashlib
import json
from pathlib import Path
import re
import runpy
import statistics
import wave

helpers=runpy.run_path(str(Path(__file__).with_name("analyze-caption-latency.py")))

def pcm_digest(root):
    with wave.open(str(root/"audio/uploaded.wav")) as audio:
        return (audio.getframerate(),audio.getnchannels(),audio.getsampwidth(),
                hashlib.sha256(audio.readframes(audio.getnframes())).hexdigest())

def progress_clock(rows):
    active=[r for r in rows if r["event_type"]=="connection.active"]
    if len(active)!=1:
        raise ValueError("Progress comparison requires one uninterrupted connection per run")
    epoch=active[0].get("connection_epoch",1)
    rtp=[r for r in rows if r["event_type"]=="transport.webrtc_stats" and r.get("kind")=="outbound-rtp" and r.get("packetsSent",0)>0 and r.get("connection_epoch",1)==epoch]
    if not rtp:
        raise ValueError("No native outgoing RTP clock for progress comparison")
    early=[r for r in rtp if helpers["stamp"](r["received_at"])-helpers["stamp"](rtp[0]["received_at"])<=5]
    origin=statistics.median(helpers["stamp"](r["received_at"])-r["packetsSent"]*.02 for r in early)
    # A microphone can start seconds after RTP begins sending startup silence.
    # Equal uploaded WAVs must be compared from their first consumed PCM sample,
    # rather than attributing device initialization to caption processing.
    consumed=[r for r in rows if r["event_type"]=="transport.webrtc_input" and r.get("connection_epoch",1)==epoch and r.get("consumed_samples",0)>0]
    if consumed:
        initial=[r for r in consumed if helpers["stamp"](r["received_at"])-helpers["stamp"](consumed[0]["received_at"])<=5]
        origins=[helpers["stamp"](r["received_at"])-(r["consumed_samples"]+r.get("underflow_samples",0)+r.get("tail_padding_samples",0))/16000 for r in initial]
        if max(origins)-min(origins)>.25:
            raise ValueError("Initial consumed PCM clock is unstable")
        return {"origin_seconds":statistics.median(origins),"basis":"first_consumed_pcm_sample",
                "initial_origin_spread_seconds":max(origins)-min(origins),"pcm_origin_minus_rtp_origin_seconds":statistics.median(origins)-origin}
    return {"origin_seconds":origin,"basis":"initial_rtp_packets_fallback"}

def source_words(root):
    rows=helpers["lines"](root/"events.jsonl")
    origin=progress_clock(rows)["origin_seconds"]
    segments={}
    for row in rows:
        if row["event_type"] not in ("text.append","text.replace") or row.get("track")!="source":
            continue
        key=row["segment_id"];old=segments.get(key,[]);text=row["text"]
        received=helpers["stamp"](row["received_at"])-origin
        if row["event_type"]=="text.append":
            segments[key]=old+[(c,received) for c in text]
        else:
            updated=[(c,received) for c in text]
            # A final replacement must not pretend unchanged interim words first appeared at finalization.
            for block in SequenceMatcher(None,"".join(c for c,t in old),text,autojunk=False).get_matching_blocks():
                updated[block.b:block.b+block.size]=old[block.a:block.a+block.size]
            segments[key]=updated
    words=[]
    for chars in segments.values():
        text="".join(c for c,t in chars)
        for match in re.finditer(r"[a-zA-Z0-9]+(?:['’][a-zA-Z0-9]+)*",text):
            words.append((match[0].lower().replace("’","'"),max(t for c,t in chars[match.start():match.end()])))
    return words

def compare_words(actual,reference):
    matches=[]
    for block in SequenceMatcher(None,[w for w,t in reference],[w for w,t in actual],autojunk=False).get_matching_blocks():
        # Four consecutive matching words distinguish speech progress from repeated short function words.
        for offset in range(3,block.size):
            a=actual[block.b+offset];r=reference[block.a+offset]
            matches.append({"reference_word_index":block.a+offset,"phrase":" ".join(w for w,t in reference[block.a+offset-3:block.a+offset+1]),
                            "reference_seconds":r[1],"actual_seconds":a[1],"extra_seconds":a[1]-r[1]})
    if not matches:
        raise ValueError("No sufficiently long matching source spans")
    extras=sorted(r["extra_seconds"] for r in matches)
    first=[r["extra_seconds"] for r in matches if r["reference_word_index"]<len(reference)/4]
    last=[r["extra_seconds"] for r in matches if r["reference_word_index"]>=3*len(reference)/4]
    growth=statistics.median(last)-statistics.median(first) if first and last else None
    coverage=len(matches)/max(1,len(reference))
    return {"matched_words":len(matches),"reference_words":len(reference),"matched_coverage":coverage,
            "median_extra_seconds":statistics.median(extras),"p95_extra_seconds":extras[min(len(extras)-1,int(.95*len(extras)))],
            "maximum_extra_seconds":max(extras),"last_minus_first_quarter_seconds":growth,"matches":matches}

def compare(root,reference):
    if pcm_digest(root)!=pcm_digest(reference):
        raise ValueError("Recordings differ: a same-audio comparison cannot pass")
    baseline=helpers["audit"](reference)
    lag=baseline["maximum_provider_event_lag_seconds"]
    if lag is None or lag>5 or baseline["tail_confirmed"] is not True:
        raise ValueError("Reference is not a healthy complete realtime run")
    result=compare_words(source_words(root),source_words(reference))
    result.update({"session":str(root),"reference_session":str(reference),"measurement":"relative source interim-caption progress; not forced audio-word alignment",
                   "same_pcm_sha256":pcm_digest(root)[-1],
                   "actual_progress_clock":progress_clock(helpers["lines"](root/"events.jsonl")),
                   "reference_progress_clock":progress_clock(helpers["lines"](reference/"events.jsonl"))})
    result["success"]=(result["matched_coverage"]>=.6 and result["p95_extra_seconds"]<=2 and result["maximum_extra_seconds"]<=5
                       and result["last_minus_first_quarter_seconds"] is not None and result["last_minus_first_quarter_seconds"]<=2)
    return result

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("session",type=Path);p.add_argument("reference",type=Path);p.add_argument("--output",type=Path,required=True)
    args=p.parse_args()
    try: result=compare(args.session,args.reference)
    except (ValueError,KeyError,OSError,wave.Error) as error: result={"success":False,"error":str(error)}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({k:v for k,v in result.items() if k!="matches"},ensure_ascii=False))
    raise SystemExit(0 if result["success"] else 1)
