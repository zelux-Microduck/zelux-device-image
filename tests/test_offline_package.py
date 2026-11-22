"""Regression test for files needed by the PWM overlay flow in offline packages."""
from __future__ import annotations

import shutil
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GIT_BASH = Path(r"C:\Program Files\Git\bin\bash.exe")
BASH = shutil.which("bash") or (str(GIT_BASH) if GIT_BASH.is_file() else None)


@unittest.skipUnless(BASH, "bash is required to exercise install.sh --pack")
class OfflinePackageTests(unittest.TestCase):
    def test_offline_package_contains_pwm_overlay_compiler_and_sources(self) -> None:
        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        package_name = f"zelux-duck-{version}"
        with tempfile.TemporaryDirectory(prefix="zelux-offline-package-") as tmp:
            component_root = Path(tmp) / "components"
            (component_root / "software/zeluxd").mkdir(parents=True)
            (component_root / "software/systemd").mkdir(parents=True)
            (component_root / "software/systemd/zeluxd.service").write_text(
                "[Unit]\nDescription=test fixture\n", encoding="utf-8"
            )
            env = os.environ.copy()
            env["ZELUX_COMPONENT_ROOT"] = str(component_root)
            env['ZELUX_PYTHON'] = __import__('sys').executable
            from test_robotd_integration import fixture
            robot_sha = fixture(component_root / 'robotd')
            (component_root / 'components.lock.yaml').write_text(
                'robotd: 1.2.3\nrobotd_manifest_sha256: ' + robot_sha + '\n')
            subprocess.run(
                [BASH, str(ROOT / "install.sh"), "--pack"],
                cwd=tmp,
                check=True,
                capture_output=True,
                env=env,
            )
            archive = Path(tmp) / f"{package_name}-arm64.tar.gz"
            self.assertTrue(archive.is_file(), "pack command did not produce the archive")
            with tarfile.open(archive, "r:gz") as bundle:
                names = set(bundle.getnames())
                compiler_mode = bundle.getmember(
                    f"{package_name}/tools/build-pwm-overlays.sh"
                ).mode

        required = {
            f"{package_name}/install.sh",
            f"{package_name}/robotd/bin/robotd",
            f"{package_name}/robotd/bin/robotctl",
            f"{package_name}/robotd/lib/libonnxruntime.so",
            f"{package_name}/robotd/systemd/robotd.service",
            f"{package_name}/tools/robotd_component.py",
            f"{package_name}/components.lock.yaml",
            f"{package_name}/tools/build-pwm-overlays.sh",
            f"{package_name}/device-tree/overlays/rk3568-pwm12-m1.dts",
            f"{package_name}/device-tree/overlays/rk3568-pwm13-m1.dts",
            f"{package_name}/overlay/usr/local/sbin/zelux-pwm-setupd",
            f"{package_name}/overlay/etc/systemd/system/zelux-pwm-setupd.service",
        }
        self.assertTrue(required <= names, f"offline archive is missing: {sorted(required - names)}")
        self.assertTrue(compiler_mode & 0o111, "packaged overlay builder must remain executable")


if __name__ == "__main__":
    unittest.main()
