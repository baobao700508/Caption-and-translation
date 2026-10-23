#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/setup-webrtc.sh
export DEVELOPER_DIR="${LIVECAPTION_DEVELOPER_DIR:-$(xcode-select -p)}"
build_path="${LIVECAPTION_BUILD_PATH:-.build-selected-toolchain}"
mkdir -p TestResults
swift build --scratch-path "$build_path" --product LiveCaptionChecks -j 6
"$build_path/debug/LiveCaptionChecks" | tee TestResults/offline-checks.txt
