#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
pipeline="${1:-transcribe}"
if [[ "$pipeline" != transcribe && "$pipeline" != translate ]]; then
  printf '参数应为 transcribe 或 translate\n'; exit 2
fi
python3 - "$pipeline" <<'PY'
import json,sys
from pathlib import Path
d=json.loads((Path.home()/'Desktop/LiveCaption配置.json').read_text())
bailian = sys.argv[1] == 'translate' and d.get('translateProvider','google') == 'bailian'
key = 'bailianAPIKey' if bailian else 'apiKey'
if not d.get(key,'').strip(): raise SystemExit('尚未执行云端验证：请先填写桌面配置的 '+key)
if bailian and not d.get('bailianWorkspaceID','').strip(): raise SystemExit('请先填写 bailianWorkspaceID')
PY
if pgrep -f "$PWD/dist/LiveCaption.app/Contents/MacOS/LiveCaption" >/dev/null; then
  printf '请先停止并退出现有 LiveCaption，再运行课堂端到端验证。\n'; exit 2
fi
if [[ ! -f TestResults/fixtures/classroom.wav ]]; then
  mkdir -p TestResults/fixtures
  say -v Samantha -r 155 -o TestResults/fixtures/classroom.aiff 'Today we will discuss energy storage. A battery stores electrical energy. Temperature affects battery lifetime. The experiment begins at twenty five degrees Celsius. Next we compare two different battery materials.'
  afconvert -f WAVE -d LEI16@16000 -c 1 TestResults/fixtures/classroom.aiff TestResults/fixtures/classroom.wav
fi
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/LiveCaption-E2E.XXXXXX")"
python3 - "$run_dir" <<'PY'
from pathlib import Path
import sys,wave,os
config=Path(sys.argv[1])/'config.json'
fd=os.open(config,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'wb') as f:f.write((Path.home()/'Desktop/LiveCaption配置.json').read_bytes())
dest=Path(sys.argv[1])/'fixture.wav'
with wave.open('TestResults/fixtures/classroom.wav','rb') as f: params=f.getparams();frames=f.readframes(f.getnframes())
with wave.open(str(dest),'wb') as f:f.setparams(params);f.writeframes(frames*8)
PY
trap 'task_exit=$?; rm -f "$run_dir/config.json"; exit "$task_exit"' EXIT
launch_args=(--verify-classroom "$run_dir/fixture.wav" "$run_dir/result.json" "$pipeline" --verification-config "$run_dir/config.json" --verification-exit)
if [[ "${2:-}" == switches ]]; then launch_args+=(--verify-switches); fi
open -a "$PWD/dist/LiveCaption.app" --args "${launch_args[@]}"
for ((attempt=0;attempt<360;attempt++)); do
  if [[ -f "$run_dir/result.json" ]]; then
    destination="TestResults/classroom-${pipeline}-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$destination"
    cp "$run_dir/result.json" "$destination/result.json"
    if [[ -d "$run_dir/classroom-fixture-logs" ]]; then cp -R "$run_dir/classroom-fixture-logs" "$destination/"; fi
    python3 - "$destination/result.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);r=json.loads(p.read_text())
print(('PASS' if r.get('success') else 'FAIL')+' classroom '+r.get('pipeline',''))
print('完整结果：'+str(p.resolve()))
raise SystemExit(0 if r.get('success') else 1)
PY
    exit $?
  fi
  sleep 0.5
done
printf '验证尚未完成：可能仍在等待 macOS 授权或连接。临时目录：%s\n' "$run_dir"
exit 2
