#!/usr/bin/env python3
"""Finite, distinct public voices for development/held-out replay; no TTS or loops."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import urllib.request
import wave

root = Path(__file__).resolve().parent.parent / 'TestResults/fixtures/jev-voices'
root.mkdir(parents=True, exist_ok=True)
speakers = {'1089/134686': ('development', 5), '1221/135766': ('held_out', 5)}
wanted = {}
for chapter, (_, count) in speakers.items():
    speaker, book = chapter.split('/')
    for name in [f'{speaker}-{book}-{i:04}.flac' for i in range(count)] + [f'{speaker}-{book}.trans.txt']:
        target = root / chapter / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            wanted[f'LibriSpeech/test-clean/{chapter}/{name}'] = target
url = 'https://openslr.trmal.net/resources/12/test-clean.tar.gz'
if wanted:
    with urllib.request.urlopen(url, timeout=90) as response:
        with tarfile.open(fileobj=response, mode='r|gz') as archive:
            for entry in archive:
                if entry.name in wanted and entry.isfile():
                    if entry.size > 20_000_000:
                        raise ValueError('Unexpected file size')
                    wanted.pop(entry.name).write_bytes(archive.extractfile(entry).read())
                    if not wanted:
                        break
    if wanted:
        raise ValueError(f'Missing public fixtures: {list(wanted)}')
manifest = []
for chapter, (split, count) in speakers.items():
    speaker, book = chapter.split('/')
    folder = root / chapter
    references = dict(line.split(' ', 1) for line in (folder / f'{speaker}-{book}.trans.txt').read_text().splitlines())
    pcm = bytearray()
    clips = []
    for i in range(count):
        uid = f'{speaker}-{book}-{i:04}'
        chunk = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(folder / f'{uid}.flac'), '-f', 's16le', '-ac', '1', '-ar', '16000', '-'])
        clips.append({'id': uid, 'start_seconds': len(pcm)/32000, 'reference': references[uid]})
        pcm.extend(chunk)
    target = root / f'{speaker}.wav'
    with wave.open(str(target), 'wb') as out:
        out.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        out.writeframes(pcm)
    item = {'speaker': speaker, 'chapter': chapter, 'split': split, 'audio_path': str(target), 'seconds': len(pcm)/32000,
            'pcm_sha256': hashlib.sha256(pcm).hexdigest(), 'clips': clips, 'license': 'CC BY 4.0',
            'source_page': 'https://www.openslr.org/12/', 'archive_url': url,
            'processing': 'Five consecutive original utterances once each in chapter order. Lossless PCM decoding; no TTS, loops, gain or inserted silence.'}
    (root / f'{speaker}-provenance.json').write_text(json.dumps(item, ensure_ascii=False, indent=2)+'\n')
    manifest.append(item)
(root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
print(json.dumps([{k: x[k] for k in ['speaker', 'split', 'seconds', 'audio_path']} for x in manifest], ensure_ascii=False))
