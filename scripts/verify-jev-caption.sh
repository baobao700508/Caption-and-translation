#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 3 ]]; then echo '用法：verify-jev-caption.sh 配置.json 样本.json 输出目录';exit 2;fi
config="$1"
fixtures="$2"
destination="$3"
if [[ "${LIVECAPTION_SKIP_BUILD:-0}" != 1 ]];then bash scripts/build.sh;fi
test_root="$(mktemp -d /private/tmp/LiveCaption-JevView.XXXXXX)"
ditto dist/LiveCaption.app "$test_root/JevView.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.livecaption.jev-view-check' "$test_root/JevView.app/Contents/Info.plist"
codesign --force --sign - "$test_root/JevView.app"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
open -n -W "$test_root/JevView.app" --args --verify-caption-reflow "$destination/result.json" "$config" "$fixtures" --verification-exit
python3 - "$destination/result.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);r=json.loads(p.read_text())
for key,value in r['checks'].items():print(('PASS ' if value else 'FAIL ')+key)
print(p)
raise SystemExit(0 if r['success'] else 1)
PY
