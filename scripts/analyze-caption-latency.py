#!/usr/bin/env python3
"""Audit recorded realtime clocks; distinguish provider-event lag from local submission and reflow."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import statistics

def stamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()

def lines(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []

def audit(root):
    events=lines(root/"events.jsonl")
    uploaded=lines(root/"audio/upload-index.jsonl")
    decisions=lines(root/"reflow-decisions.jsonl")
    active=[e for e in events if e["event_type"]=="connection.active"]
    # Calibrate against the initial outgoing RTP packet clock, rather than microphone startup:
    # the media track can already be sending silence while Apple Voice Processing starts.
    clocks={};calibrations=[]
    for connection in active:
        epoch=connection.get("connection_epoch",1);base=stamp(connection["received_at"])
        rtp=[e for e in events if e.get("connection_epoch",1)==epoch and e["event_type"]=="transport.webrtc_stats" and e.get("kind")=="outbound-rtp" and e.get("packetsSent",0)>0]
        early=[e for e in rtp if stamp(e["received_at"])-stamp(rtp[0]["received_at"])<=5] if rtp else []
        origins=[stamp(e["received_at"])-e["packetsSent"]*.020 for e in early]
        clock=statistics.median(origins) if origins else base;clocks[epoch]=clock
        calibrations.append({"connection_epoch":epoch,"basis":"initial_rtp_packets" if origins else "session_updated_fallback",
            "rtp_origin_minus_session_updated_seconds":clock-base,"early_clock_origin_spread_seconds":max(origins)-min(origins) if origins else None})
    vad=[]
    for e in events:
        kind=e["event_type"]
        key="audio_start_ms" if kind=="input_audio_buffer.speech_started" else "audio_end_ms"
        epoch=e.get("connection_epoch",1)
        if kind in ["input_audio_buffer.speech_started","input_audio_buffer.speech_stopped"] and e.get(key) is not None and epoch in clocks:
            vad.append({"event":kind,"received_at":e["received_at"],"provider_audio_seconds":e[key]/1000,
                        "connection_epoch":epoch,"lag_seconds":stamp(e["received_at"])-clocks[epoch]-e[key]/1000})
    finals=[{"track":e["track"],"received_at":e["received_at"],"provider_audio_end_seconds":e["audio_end_ms"]/1000,
             "connection_epoch":e.get("connection_epoch",1),"lag_seconds":stamp(e["received_at"])-clocks[e.get("connection_epoch",1)]-e["audio_end_ms"]/1000}
            for e in events if e["event_type"] in ["text.append","text.replace"] and e.get("finality")=="final" and e.get("audio_end_ms") is not None and e.get("connection_epoch",1) in clocks]
    # Timely speech-start/stop events do not imply timely captions. Measure the first
    # nonempty text per provider item, before final replacements or background reflow.
    first_text=[];seen_text=set();unmeasured_first_text=[]
    for e in events:
        if e["event_type"] not in ("text.append","text.replace") or not e.get("text","").strip():
            continue
        epoch=e.get("connection_epoch",1)
        key=(epoch,e.get("track"),e.get("segment_id",e.get("provider_segment_id")))
        if key in seen_text:
            continue
        seen_text.add(key)
        if epoch not in clocks or e.get("audio_start_ms") is None:
            unmeasured_first_text.append({"connection_epoch":epoch,"track":e.get("track"),"segment_id":key[2],
                                          "received_at":e["received_at"],"reason":"missing_provider_start_or_clock"})
            continue
        first_text.append({"track":e["track"],"segment_id":key[2],"received_at":e["received_at"],
            "provider_audio_start_seconds":e["audio_start_ms"]/1000,"connection_epoch":epoch,
            "delay_seconds":stamp(e["received_at"])-clocks[epoch]-e["audio_start_ms"]/1000})
    submit=[stamp(e["submitted_at"])-stamp(e["capture_ended_at"]) for e in uploaded]
    sends=[stamp(e["send_completed_at"])-stamp(e["submitted_at"]) for e in uploaded]
    durations=[e["elapsed_seconds"] for e in decisions if e["event_type"]=="caption.reflow.validated"]
    native=[e for e in events if e["event_type"]=="transport.webrtc_input"]
    projections=[e["projection_ms"] for e in events if e["event_type"]=="caption.first_projected"]
    native_delivery=[e["native_queue_delay_seconds"] for e in events if e["event_type"]=="transport.webrtc_delivery"]
    return {"session":str(root),"media_clock_basis":"initial outbound RTP packet count at Opus 20 ms packetization; VAD/final event lag, not word-level latency",
            "clock_calibrations":calibrations,
            "capture_to_submit_median_seconds":statistics.median(submit) if submit else None,"capture_to_submit_max_seconds":max(submit,default=None),
            "client_send_max_seconds":max(sends,default=None),"native_pending_max_seconds":max((e["pending_samples"]/16000 for e in native),default=None),
            "native_receive_queue_max_seconds":max(native_delivery,default=None),
            "native_underflow_seconds":max((e["underflow_samples"]/16000 for e in native),default=None),
            "jev_median_seconds":statistics.median(durations) if durations else None,"jev_max_seconds":max(durations,default=None),
            "first_app_projection_max_ms":max(projections,default=None),"provider_vad_events":vad,"provider_final_text_events":finals,
            "first_text_measurement":"provider segment audio start to first nonempty source/translation text; not per-word latency or audible translation latency",
            "first_text_events":first_text,"maximum_first_text_delay_seconds":max((e["delay_seconds"] for e in first_text),default=None),
            "unmeasured_first_text_events":unmeasured_first_text,
            "maximum_provider_event_lag_seconds":max((e["lag_seconds"] for e in vad),default=None),
            "tail_confirmed":next((e.get("confirmed") for e in reversed(events) if e["event_type"]=="connection.final_finish"),None)}

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("session",type=Path)
    p.add_argument("--output",type=Path,required=True)
    p.add_argument("--max-provider-lag",type=float,default=5)
    p.add_argument("--max-first-text-delay",type=float,default=5)
    a=p.parse_args();result=audit(a.session)
    result["within_provider_lag_budget"]=result["maximum_provider_event_lag_seconds"] is not None and result["maximum_provider_event_lag_seconds"]<=a.max_provider_lag
    result["provider_lag_budget_seconds"]=a.max_provider_lag
    result["within_first_text_budget"]=not result["unmeasured_first_text_events"] and result["maximum_first_text_delay_seconds"] is not None and result["maximum_first_text_delay_seconds"]<=a.max_first_text_delay
    result["first_text_budget_seconds"]=a.max_first_text_delay
    result["success"]=result["within_provider_lag_budget"] and result["within_first_text_budget"]
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({k:result[k] for k in ["success","within_provider_lag_budget","within_first_text_budget","capture_to_submit_max_seconds","native_pending_max_seconds","jev_max_seconds","maximum_provider_event_lag_seconds","maximum_first_text_delay_seconds","tail_confirmed"]}))
    raise SystemExit(0 if result["success"] else 1)
