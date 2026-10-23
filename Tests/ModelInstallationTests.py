import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('prepare_sat', Path(__file__).resolve().parents[1] / 'scripts/prepare-sat.py')
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class ModelInstallationTests(unittest.TestCase):
    def test_verified_download_reuses_complete_bytes_without_network(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'model.onnx'
            payload = b'complete model bytes'
            item = dict(url='https://example.invalid/model', bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())
            calls = []
            def opener(request, timeout):
                calls.append(request.full_url)
                return io.BytesIO(payload)
            with contextlib.redirect_stdout(io.StringIO()):
                INSTALLER.fetch(item, target, opener)
                INSTALLER.fetch(item, target, opener)
            self.assertEqual(target.read_bytes(), payload)
            self.assertEqual(len(calls), 1)
            self.assertFalse(target.with_suffix('.onnx.partial').exists())

    def test_corrupt_download_is_not_published_and_retry_repairs_it(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'model.onnx'
            payload = b'correct model'
            item = dict(url='https://example.invalid/model', bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())
            target.write_bytes(b'previous corruption')
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(ValueError):
                    INSTALLER.fetch(item, target, lambda *a, **k: io.BytesIO(b'truncated'))
                self.assertFalse(target.with_suffix('.onnx.partial').exists())
                self.assertNotEqual(target.read_bytes(), payload)
                INSTALLER.fetch(item, target, lambda *a, **k: io.BytesIO(payload))
            self.assertEqual(target.read_bytes(), payload)

    def test_interrupted_download_cleans_partial_and_keeps_existing_file(self):
        class Broken(io.BytesIO):
            def read(self, size=-1):
                raise OSError('connection interrupted')
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'model.onnx'
            target.write_bytes(b'old bytes')
            item = dict(url='https://example.invalid/model', bytes=5, sha256='a'*64)
            with self.assertRaises(OSError):
                INSTALLER.fetch(item, target, lambda *a, **k: Broken())
            self.assertEqual(target.read_bytes(), b'old bytes')
            self.assertFalse(target.with_suffix('.onnx.partial').exists())


if __name__ == '__main__':
    unittest.main()
