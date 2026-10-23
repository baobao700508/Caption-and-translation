#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 || $# -gt 3 ]]; then
  printf '%s\n' '用法：verify-live.sh <transcribe|translate|all> <测试配置.json> [subtitles|speech]' >&2
  exit 2
fi
if [[ ! -f "$2" ]]; then printf '%s\n' '测试配置文件不存在。' >&2; exit 2; fi
export DEVELOPER_DIR="${LIVECAPTION_DEVELOPER_DIR:-$(xcode-select -p)}"
build_path="${LIVECAPTION_BUILD_PATH:-.build-selected-toolchain}"
python3 scripts/prepare-human-fixture.py
swift run --scratch-path "$build_path" -c release LiveCaptionVerify TestResults/fixtures/librispeech/human-speech.wav "$1" "$2" "${3:-subtitles}"
