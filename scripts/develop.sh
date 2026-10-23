#!/bin/bash
# A clean clone needs only Xcode and the system shell. Models remain optional.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${LIVECAPTION_DEVELOPER_DIR:-$(xcode-select -p)}"
if ! xcrun --find swift >/dev/null 2>&1; then
  printf '%s\n' '请安装 Xcode／Swift 工具链，打开 Xcode 完成首次组件安装，再运行此命令。' >&2; exit 1
fi
bash scripts/install-sat.sh --runtime-only
root="${LIVECAPTION_MODEL_HOME:-$HOME/Library/Application Support/LiveCaption}"
version="$(/usr/bin/plutil -extract runtimeVersion raw -o - Resources/LocalModels.json)"
export PATH="$root/SaT/$version-$(uname -m)/bin:$PATH"
bash scripts/setup-webrtc.sh
if [[ ! -f Vendor/install/lib/liblivecaption-apm.a ]]; then python3 scripts/build_audio.py; fi
bash scripts/check.sh
export LIVECAPTION_APP_PATH="${LIVECAPTION_APP_PATH:-$PWD/TestResults/development/LiveCaption.app}"
bash scripts/build.sh
printf '开发包已准备：%s\n打开：open "%s"\n' "$LIVECAPTION_APP_PATH" "$LIVECAPTION_APP_PATH"
