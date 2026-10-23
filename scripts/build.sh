#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Only the release coordinator may replace the desktop distribution. Explicit
# output paths are for isolated verification bundles and never publish them.
if [[ -z "${LIVECAPTION_APP_PATH:-}" ]]; then
  exec python3 scripts/release.py "$@"
fi
export DEVELOPER_DIR="${LIVECAPTION_DEVELOPER_DIR:-$(xcode-select -p)}"
build_path="${LIVECAPTION_BUILD_PATH:-.build-selected-toolchain}"
export MACOSX_DEPLOYMENT_TARGET=14.2
bash scripts/setup-webrtc.sh
if [[ ! -f Vendor/install/lib/liblivecaption-apm.a ]]; then
  python3 scripts/build_audio.py
fi
swift build --scratch-path "$build_path" --product LiveCaption -c release -j 6
app="$LIVECAPTION_APP_PATH"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
ditto Vendor/webrtc/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework "$app/Contents/Frameworks/WebRTC.framework"
codesign --force --sign - "$app/Contents/Frameworks/WebRTC.framework"
cp "$build_path/release/LiveCaption" "$app/Contents/MacOS/LiveCaption"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp scripts/sat-worker.py "$app/Contents/Resources/sat-worker.py"
cp scripts/install-sat.sh scripts/prepare-sat.py Resources/LocalModels.json Resources/SaT-requirements.txt "$app/Contents/Resources/"
cp Resources/Configuration.example.json "$app/Contents/Resources/"
cp Resources/SaT-LICENSE.txt "$app/Contents/Resources/SaT-LICENSE.txt"
cp Resources/WhisperKit-LICENSE.txt Resources/WhisperKit-NOTICES.txt "$app/Contents/Resources/"
cp Resources/ThirdPartyNotices.txt "$app/Contents/Resources/ThirdPartyNotices.txt"
cat Vendor/webrtc/WebRTC.xcframework/LICENSE >> "$app/Contents/Resources/ThirdPartyNotices.txt"
codesign --force --sign - --entitlements Resources/Entitlements.plist "$app"
codesign --verify --deep --strict "$app"
printf '应用已构建：%s\n' "$app"
