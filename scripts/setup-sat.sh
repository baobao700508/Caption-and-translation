#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
runtime="${LIVECAPTION_SAT_RUNTIME:-$HOME/Library/Application Support/LiveCaption/SaT/runtime}"
python="${LIVECAPTION_SAT_BASE_PYTHON:-python3}"
"$python" -c 'import sys; assert sys.version_info >= (3,9), "SaT requires Python 3.9 or newer"'
if [[ ! -x "$runtime/bin/python3" ]]; then "$python" -m venv "$runtime"; fi
"$runtime/bin/python3" -m pip install 'wtpsplit[onnx-cpu]==2.2.2' 'transformers>=4.39,<5' sentencepiece
printf 'SaT 本地运行环境已准备：%s\n' "$runtime/bin/python3"
printf '首次推理会下载所选模型；字幕文字只在本机处理。\n'
