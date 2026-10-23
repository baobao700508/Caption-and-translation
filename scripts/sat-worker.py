#!/usr/bin/env python3
"""Local, newline-delimited SaT inference. stdout is reserved for the protocol."""
import contextlib
import json
import os
import sys
import time

os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')
models = {}


def infer(request):
    if request.get('version') != 1:
        raise ValueError('unsupported protocol')
    model_name = request['model']
    if model_name not in ('sat-3l', 'sat-3l-no-limited-lookahead', 'sat-3l-sm', 'sat-12l'):
        raise ValueError('unsupported model')
    begin = time.monotonic()
    cold = model_name not in models
    if cold:
        with contextlib.redirect_stdout(sys.stderr):
            from wtpsplit import SaT
            import onnxruntime as ort
            options = ort.SessionOptions()
            options.intra_op_num_threads = 2
            options.inter_op_num_threads = 1
            models.clear()  # At most one loaded model per App process.
            models[model_name] = SaT(model_name, ort_providers=['CPUExecutionProvider'],
                                    ort_kwargs={'sess_options': options})
    loaded = time.monotonic()
    tracks = []
    for name in ('source', 'translation'):
        atoms = request[name]
        if not isinstance(atoms, list) or any(not isinstance(x, str) for x in atoms):
            raise ValueError('invalid atoms')
        text = ''.join(atoms)
        if len(text) > 24000:
            raise ValueError('input budget exceeded')
        if not text.strip():
            tracks.append([])
            continue
        with contextlib.redirect_stdout(sys.stderr):
            probs = models[model_name].predict_proba(text)
        # SaT scores the character before a boundary. Preserve every original byte,
        # including whitespace: the Swift renderer alone owns display text.
        result = []
        chars = 0
        for i, atom in enumerate(atoms):
            trimmed = atom.rstrip()
            end = chars + len(trimmed)
            if trimmed:
                score = float(probs[end - 1])
                result.append({'end': i + 1, 'probability': score})
            chars += len(atom)
        tracks.append(result)
    return {'version': 1, 'model': model_name, 'cold_start': cold,
            'load_seconds': loaded - begin, 'inference_seconds': time.monotonic() - loaded,
            'execution_provider': 'CPUExecutionProvider',
            'source': tracks[0], 'translation': tracks[1]}


for line in sys.stdin:
    try:
        request = json.loads(line)
        response = infer(request)
    except Exception as error:
        response = {'version': 1, 'error_type': type(error).__name__}
        print('SaT worker failed: ' + type(error).__name__, file=sys.stderr, flush=True)
    print(json.dumps(response, ensure_ascii=False, allow_nan=False), flush=True)
