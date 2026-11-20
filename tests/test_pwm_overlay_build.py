"""Exercise the overlay build/install/manifest pipeline without a host dtc."""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GIT_BASH = Path(r"C:\Program Files\Git\bin\bash.exe")
BASH = shutil.which("bash") or (str(GIT_BASH) if GIT_BASH.is_file() else None)
REAL_DTC = shutil.which("dtc")


@unittest.skipUnless(BASH, "bash is required to exercise the overlay build script")
class PwmOverlayBuildTests(unittest.TestCase):
    @unittest.skipUnless(REAL_DTC, "real dtc compiler is not installed")
    def test_trusted_overlay_sources_compile_with_real_dtc(self) -> None:
        with tempfile.TemporaryDirectory(prefix="zelux-pwm-dtc-") as tmp:
            for overlay in ("rk3568-pwm12-m1", "rk3568-pwm13-m1"):
                source = ROOT / "device-tree/overlays" / f"{overlay}.dts"
                output = Path(tmp) / f"{overlay}.dtbo"
                subprocess.run(
                    [REAL_DTC, "-@", "-q", "-I", "dts", "-O", "dtb", "-o",
                     str(output), str(source)],
                    check=True,
                    capture_output=True,
                )
                self.assertGreater(output.stat().st_size, 0)

    @unittest.skipUnless(BASH and REAL_DTC, "bash and real dtc are required")
    def test_build_script_with_real_dtc_emits_matching_manifest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="zelux-pwm-real-build-") as tmp:
            root = Path(tmp)
            boot_root, rootfs_root = root / "boot", root / "rootfs"
            subprocess.run(
                [BASH, str(ROOT / "tools/build-pwm-overlays.sh"), str(boot_root),
                 str(rootfs_root), str(ROOT / "device-tree/overlays")],
                check=True,
                capture_output=True,
            )
            manifest = rootfs_root / "usr/share/zelux/pwm-overlays.sha256"
            rows = [line.split() for line in manifest.read_text(encoding="ascii").splitlines()]
            self.assertEqual([row[1] for row in rows],
                             ["rk3568-pwm12-m1.dtbo", "rk3568-pwm13-m1.dtbo"])
            for digest, filename in rows:
                artifact = boot_root / "overlay-user" / filename
                self.assertGreater(artifact.stat().st_size, 0)
                self.assertEqual(digest, hashlib.sha256(artifact.read_bytes()).hexdigest())

    def test_build_script_installs_two_artifacts_and_matching_manifest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="zelux-pwm-build-") as tmp:
            root = Path(tmp)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_dtc = fake_bin / "dtc"
            fake_dtc.write_text(
                "#!/bin/sh\n"
                "set -eu\n"
                "out=''\n"
                "input=''\n"
                "while [ $# -gt 0 ]; do\n"
                "  if [ \"$1\" = '-o' ]; then out=$2; shift 2; else input=$1; shift; fi\n"
                "done\n"
                "cp \"$input\" \"$out\"\n",
                encoding="utf-8",
                newline="\n",
            )
            fake_dtc.chmod(0o755)
            boot_root = root / "boot"
            rootfs_root = root / "rootfs"
            env = os.environ.copy()
            env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
            subprocess.run(
                [BASH, str(ROOT / "tools/build-pwm-overlays.sh"), str(boot_root),
                 str(rootfs_root), str(ROOT / "device-tree/overlays")],
                check=True,
                capture_output=True,
                env=env,
            )

            overlay_dir = boot_root / "overlay-user"
            manifest = rootfs_root / "usr/share/zelux/pwm-overlays.sha256"
            rows = [line.split() for line in manifest.read_text(encoding="ascii").splitlines()]
            self.assertEqual([row[1] for row in rows],
                             ["rk3568-pwm12-m1.dtbo", "rk3568-pwm13-m1.dtbo"])
            for digest, filename in rows:
                artifact = overlay_dir / filename
                self.assertEqual(digest, hashlib.sha256(artifact.read_bytes()).hexdigest())
                self.assertTrue(artifact.stat().st_mode & 0o444)


if __name__ == "__main__":
    unittest.main()
