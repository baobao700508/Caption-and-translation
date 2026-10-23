#!/usr/bin/env python3
"""Separate audio integrity, provider timing, local projection, and lossless reflow."""
from collections import OrderedDict
from datetime import datetime
import json
from pathlib import Path
import re
import sys

result_path = Path(sys.argv[1])
result = json.loads(result_path.read_text())
events = [json.loads(line) for line in (Path(result["log_path"]) / "events.jsonl").read_text().splitlines()]
def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
origin = next(timestamp(e["input_started_at"]) for e in events if e["event_type"] == "verification.file_input_started")
segments = OrderedDict()
for event in events:
    if event["event_type"] not in ("text.append", "text.replace"):
        continue
    key = (event["connection_epoch"], event["track"], event["segment_id"])
    segments[key] = ("" if event["event_type"] == "text.replace" else segments.get(key, "")) + event["text"]
epoch = max(key[0] for key in segments)
raw = {track: "".join(text for key,text in segments.items() if key[0] == epoch and key[1] == track)
       for track in ("source", "translation")}
layout = {track: "".join(row[track] for row in result.get("caption_rows", [])) for track in raw}
applied = [e for e in events if e["event_type"] == "caption.layout.applied"]
projected = [e for e in events if e["event_type"] == "caption.first_projected"]
metrics = {
    "input_pcm_byte_identical": result["input_pcm_byte_identical"],
    "tail_confirmed": any(e["event_type"] == "session.stopped" and e.get("tail_incomplete") is False for e in events),
    "lossless_current_epoch": {track: raw[track].encode() == layout[track].encode() for track in raw},
    "source_bytes": len(raw["source"].encode()), "translation_bytes": len(raw["translation"].encode()),
    "caption_rows": len(result.get("caption_rows", [])),
    "first_caption_from_file_start_seconds": {track: round(min(timestamp(e["received_at"]) for e in projected if e["track"] == track)-origin, 3)
        for track in raw if any(e["track"] == track for e in projected)},
    "local_first_projection_ms": [round(e["projection_ms"], 3) for e in projected],
    "reflows_while_journal_open": len(applied),
    "reflow_seconds": [round(e["elapsed_seconds"], 3) for e in applied],
    "reflow_attempts": [e.get("attempts") for e in applied],
    "first_reflow_from_file_start_seconds": round(timestamp(applied[0]["received_at"])-origin,3) if applied else None,
    "gaps": [e for e in events if e["event_type"] == "gap"],
    "connection_epochs": sorted({key[0] for key in segments}),
    "timing_scope": "First-caption times start at file input, not word end. Local projection measures AppSession state update, not physical display refresh. Reflow never blocks raw text."
}
fixture=Path(result.get('fixture_path') or Path(__file__).resolve().parent.parent / 'TestResults/fixtures/librispeech/human-speech.wav')
reference=fixture.with_name('provenance'+fixture.stem.removeprefix('human-speech')+'.json')
if reference.exists() and 'clips' in json.loads(reference.read_text()):
    truth = " ".join(c["reference"] for c in json.loads(reference.read_text())["clips"])
    heard = " ".join(text for key,text in segments.items() if key[1] == "source")
    def words(text): return re.findall(r"[a-z0-9]+", text.lower())
    a,b=words(truth),words(heard)
    row=list(range(len(b)+1))
    for i,x in enumerate(a,1):
        next_row=[i]
        for j,y in enumerate(b,1):
            next_row.append(min(row[j]+1,next_row[-1]+1,row[j-1]+(x!=y)))
        row=next_row
    metrics["reference_words"]=len(a)
    metrics["source_word_edits"]=row[-1]
    metrics["source_word_error_rate"]=round(row[-1]/len(a),4)
    metrics["wer_scope"]="Single audiobook sample, lowercase ASCII word normalization; not a model benchmark or translation accuracy score."
out=result_path.with_name("metrics.json")
out.write_text(json.dumps(metrics,ensure_ascii=False,indent=2)+"\n")
print(json.dumps(metrics,ensure_ascii=False,indent=2))
