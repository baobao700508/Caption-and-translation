#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${LIVECAPTION_DEVELOPER_DIR:-$(xcode-select -p)}"
build_path="${LIVECAPTION_BUILD_PATH:-.build-selected-toolchain}"
bash scripts/setup-webrtc.sh
swift build --scratch-path "$build_path" --product LiveCaption -j 6
test_root="$(mktemp -d /private/tmp/LiveCaption-Layout.XXXXXX)"
app="$test_root/CaptionLayoutCheck.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp "$build_path/debug/LiveCaption" "$app/Contents/MacOS/LiveCaption"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.livecaption.caption-layout-check' "$app/Contents/Info.plist"
ditto Vendor/webrtc/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework "$app/Contents/Frameworks/WebRTC.framework"
codesign --force --sign - "$app/Contents/Frameworks/WebRTC.framework"
codesign --force --sign - "$app"
result="$test_root/result.json"
open -n -W "$app" --args --verify-caption-layout "$result" --verification-exit "$@"
destination="$PWD/TestResults/caption-layout-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$destination"
cp "$result" "$destination/result.json"
for screenshot in "$test_root"/*.png; do
  if [[ -f "$screenshot" ]]; then cp "$screenshot" "$destination/"; fi
done
result="$destination/result.json"
python3 - "$result" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);r=json.loads(p.read_text())
for key,passed in r['checks'].items(): print(('PASS ' if passed else 'FAIL ')+key)
print(str(p))
raise SystemExit(0 if r['success'] else 1)
PY
