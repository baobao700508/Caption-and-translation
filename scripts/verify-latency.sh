#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -f "$PWD/dist/LiveCaption.app/Contents/MacOS/LiveCaption" >/dev/null; then
  printf '请先结束并退出 LiveCaption。\n'; exit 2
fi
mkdir -p TestResults/fixtures
  python3 - <<'PY'
from pathlib import Path
import wave,math,array
with wave.open('TestResults/fixtures/classroom.wav','rb') as f: params=f.getparams();frames=f.readframes(f.getnframes())
with wave.open('TestResults/fixtures/latency.wav','wb') as f:
 f.setparams(params);warmup=array.array("h",(int(1000*math.sin(2*math.pi*440*i/16000)) for i in range(3200))).tobytes();f.writeframes(warmup+bytes(10*16000*2)+frames*4)
PY
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/LiveCaption-Latency.XXXXXX")"
python3 - "$run_dir" <<'PY'
from pathlib import Path
import sys,os
fd=os.open(Path(sys.argv[1])/'config.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'wb') as f:f.write((Path.home()/'Desktop/LiveCaption配置.json').read_bytes())
PY
trap 'rm -f "$run_dir/config.json"' EXIT
args=(--verify-latency "$PWD/TestResults/fixtures/latency.wav" "$run_dir/result.json" "$run_dir/config.json" --verification-exit)
if [[ "${1:-subtitles}" == speech ]]; then args+=(--latency-speech); fi
open -a "$PWD/dist/LiveCaption.app" --args "${args[@]}"
for ((attempt=0;attempt<240;attempt++)); do
 if [[ -f "$run_dir/result.json" ]]; then
  destination="TestResults/latency-${1:-subtitles}-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$destination"
  cp "$run_dir/result.json" "$destination/result.json"
  cp -R "$run_dir/latency-logs" "$destination/"
  session_path="$(python3 - "$destination" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1]);r=json.loads((p/'result.json').read_text())
if 'log_path' not in r: raise SystemExit(r.get('error','未启动采集'))
print(p/'latency-logs'/Path(r['log_path']).parent.name/Path(r['log_path']).name)
PY
)"
  python3 scripts/check-latency.py "$session_path" --speech-onset --report "$destination/latency.json"
  exit $?
 fi
 sleep 0.5
done
printf '延迟测试尚未完成；请检查系统权限提示。\n'; exit 2
