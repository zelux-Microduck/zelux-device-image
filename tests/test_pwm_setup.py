"""Unit tests for restricted Armbian PWM overlay editing (no device access)."""
import importlib.machinery
import importlib.util
import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "overlay/usr/local/sbin/zelux-pwm-setupd"
loader = importlib.machinery.SourceFileLoader("zelux_pwm_setupd", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
setupd = importlib.util.module_from_spec(spec)
loader.exec_module(setupd)


class PwmSetupTests(unittest.TestCase):
    def test_setup_unit_keeps_boot_writable_without_unprotecting_system_directories(self):
        unit = (SCRIPT.parents[3] / "etc/systemd/system/zelux-pwm-setupd.service").read_text("utf-8")
        settings = dict(line.split("=", 1) for line in unit.splitlines()
                        if "=" in line and not line.lstrip().startswith("#"))
        self.assertEqual(settings["ProtectSystem"], "no")
        self.assertEqual(set(settings["ReadOnlyPaths"].split()), {"/usr", "/etc", "-/efi"})
        self.assertIn("/boot", settings["ReadWritePaths"].split())
        self.assertEqual(settings["ProtectHome"], "yes")
        self.assertEqual(settings["NoNewPrivileges"], "yes")
        self.assertNotIn("CAP_SYS_ADMIN", settings["CapabilityBoundingSet"])

    def test_board_identity_variants_and_rejections(self):
        for model, compatible, expected in [
            ("Radxa ZERO 3", ["radxa,zero3", "rockchip,rk3566"], True),
            ("Radxa ZERO 3", ["radxa,zero3-aic8800ds2", "rockchip,rk3566"], True),
            ("Radxa ZERO 3W", ["radxa,zero-3w", "rockchip,rk3566"], True),
            ("Radxa ZERO3W", [], True),
            ("Radxa ZERO 3E", ["radxa,zero3", "rockchip,rk3566"], False),
            ("Radxa ZERO 3W", ["radxa,zero-3e", "rockchip,rk3566"], False),
            ("Radxa ZERO 3W", ["unknown,board", "rockchip,rk3566"], False),
            ("Radxa ZERO 3", ["rockchip,rk3566"], False),
            ("Radxa ZERO 3", [], False), ("", [], False),
        ]:
            with self.subTest(model=model, compatible=compatible):
                self.assertEqual(setupd.is_zero3w(model, compatible), expected)

    def test_legacy_armbian_board_reaches_pin_selection(self):
        self.manager._profile_error = setupd.SetupManager._profile_error.__get__(self.manager)
        self.manager._runtime_and_status = setupd.SetupManager._runtime_and_status.__get__(self.manager)
        self.manager.model_file.write_bytes(b"Radxa ZERO 3\0")
        self.manager.tree_root.mkdir()
        (self.manager.tree_root / "compatible").write_bytes(b"radxa,zero3-aic8800ds2\0rockchip,rk3566\0")
        self.manager.armbian_release.write_text("ID=armbian\n")
        (self.boot / "boot.cmd").write_text("overlay_error user_overlays overlay-user")
        self.manager._tree_mapping = lambda _: {"compatible": True, "ready": False}
        state = self.manager.status()
        self.assertEqual(state["state"], "overlay_required", state)
        self.assertEqual(len(state["mapped_pins"]), 2)
        self.assertIn("radxa,zero3-aic8800ds2", state["compatible"])
        (self.manager.tree_root / "compatible").unlink()
        rejected = self.manager.status()
        self.assertEqual(rejected["state"], "unsupported")
        self.assertIn("Radxa ZERO 3", rejected["reason"])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.boot = root / "boot"
        self.boot.mkdir()
        self.env = self.boot / "armbianEnv.txt"
        self.env.write_text("verbosity=1\nuser_overlays=existing # keep me\n", encoding="utf-8")
        self.manager = setupd.SetupManager(
            boot_env=self.env, overlay_dir=root / "overlay-user",
            manifest=root / "overlays.sha256", state_dir=root / "state",
            model_file=root / "model", symbols_root=root / "symbols",
            tree_root=root / "tree", pwm_root=root / "sys-pwm",
            kernel_release="6.1.115-vendor-rk35xx", armbian_release=root / "armbian-release")
        self.manager._runtime_and_status = lambda: {"state": "overlay_required", "mapped_pins": [
            {"id": pin_id, "state": "overlay_required", "overlay_id": overlay_id}
            for pin_id, (_, _, _, _, overlay_id) in setupd.PIN_OVERLAYS.items()]}
        self.manager._profile_error = lambda: ""
        self.manager._overlay_available = lambda _overlay: True

    def tearDown(self):
        self.tmp.cleanup()

    def test_preview_confirm_apply_backup_and_rollback(self):
        pin_id = "radxa-zero3w-pin24-pwm13-m1"
        preview = self.manager.preview(pin_id)
        self.assertIn("rk3568-pwm13-m1", preview["diff"])
        self.assertIn("keep me", preview["diff"])
        result = self.manager.apply(pin_id, preview["token"], True)
        self.assertEqual(result["state"], "reboot_required")
        self.assertIn("rk3568-pwm13-m1", self.env.read_text(encoding="utf-8"))
        self.assertEqual(len(list((Path(self.tmp.name) / "state").glob("*.bak"))), 1)
        self.assertTrue(self.manager.rollback(pin_id, True)["reboot_required"])
        self.assertNotIn("rk3568-pwm13-m1", self.env.read_text(encoding="utf-8"))

    def test_apply_requires_confirmation_token_and_allowlisted_pin(self):
        pin_id = "radxa-zero3w-pin21-pwm12-m1"
        preview = self.manager.preview(pin_id)
        with self.assertRaises(setupd.SetupError):
            self.manager.apply(pin_id, preview["token"], False)
        with self.assertRaises(setupd.SetupError):
            self.manager.preview("../../armbianEnv.txt")

    def test_apply_rejects_boot_config_changed_after_preview(self):
        pin_id = "radxa-zero3w-pin24-pwm13-m1"
        preview = self.manager.preview(pin_id)
        self.env.write_text("verbosity=2\nuser_overlays=existing # user edit\n", encoding="utf-8")
        with self.assertRaisesRegex(setupd.SetupError, "发生变化"):
            self.manager.apply(pin_id, preview["token"], True)

    def test_duplicate_user_overlays_lines_fail_closed(self):
        self.env.write_text("user_overlays=a\nuser_overlays=b\n", encoding="utf-8")
        with self.assertRaises(setupd.SetupError):
            self.manager.preview("radxa-zero3w-pin24-pwm13-m1")

    def test_overlay_manifest_digest_must_match_non_symlink_artifact(self):
        # setUp stubs availability for boot-config workflow tests; exercise the
        # real manifest/hash implementation in this security regression test.
        self.manager._overlay_available = setupd.SetupManager._overlay_available.__get__(self.manager)
        overlay_id = "rk3568-pwm13-m1"
        self.manager.overlay_dir.mkdir()
        artifact = self.manager.overlay_dir / (overlay_id + ".dtbo")
        artifact.write_bytes(b"trusted binary")
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        self.manager.manifest.write_text(f"{digest}  {overlay_id}.dtbo\n", encoding="ascii")
        self.assertTrue(self.manager._overlay_available(overlay_id))
        artifact.write_bytes(b"modified binary")
        self.assertFalse(self.manager._overlay_available(overlay_id))
        # Simulate a symlink without requiring Windows Developer Mode/admin
        # privileges; the implementation must reject symlink artifacts too.
        artifact.write_bytes(b"trusted binary")
        with patch.object(setupd.Path, "is_symlink", return_value=True):
            self.assertFalse(self.manager._overlay_available(overlay_id))

    def test_profile_rejects_extlinux_overlay_loader_and_unknown_boot_script(self):
        self.manager._profile_error = setupd.SetupManager._profile_error.__get__(self.manager)
        self.manager.model_file.write_bytes(b"Radxa ZERO 3W\0")
        self.manager.armbian_release.write_text("ID=armbian\n", encoding="utf-8")
        (self.boot / "boot.cmd").write_text("overlay_error user_overlays overlay-user", encoding="utf-8")
        self.assertEqual(self.manager._profile_error(), "")
        extlinux = self.boot / "extlinux"
        extlinux.mkdir()
        (extlinux / "extlinux.conf").write_text("LABEL Armbian\n fdtoverlays /boot/custom.dtbo\n", encoding="utf-8")
        self.assertIn("extlinux fdtoverlays", self.manager._profile_error())
        (extlinux / "extlinux.conf").unlink()
        (self.boot / "boot.cmd").write_text("overlay_error", encoding="utf-8")
        self.assertIn("user_overlays/overlay-user", self.manager._profile_error())

    def test_live_pinmux_and_registered_controller_are_ready_without_export(self):
        root = Path(self.tmp.name)
        controller = root / "tree" / "pwm13"
        group = root / "tree" / "pinctrl" / "pwm13m1_pins"
        (root / "symbols").mkdir()
        controller.mkdir(parents=True)
        group.mkdir(parents=True)
        (root / "symbols/pwm13").write_bytes(b"/pwm13\0")
        (root / "symbols/pwm13m1_pins").write_bytes(b"/pinctrl/pwm13m1_pins\0")
        (controller / "status").write_bytes(b"okay\0")
        (controller / "pinctrl-names").write_bytes(b"active\0")
        phandle = b"\0\0\0\x31"
        (controller / "pinctrl-0").write_bytes(phandle)
        (group / "phandle").write_bytes(phandle)
        chip = root / "sys-pwm/pwmchip4"
        (chip / "device/of_node").mkdir(parents=True)
        (chip / "npwm").write_text("1")
        with patch.object(setupd.Path, "resolve", return_value=controller):
            result = self.manager._tree_mapping("radxa-zero3w-pin24-pwm13-m1")
        self.assertTrue(result["pinctrl_active"])
        self.assertTrue(result["ready"])
        self.assertFalse(result["controller"]["exported"])

    def test_rebooted_but_inactive_overlay_is_validation_failed(self):
        self.manager._runtime_and_status = setupd.SetupManager._runtime_and_status.__get__(self.manager)
        pin_id = "radxa-zero3w-pin24-pwm13-m1"
        self.env.write_text("user_overlays=rk3568-pwm13-m1\n", encoding="utf-8")
        self.manager.state_dir.mkdir(parents=True, exist_ok=True)
        (self.manager.state_dir / "pending-reboot.json").write_text(
            '{"pin_id":"' + pin_id + '","boot_id":"previous-boot"}', encoding="utf-8")
        self.manager._boot_id = lambda: "current-boot"
        self.manager._tree_mapping = lambda _pin: {"compatible": True, "ready": False,
            "pinctrl_active": False, "controller": None, "reason": "inactive"}
        state = self.manager._runtime_and_status()
        pin = next(item for item in state["mapped_pins"] if item["id"] == pin_id)
        self.assertEqual(pin["state"], "validation_failed", state)
        self.assertFalse(pin["ready"])
        self.assertEqual(state["state"], "validation_failed")

    def test_rollback_is_pending_until_reboot_then_verified(self):
        self.manager._runtime_and_status = setupd.SetupManager._runtime_and_status.__get__(self.manager)
        pin_id = "radxa-zero3w-pin24-pwm13-m1"
        self.env.write_text("user_overlays=existing rk3568-pwm13-m1 # keep\n", encoding="utf-8")
        self.manager._boot_id = lambda: "boot-before"
        self.manager._tree_mapping = lambda _pin: {"compatible": True, "ready": False,
            "pinctrl_active": False, "controller": None, "reason": "inactive"}
        result = self.manager.rollback(pin_id, True)
        self.assertTrue(result["reboot_required"])
        before = self.manager._runtime_and_status()
        self.assertEqual(next(p for p in before["mapped_pins"] if p["id"] == pin_id)["state"],
                         "rollback_reboot_required")
        self.manager._boot_id = lambda: "boot-after"
        after = self.manager._runtime_and_status()
        self.assertEqual(next(p for p in after["mapped_pins"] if p["id"] == pin_id)["state"],
                         "overlay_required")
        self.assertFalse((self.manager.state_dir / "pending-reboot.json").exists())

    def test_rollback_refuses_to_disable_active_runtime_pinmux(self):
        pin_id = "radxa-zero3w-pin24-pwm13-m1"
        self.manager._tree_mapping = lambda _pin: {"ready": True, "pinctrl_active": True}
        with self.assertRaisesRegex(setupd.SetupError, "不能在线回滚"):
            self.manager.rollback(pin_id, True)


if __name__ == "__main__":
    unittest.main()
