#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-subtitles}"
config="${2:-$HOME/Desktop/LiveCaption配置.json}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ $# -gt 0 ]]; then shift; fi
case "$mode" in subtitles|speech|transcribe) ;; *) echo '模式须为 subtitles、speech 或 transcribe'; exit 2;; esac
python3 scripts/prepare-human-fixture.py
if [[ "${LIVECAPTION_SKIP_BUILD:-0}" != 1 ]]; then bash scripts/build.sh; fi
test_root="$(mktemp -d /private/tmp/LiveCaption-Human.XXXXXX)"
trap 'rm -f "$test_root/config.json"' EXIT
ditto dist/LiveCaption.app "$test_root/HumanCheck.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.livecaption.human-check' "$test_root/HumanCheck.app/Contents/Info.plist"
codesign --force --sign - "$test_root/HumanCheck.app"
cp "$config" "$test_root/config.json"
chmod 600 "$test_root/config.json"
fixture="${LIVECAPTION_HUMAN_FIXTURE:-$PWD/TestResults/fixtures/librispeech/human-speech.wav}"
cp "$fixture" "$test_root/input.wav"
extra=(--verification-exit "$@")
if [[ "$mode" == speech ]]; then extra+=(--file-speech); fi
if [[ "$mode" == transcribe ]]; then extra+=(--file-transcribe); fi
python3 scripts/watch-native-verification.py "$test_root" "$test_root/HumanCheck.app/Contents/MacOS/LiveCaption" --verify-file "$test_root/input.wav" "$test_root/result.json" "$test_root/config.json" "${extra[@]}"
destination="$PWD/TestResults/human-$mode-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$destination"
cp "$test_root/result.json" "$destination/result.json"
if [[ -f "$test_root/caption.png" ]]; then cp "$test_root/caption.png" "$destination/caption.png"; fi
for live_image in live-before-model.png live-model-split.png; do
  if [[ -f "$test_root/$live_image" ]]; then cp "$test_root/$live_image" "$destination/"; fi
done
if [[ -d "$test_root/app-file-logs" ]]; then ditto "$test_root/app-file-logs" "$destination/app-file-logs"; fi
for evidence in ui-heartbeat.json ui-watchdog.json blocked.sample.txt native-process.log; do
  if [[ -f "$test_root/$evidence" ]]; then cp "$test_root/$evidence" "$destination/"; fi
done
python3 - "$destination" "$fixture" <<'PY'
import json,sys,subprocess,os
from pathlib import Path
p=Path(sys.argv[1]);result=json.loads((p/'result.json').read_text())
if result.get('log_path'):
    old=Path(result['log_path'])
    result['log_path']=str(p/'app-file-logs'/old.parent.name/old.name)
result['fixture_path']=str(Path(sys.argv[2]).resolve())
(p/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
if result.get('log_path') and result.get('mode') != 'transcribe':
    subprocess.run([sys.executable,'scripts/analyze-caption-latency.py',result['log_path'],'--output',str(p/'latency-audit.json')],stdout=subprocess.DEVNULL,check=False)
    latency=json.loads((p/'latency-audit.json').read_text())
    result['protocol_and_content_success']=result['success']
    result['provider_event_lag_max_seconds']=latency['maximum_provider_event_lag_seconds']
    result['provider_event_latency_pass']=latency['within_provider_lag_budget']
    result['first_text_delay_max_seconds']=latency['maximum_first_text_delay_seconds']
    result['first_text_latency_pass']=latency['within_first_text_budget']
    result['success']=result['success'] and latency['success']
    (p/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    reference=os.environ.get('LIVECAPTION_LATENCY_REFERENCE')
    if reference:
        subprocess.run([sys.executable,'scripts/compare-caption-progress.py',result['log_path'],reference,'--output',str(p/'source-progress.json')],stdout=subprocess.DEVNULL,check=False)
        progress=json.loads((p/'source-progress.json').read_text())
        result['source_progress_pass']=progress['success']
        result['success']=result['success'] and progress['success']
        (p/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
if result.get('injected_disconnect_after') is not None:
    subprocess.run([sys.executable,'scripts/analyze-recovery.py',str(p/'result.json')],stdout=subprocess.DEVNULL,check=False)
    audit=json.loads((p/'recovery-audit.json').read_text())
    result['full_input_success']=result['success']
    result['success']=audit['recovery_success'] and result.get('provider_event_latency_pass',True) and result.get('first_text_latency_pass',True) and result.get('source_progress_pass',True)
    result['acceptance']='intentional_gap_with_fresh_recovery'
    (p/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
for key in ('success','input_pcm_byte_identical','live_readable_while_running','live_window_responsive','maximum_main_actor_gap_seconds','provider_event_lag_max_seconds','provider_event_latency_pass','first_text_delay_max_seconds','first_text_latency_pass','reflow_status','reflow_applied_count','tail_confirmed'):
    print(key, result.get(key))
print(p/'result.json')
raise SystemExit(0 if result['success'] else 1)
PY
