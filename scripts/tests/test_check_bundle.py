"""A passing receipt must identify exact portable bundle bytes."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('check_bundle', Path(__file__).resolve().parents[1]/'check-bundle.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class BundleIdentityTests(unittest.TestCase):
    def test_content_and_execution_permission_change_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            file = root/'runtime'
            file.write_bytes(b'first engine')
            first = gate.inventory(root)[0]
            file.write_bytes(b'other engine')
            second = gate.inventory(root)[0]
            self.assertNotEqual(first, second)
            file.chmod(0o755)
            self.assertNotEqual(second, gate.inventory(root)[0])

    def test_relocation_preserves_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)/'Virtual.app'
            root.mkdir()
            (root/'runtime').write_bytes(b'engine')
            (root/'alias').symlink_to('runtime')
            first = gate.inventory(root)[0]
            other = root.with_name('Moved.app')
            root.rename(other)
            self.assertEqual(first, gate.inventory(other)[0])

    def test_external_and_broken_links_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)/'Virtual.app'
            root.mkdir()
            link = root/'alias'
            link.symlink_to('../outside')
            with self.assertRaisesRegex(ValueError, 'verlässt'):
                gate.inventory(root)
            link.unlink()
            link.symlink_to('missing')
            with self.assertRaisesRegex(ValueError, 'fehlt'):
                gate.inventory(root)

    def test_bundle_without_engine_cannot_be_certified(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'Contents/MacOS').mkdir(parents=True)
            (root/'Contents/MacOS/Virtual').write_bytes(b'launcher')
            with self.assertRaisesRegex(ValueError, 'Unvollständiges'):
                gate.require_bundle(root)

    def test_failed_retry_invalidates_previous_success_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = root/'verified.json'
            receipt.write_text('{"core_gate":"passed"}')
            with patch('sys.argv', ['check-bundle.py', str(root/'missing.app'), '--receipt', str(receipt)]):
                with self.assertRaises(ValueError):
                    gate.main()
            self.assertFalse(receipt.exists())


if __name__ == '__main__':
    unittest.main()
