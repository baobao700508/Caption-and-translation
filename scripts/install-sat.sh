#!/bin/bash
# Shared bootstrap for the App and developers. Requires only macOS system tools.
set -euo pipefail
resources="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$resources/../Resources/LocalModels.json" ]]; then resources="$(cd "$resources/../Resources" && pwd)"; fi
manifest="$resources/LocalModels.json"
helper="$(dirname "$0")/prepare-sat.py"
root="${LIVECAPTION_MODEL_HOME:-$HOME/Library/Application Support/LiveCaption}"
model="${1:-sat-3l}"
case "$model" in --runtime-only) model="" ;; sat-3l|sat-3l-sm|sat-12l|sat-3l-no-limited-lookahead) ;; *) exit 64 ;; esac
arch="$(uname -m)"
version="$(/usr/bin/plutil -extract runtimeVersion raw -o - "$manifest")"
base="$root/SaT/$version-$arch"
mkdir -p "$root/SaT"
lock="$root/SaT/.install-lock"
if ! mkdir "$lock" 2>/dev/null; then
  owner="$(cat "$lock/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
    rm -rf "$lock"; mkdir "$lock"
  else
    printf '%s\n' '另一个 SaT 安装任务正在运行，请稍后重试。' >&2; exit 75
  fi
fi
printf '%s' "$$" > "$lock/pid"
child=""
scratch=""
cleanup() { if [[ -n "$scratch" ]]; then rm -rf "$scratch"; fi; rm -rf "$lock"; }
cancel() { if [[ -n "$child" ]]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi; exit 130; }
trap cleanup EXIT
trap cancel TERM INT
run() { "$@" & child=$!; wait "$child"; child=""; }
if [[ ! -x "$base/bin/python3" ]]; then
  url="$(/usr/bin/plutil -extract "python.$arch.url" raw -o - "$manifest")"
  sha="$(/usr/bin/plutil -extract "python.$arch.sha256" raw -o - "$manifest")"
  scratch="$(mktemp -d "$root/SaT/.bootstrap.XXXXXX")"
  printf '%s\n' '{"phase":"runtime","message":"正在下载独立 Python；无需安装系统 Python…"}'
  run /usr/bin/curl --fail --location --silent --show-error --retry 2 --connect-timeout 30 --max-time 600 "$url" -o "$scratch/python.tar.gz"
  actual="$(/usr/bin/shasum -a 256 "$scratch/python.tar.gz")"
  [[ "${actual%% *}" == "$sha" ]] || { printf '%s\n' 'Python 下载校验失败，请重试。' >&2; exit 65; }
  run /usr/bin/tar -xzf "$scratch/python.tar.gz" -C "$scratch"
  mv "$scratch/python" "$base"
fi
export PYTHONNOUSERSITE=1
export TOKENIZERS_PARALLELISM=false
if [[ -n "$model" ]]; then
  run "$base/bin/python3" -u "$helper" --root "$root" --manifest "$manifest" --requirements "$resources/SaT-requirements.txt" --model "$model"
fi
