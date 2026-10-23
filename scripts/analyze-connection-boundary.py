#!/usr/bin/env python3
"""Summarize file-test timing and sanitized SCTP evidence without audio/config secrets."""
import argparse
import datetime
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('run', type=Path)
p.add_argument('--fixture', type=Path)
args = p.parse_args()
result_path = args.run / 'result.json'
result = json.loads(result_path.read_text())
if args.fixture:
    result['fixture_path'] = str(args.fixture.resolve())
    result_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
directory = Path(result['log_path'])
events = [json.loads(line) for line in (directory / 'events.jsonl').read_text().splitlines()]
def stamp(value):
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
origin = stamp(next(e['input_started_at'] for e in events if e['event_type'] == 'verification.file_input_started'))
def elapsed(e):
    return round(stamp(e['received_at']) - origin, 3)
connected = [e for e in events if e['event_type'] == 'transport.webrtc_stage' and e.get('ice_state') == 2]
disconnected = [e for e in events if e['event_type'] == 'transport.webrtc_stage' and e.get('ice_state') == 5]
boundaries = [e for e in events if e['event_type'] == 'input_audio_buffer.speech_stopped']
report = {k: result.get(k) for k in ('success', 'mode', 'input_pcm_byte_identical', 'submitted_samples',
          'encoder_input_samples', 'discarded_input_samples', 'tail_confirmed', 'final_connection_tail_confirmed',
          'reflow_applied_count', 'live_readable_while_running', 'translated_samples', 'physical_playback_buffers')}
report['connections'] = len(connected)
report['disconnects'] = [{'epoch': e['connection_epoch'], 'input_elapsed': elapsed(e),
                         'after_connection_seconds': round(stamp(e['received_at']) - stamp(next(c['received_at'] for c in connected if c['connection_epoch'] == e['connection_epoch'])), 3)} for e in disconnected]
report['boundaries'] = [{'epoch': e['connection_epoch'], 'input_elapsed': elapsed(e), 'audio_end_ms': e.get('audio_end_ms')} for e in boundaries]
report['first_text_seconds'] = {track: next((elapsed(e) for e in events if e['event_type'] in ('text.append', 'text.replace') and e.get('track') == track), None) for track in ('source', 'translation')}
report['first_audio_seconds'] = next((elapsed(e) for e in events if e['event_type'] == 'translation.audio.first_received'), None)
report['playout_stages'] = [{k: e[k] for k in ('stage', 'drain_wait_ms', 'remote_finished') if k in e} | {'input_elapsed': elapsed(e)} for e in events if e['event_type'] == 'transport.webrtc_stage' and str(e.get('stage', '')).startswith('playout.')]
report['encoder_underflow_samples'] = max((e.get('underflow_samples', 0) for e in events), default=0)
index_path = directory / 'audio/upload-index.jsonl'
if index_path.exists():
    index = [json.loads(line) for line in index_path.read_text().splitlines()]
    report['max_capture_to_client_submit_seconds'] = round(max((stamp(e['submitted_at']) - stamp(e['capture_started_at']) for e in index), default=0), 3)
sctp = args.run / 'sctp.jsonl'
if sctp.exists():
    packets = [json.loads(line) for line in sctp.read_text().splitlines()]
    report['all_observed_sctp_crc_valid'] = all(e.get('crc_valid', False) for e in packets)
    report['last_sctp_before_disconnect'] = []
    for e in disconnected:
        t = stamp(e['received_at'])
        window = [q for q in packets if t - 8 < q['t'] < t]
        report['last_sctp_before_disconnect'].append({'epoch': e['connection_epoch'], 'packets': window[-8:]})
(args.run / 'boundary-audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in report.items() if k != 'last_sctp_before_disconnect'}, ensure_ascii=False, indent=2))
