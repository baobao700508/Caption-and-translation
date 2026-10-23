#!/usr/bin/env python3
"""Prepare one finite, attributed human-speech fixture; never synthesize or loop."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import wave
import argparse

parser=argparse.ArgumentParser()
parser.add_argument('--utterances',type=int,default=7)
args=parser.parse_args()
if not 7 <= args.utterances <= 20:
    parser.error('Use 7 to 20 consecutive utterances, without repetition.')
suffix='' if args.utterances == 7 else '-'+str(args.utterances)

root = Path(__file__).resolve().parent.parent / "TestResults/fixtures/librispeech"
root.mkdir(parents=True, exist_ok=True)
chapter = "LibriSpeech/test-clean/6930/75918"
names = [f"6930-75918-{i:04}.flac" for i in range(args.utterances)]
transcript = "6930-75918.trans.txt"
url = "https://openslr.trmal.net/resources/12/test-clean.tar.gz"
missing = {name for name in names + [transcript] if not (root / name).exists()}
if missing:
    with urllib.request.urlopen(url, timeout=90) as response:
        with tarfile.open(fileobj=response, mode="r|gz") as archive:
            for entry in archive:
                name = Path(entry.name).name
                if entry.name == f"{chapter}/{name}" and name in missing and entry.isfile():
                    if entry.size > 20_000_000:
                        raise ValueError("Unexpected fixture size")
                    (root / name).write_bytes(archive.extractfile(entry).read())
                    missing.remove(name)
                    if not missing:
                        break
    if missing:
        raise ValueError(f"Missing public fixture files: {sorted(missing)}")
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg:
    raise SystemExit("需要 ffmpeg 将公开 FLAC 无损解码为 PCM；不会生成测试语音。")
references = dict(line.split(" ", 1) for line in (root / transcript).read_text().splitlines())
pcm = bytearray()
clips = []
for name in names:
    chunk = subprocess.check_output([ffmpeg, "-v", "error", "-i", str(root / name),
                                    "-f", "s16le", "-acodec", "pcm_s16le", "-"])
    start = len(pcm) / 32000
    pcm.extend(chunk)
    clips.append({"id": Path(name).stem, "start_seconds": start,
                  "end_seconds": len(pcm) / 32000, "reference": references[Path(name).stem]})
digest = hashlib.sha256(pcm).hexdigest()
if args.utterances == 7 and digest != "d08d93fcd77edd72c20341646f98131b6250c46ca9180e1d3053d689a9ebed9b":
    raise ValueError("Public fixture PCM differs from the verified reference")
with wave.open(str(root / f"human-speech{suffix}.wav"), "wb") as wav:
    wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
    wav.writeframes(pcm)
(root / f"provenance{suffix}.json").write_text(json.dumps({
    "dataset": "LibriSpeech test-clean", "source_page": "https://www.openslr.org/12/",
    "archive_url": url, "license": "CC BY 4.0", "chapter": chapter,
    "selected_files": names, "clips": clips, "duration_seconds": len(pcm) / 32000,
    "pcm_sha256": digest,
    "processing": f"Lossless FLAC decoding; {args.utterances} consecutive utterances once each in chapter order. No synthesis, looping, denoising, gain or inserted silence."
}, ensure_ascii=False, indent=2) + "\n")
print(root / f"human-speech{suffix}.wav")
