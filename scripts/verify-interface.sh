#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -f "$PWD/dist/LiveCaption.app/Contents/MacOS/LiveCaption" >/dev/null; then
  printf '请先退出正在运行的 LiveCaption，再运行隔离界面检查。\n'; exit 2
fi
result="$PWD/TestResults/interface-$(date +%Y%m%d-%H%M%S).json"
mkdir -p TestResults
open -a "$PWD/dist/LiveCaption.app" --args --verify-interface "$result" --verification-exit
for ((attempt=0;attempt<40;attempt++)); do
  if [[ -f "$result" ]]; then
    python3 - "$result" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);d=json.loads(p.read_text())
for name,passed in d['checks'].items():print(('PASS ' if passed else 'FAIL ')+name)
print('原生窗口状态报告：'+str(p))
raise SystemExit(0 if d['success'] else 1)
PY
    exit $?
  fi
  sleep 0.25
done
printf '原生窗口检查尚未返回：%s\n' "$result"
exit 2
