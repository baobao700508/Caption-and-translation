#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${LIVECAPTION_DEVELOPER_DIR:-$(xcode-select -p)}"
build_path="${LIVECAPTION_BUILD_PATH:-.build-selected-toolchain}"
python3 scripts/prepare-human-fixture.py
swift run --scratch-path "$build_path" -c release LiveCaptionVerify TestResults/fixtures/librispeech/human-speech.wav "${1:-translate}" "${2:-$HOME/Desktop/LiveCaption配置.json}" "${3:-subtitles}"
