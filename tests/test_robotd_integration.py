"""Host-only delivery tests: fake ELF headers never execute robot code."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('robot_component', ROOT / 'tools/robotd_component.py')
component = importlib.util.module_from_spec(spec)
spec.loader.exec_module(component)


def fixture(root):
    root.mkdir(parents=True, exist_ok=True)
    header = b'\x7fELF\x02\x01' + b'\0' * 12 + b'\xb7\0'
    for name in component.REQUIRED:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if name.startswith(('bin/', 'lib/')):
            path.write_bytes(header)
        elif name.endswith('.service'):
            path.write_text('[Service]\nGroup=robot\nExecStart=/opt/robot/daemon/current/bin/robotd\n')
        else:
            path.write_text('[bus]\nprotocol="feetech-sts"\n')
    manifest = dict(schema=component.SCHEMA, version='1.2.3', source='test release',
                    source_revision='test-revision', files=component.files(root))
    (root / component.MANIFEST).write_text(json.dumps(manifest))
    return component.digest(root / component.MANIFEST)


class RobotdTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.sha = fixture(self.source)
        self.lock = self.root / 'components.lock.yaml'
        self.lock.write_text('image: 1.0.0\nrobotd: pending\n')
        self.output = self.root / 'assembled'

    def test_pinned_assembly_and_tamper(self):
        component.assemble(self.source, self.sha, self.output, self.lock)
        self.assertEqual(component.locked(self.output, self.lock)['version'], '1.2.3')
        (self.output / 'bin/robotctl').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'hashes'):
            component.locked(self.output, self.lock)

    def test_wrong_pin_and_missing_artifact(self):
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            component.assemble(self.source, '0' * 64, self.output, self.lock)
        (self.source / 'lib/libonnxruntime.so').unlink()
        with self.assertRaises(ValueError):
            component.verify(self.source)

    def test_architecture_validation(self):
        (self.source / 'bin/robotd').write_bytes(b'not ARM64')
        data = json.loads((self.source / component.MANIFEST).read_text())
        data['files'] = component.files(self.source)
        (self.source / component.MANIFEST).write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'ARM64'):
            component.verify(self.source)

    @unittest.skipIf(__import__('os').name == 'nt', 'native installation symlinks require Linux')
    def test_install_preserves_config_and_does_not_start_service(self):
        component.assemble(self.source, self.sha, self.output, self.lock)
        target = self.root / 'target'
        config = target / 'etc/robot/robotd.toml'
        config.parent.mkdir(parents=True)
        config.write_text('user configuration')
        with patch.object(component.subprocess, 'run', return_value=SimpleNamespace(stdout='')) as run:
            component.install(self.output, target, self.lock)
        self.assertTrue(all(args.args[0][0] == 'readelf' for args in run.call_args_list))
        self.assertEqual(config.read_text(), 'user configuration')
        self.assertTrue((target / 'opt/robot/daemon/current/bin/robotctl').is_file())
        self.assertTrue((target / 'usr/local/bin/robotctl').exists())

    def test_missing_dynamic_dependency_fails_before_install(self):
        component.assemble(self.source, self.sha, self.output, self.lock)
        with patch.object(component.subprocess, 'run', return_value=SimpleNamespace(
                stdout='(NEEDED) Shared library: [libmissing.so]')):
            with self.assertRaisesRegex(ValueError, 'libmissing'):
                component.install(self.output, self.root / 'target', self.lock)
        self.assertFalse((self.root / 'target').exists())

    def test_all_delivery_entrypoints_and_pwm_manifest_root(self):
        for name in ('build-image.sh', 'build-from-armbian.sh', 'install.sh'):
            text = (ROOT / name).read_text('utf-8')
            self.assertIn('robotd_component.py" install', text)
        text = (ROOT / 'install.sh').read_text('utf-8')
        self.assertIn('zelux-build-pwm-overlays /boot / ', text)
        self.assertNotIn('zelux-build-pwm-overlays /boot /usr ', text)
