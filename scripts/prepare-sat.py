#!/usr/bin/env python3
"""Install pinned dependencies and verified models, then prove offline inference."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import urllib.request


def emit(phase, message, **fields):
    print(json.dumps(dict(phase=phase, message=message, **fields), ensure_ascii=False), flush=True)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def fetch(item, destination, opener=urllib.request.urlopen):
    """Never publish partial or corrupt bytes as a model file."""
    if destination.exists() and digest(destination) == item['sha256']:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + '.partial')
    try:
        request = urllib.request.Request(item['url'], headers={'User-Agent': 'LiveCaption/1'})
        received = 0
        updated = 0
        with opener(request, timeout=60) as response, partial.open('wb') as stream:
            while chunk := response.read(1024 * 1024):
                stream.write(chunk)
                received += len(chunk)
                if time.monotonic() - updated > .3:
                    emit('model', '正在下载 ' + destination.name, received=received, total=item['bytes'])
                    updated = time.monotonic()
        if received != item['bytes'] or digest(partial) != item['sha256']:
            raise ValueError('模型文件校验失败：' + destination.name)
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)


def atomic_json(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False) + '\n')
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--requirements', required=True, type=Path)
    parser.add_argument('--model', required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if args.model not in manifest['models'] or args.model == 'tokenizer':
        raise ValueError('不支持的 SaT 模型')
    base = args.root / 'SaT'
    runtime = Path(sys.executable).resolve().parent.parent
    requirements_hash = digest(args.requirements)
    dependency_marker = runtime / '.dependencies.json'
    expected = dict(version=manifest['runtimeVersion'], requirements=requirements_hash)
    healthy = subprocess.run([sys.executable, '-c', 'from wtpsplit import SaT; import onnxruntime, sentencepiece'],
                             stdout=sys.stderr, stderr=sys.stderr).returncode == 0
    if not healthy or not dependency_marker.exists() or json.loads(dependency_marker.read_text()) != expected:
        emit('dependencies', '正在安装 SaT 依赖；详细下载记录写入安装日志…')
        # Terminate pip as well when the user cancels the App's worker.
        pip = subprocess.Popen([sys.executable, '-m', 'pip', 'install', '--disable-pip-version-check',
                                '--timeout', '60', '--retries', '2', '--prefer-binary',
                                *([] if healthy else ['--force-reinstall']),
                                '-r', str(args.requirements)], stdout=sys.stderr, stderr=sys.stderr,
                               start_new_session=True)
        def cancel(signum, frame):
            try:
                os.killpg(pip.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            pip.wait()
            raise SystemExit(130)
        old = signal.signal(signal.SIGTERM, cancel)
        try:
            if pip.wait() != 0:
                raise RuntimeError('依赖下载或安装失败，请查看安装日志后重试')
        finally:
            signal.signal(signal.SIGTERM, old)
        atomic_json(dependency_marker, expected)
    folder = base / 'models' / args.model
    tokenizer = base / 'tokenizer'
    folder.mkdir(parents=True, exist_ok=True)
    # Remove readiness before any repair. A crash cannot leave a valid marker for partial files.
    marker = folder / 'ready.json'
    marker.unlink(missing_ok=True)
    for name, destination in [(args.model, folder), ('tokenizer', tokenizer)]:
        for item in manifest['models'][name]['files']:
            fetch(item, destination / item['name'])
    emit('verify', '文件校验完成，正在验证离线分段…')
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    from wtpsplit import SaT
    import onnxruntime as ort
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    engine = SaT(str(folder), tokenizer_name_or_path=str(tokenizer),
                 ort_providers=['CPUExecutionProvider'], ort_kwargs={'sess_options': options})
    text = 'This is the first sentence. This is the second sentence. 这是本地分段检查。'
    if len(engine.predict_proba(text)) != len(text):
        raise RuntimeError('离线分段验证未通过')
    atomic_json(marker, dict(model=args.model, revision=manifest['models'][args.model]['revision'],
                             runtime=str(runtime), runtimeVersion=manifest['runtimeVersion']))
    emit('ready', 'SaT 已下载并通过离线推理验证')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        emit('error', str(error))
        raise SystemExit(1)
