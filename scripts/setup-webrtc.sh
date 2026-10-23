#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
framework=Vendor/webrtc/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework
if [[ -f "$framework/WebRTC" ]]; then exit 0; fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/livecaption-webrtc.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
curl --fail --location --silent --show-error --max-time 120 https://github.com/stasel/WebRTC/releases/download/155.0.0/WebRTC-M155.xcframework.zip -o "$scratch/sdk.zip"
python3 - "$scratch/sdk.zip" <<'PY'
import hashlib,pathlib,sys
assert hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() == 'cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe', 'WebRTC SDK checksum mismatch'
PY
mkdir -p Vendor/webrtc
unzip -q "$scratch/sdk.zip" 'WebRTC.xcframework/macos-x86_64_arm64/*' 'WebRTC.xcframework/LICENSE' -d Vendor/webrtc
