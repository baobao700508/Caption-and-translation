#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
bash scripts/setup-webrtc.sh
if [[ $# -lt 1 ]]; then
  printf '用法：verify-transport.sh <16kHz单声道PCM16.wav> [default|websocket|network|aoq|webrtc|webkit-webrtc] [subtitles|speech|transcribe]\n'
  exit 2
fi
audio="$1"
transport="${2:-default}"
mode="${3:-subtitles}"
case "$transport" in default|websocket|network|aoq|webrtc|native-webrtc|webkit-webrtc) ;; *) exit 2 ;; esac
case "$mode" in subtitles|speech) pipeline=translate ;; transcribe) pipeline=transcribe; mode=subtitles ;; *) exit 2 ;; esac
export DEVELOPER_DIR="${LIVECAPTION_DEVELOPER_DIR:-$(xcode-select -p)}"
swift build --scratch-path .build-selected-toolchain --product LiveCaptionVerify -c release -j 6
bundle="$PWD/TestResults/TransportVerifier.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks"
cp .build-selected-toolchain/release/LiveCaptionVerify "$bundle/Contents/MacOS/LiveCaptionVerify"
ditto Vendor/aoq/AoqClientSdk.framework "$bundle/Contents/Frameworks/AoqClientSdk.framework"
ditto Vendor/aoq/PluginOpus.framework "$bundle/Contents/Frameworks/PluginOpus.framework"
ditto Vendor/webrtc/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework "$bundle/Contents/Frameworks/WebRTC.framework"
ditto Vendor/aoq/AoqClientSdk.framework/Versions/A/Frameworks/openhevc.framework "$bundle/Contents/Frameworks/openhevc.framework"
python3 - "$bundle" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps({'CFBundleExecutable':'LiveCaptionVerify','CFBundleIdentifier':'local.livecaption.transport-verifier','CFBundlePackageType':'APPL','LSUIElement':True}))
PY
codesign --force --deep --sign - "$bundle"
private_output="$PWD/TestResults/transport-verifier-$(date +%Y%m%d-%H%M%S).txt"
set +e
LIVECAPTION_TRANSPORT="$transport" "$bundle/Contents/MacOS/LiveCaptionVerify" "$audio" "$pipeline" "$HOME/Desktop/LiveCaption配置.json" "$mode" >"$private_output" 2>&1
result=$?
set -e
python3 - "$private_output" <<'PY'
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text(errors='replace').splitlines():
    if line.startswith(('PASS ','FAIL ','验证线路数：','验证报告：','验证未执行：')): print(line)
PY
exit "$result"
