#!/usr/bin/env python3
"""Audit realtime recovery against the original, non-looped human PCM fixture."""
import collections
import datetime
import json
import sys
import wave
from pathlib import Path

result_path = Path(sys.argv[1])
result = json.loads(result_path.read_text())
directory = Path(result['log_path'])
events = [json.loads(line) for line in (directory / 'events.jsonl').read_text().splitlines()]
index = [json.loads(line) for line in (directory / 'audio/upload-index.jsonl').read_text().splitlines()]
manifest = json.loads((directory / 'audio/recording.json').read_text())
def pcm(path):
    with wave.open(str(path), 'rb') as audio:
        return audio.readframes(audio.getnframes())
def time(value):
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
source = pcm(result.get('fixture_path') or Path(__file__).resolve().parent.parent / 'TestResults/fixtures/librispeech/human-speech.wav')
uploaded = pcm(directory / 'audio/uploaded.wav')
origin = time(next(e['input_started_at'] for e in events if e['event_type'] == 'verification.file_input_started'))
cuts = {e['connection_epoch']: time(e['accept_capture_from']) for e in events if e['event_type'] == 'input.reconnected'}
submitted_by_epoch = collections.defaultdict(bytes)
identical = True
fresh = True
coverage = []
ages = collections.defaultdict(list)
for row in index:
    epoch = row['connection_epoch']
    # The fixture producer submits consecutive 100 ms frames; the last is shorter.
    start = round((time(row['capture_started_at']) - origin) * 10) * 1600
    count, offset = row['sample_count'], row['sample_offset']
    data = uploaded[offset*2:(offset+count)*2]
    identical &= data == source[start*2:(start+count)*2]
    submitted_by_epoch[epoch] += data
    coverage.append((start, start+count, 'sent'))
    if epoch in cuts:
        fresh &= time(row['capture_started_at']) >= cuts[epoch] - .001
    ages[epoch].append(time(row['submitted_at']) - time(row['capture_started_at']))
discarded = [e for e in events if e['event_type'] == 'input.discarded']
for event in discarded:
    start = round((time(event['capture_started_at']) - origin) * 10) * 1600
    coverage.append((start, start+event['sample_count'], 'discarded'))
position = 0
accounted = True
for start, end, _ in sorted(coverage):
    accounted &= start == position
    position = end
expected_samples = len(source)//2 if result.get('requested_stop_after') is None else len(uploaded)//2
accounted &= position == expected_samples
encoder_checks = []
observed_path = directory / 'audio/webrtc-input-observed.wav'
if observed_path.exists():
    observed = pcm(observed_path)
    for row in manifest.get('encoder_epochs', []):
        epoch, offset, count = row['connection_epoch'], row['sample_offset'], row['sample_count']
        expected = submitted_by_epoch[epoch]
        encoder_checks.append({'epoch': epoch, 'prefix_identical': observed[offset*2:(offset+count)*2] == expected[:count*2],
                               'discarded_old_encoder_tail_samples': len(expected)//2-count})
last_epoch = max(submitted_by_epoch, default=0)
final_finish = next((e.get('confirmed', False) for e in reversed(events) if e['event_type'] == 'connection.final_finish'), False)
post_text = {track: any(e['event_type'] in ('text.append', 'text.replace') and e.get('connection_epoch') == last_epoch and e.get('track') == track and e.get('text') for e in events) for track in ['source', 'translation']}
underflow = max((e.get('underflow_samples', 0) for e in events), default=0)
report = {
    'original_samples': len(source)//2, 'submitted_samples': len(uploaded)//2,
    'explicitly_discarded_input_samples': sum(e['sample_count'] for e in discarded),
    'all_input_accounted_once': bool(accounted), 'submitted_pcm_matches_original_positions': bool(identical),
    'reconnected_epochs': sorted(cuts), 'no_pre_reconnect_audio_replayed': bool(fresh),
    'max_capture_to_submit_seconds_by_epoch': {str(k): round(max(v),3) for k,v in ages.items()},
    'encoder_checks': encoder_checks, 'encoder_underflow_samples': underflow,
    'last_epoch_has_source': post_text['source'], 'last_epoch_has_translation': post_text['translation'],
    'last_connection_tail_confirmed': final_finish,
    'recovery_controls': [{k:e[k] for k in ['can_stop','mode_changes_blocked']} for e in events if e['event_type'] == 'verification.recovery_controls'],
    'scope': 'Client capture positions, PCM bytes, encoder continuity, subtitle recovery and documented finish; no remote PCM acknowledgement.'
}
report['recovery_success'] = bool(cuts and accounted and identical and fresh and underflow == 0 and final_finish
    and all(max(v) < .8 for v in ages.values()) and encoder_checks
    and all(e['prefix_identical'] and e['discarded_old_encoder_tail_samples'] >= 0 for e in encoder_checks)
    and encoder_checks[-1]['discarded_old_encoder_tail_samples'] == 0
    and post_text['source'] and post_text['translation'] and result.get('error') is None
    and (result['mode'] != 'speech' or result.get('translated_samples',0)>0)
    and all(c['can_stop'] and c['mode_changes_blocked'] for c in report['recovery_controls']))
output = result_path.with_name('recovery-audit.json')
output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
sys.exit(0 if report['recovery_success'] else 1)
