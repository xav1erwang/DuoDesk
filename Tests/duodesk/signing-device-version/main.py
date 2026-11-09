#!/usr/bin/env python3
"""Reproduce an old Mac's renewal against a newer phone without installing or signing anything."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Signing"))
import device_install as install
spec = importlib.util.spec_from_file_location("version_test_renew", ROOT / "Signing/renew.py")
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)


class DeviceVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.local = self.root / "Local"
        self.local.mkdir()
        self.config = {"team_id": "TESTTEAM01", "device_id": "00000000-0000000000000000", "bundle_id": "com.example.duodesk"}
        self.clock = dt.datetime(2026, 11, 9, tzinfo=dt.timezone.utc)
        self.phone = ("0.1.0", "22")
        self.calls = []
        self.stale_after_install = False
        self.malformed_reply = False
        self.old_state = {"status": "installed", "binding": renew.config_binding(self.config),
                          "source_id": "a" * 64, "checked_at": self.clock.isoformat(),
                          "expires_at": (self.clock + dt.timedelta(days=2)).isoformat()}
        (self.local / "signing-status.json").write_text(json.dumps(self.old_state))
        self.project("9")
        for stub in (patch.object(renew, "ROOT", self.root), patch.object(renew, "LOCAL", self.local),
                     patch.object(renew, "now", return_value=self.clock),
                     patch.object(renew.subprocess, "run", side_effect=self.command)):
            stub.start()
            self.addCleanup(stub.stop)

    def project(self, build):
        project = self.root / "iOSClient/Sill.xcodeproj/project.pbxproj"
        project.parent.mkdir(parents=True, exist_ok=True)
        project.write_text("MARKETING_VERSION = 0.1.0;\nCURRENT_PROJECT_VERSION = " + build + ";\n")

    def app(self, build):
        app = self.root / ("Build-" + build) / "Sill.app"
        app.mkdir(parents=True, exist_ok=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"],
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": build}))
        return app

    def command(self, args, **kwargs):
        self.calls.append(args)
        if args[0] == "/usr/bin/xcrun" and args[1:5] == ["devicectl", "device", "info", "apps"]:
            if self.malformed_reply:
                reply = {"result": {}}
            else:
                apps = [] if self.phone is None else [{"bundleIdentifier": self.config["bundle_id"],
                    "version": self.phone[0], "bundleVersion": self.phone[1]}]
                reply = {"result": {"apps": apps}}
            Path(args[args.index("--json-output") + 1]).write_text(json.dumps(reply))
        elif args[0] == "/usr/bin/xcrun" and args[1:5] == ["devicectl", "device", "install", "app"]:
            if not self.stale_after_install:
                self.phone = install.app_version(plistlib.loads((Path(args[-1]) / "Info.plist").read_bytes()))
        return subprocess.CompletedProcess(args, 0)

    def installs(self):
        return [a for a in self.calls if a[1:5] == ["devicectl", "device", "install", "app"]]

    def test_old_air_renewal_stops_before_building_or_installing(self):
        # Same failure as 2026-11-09: local record/source is 9, phone was updated to 22 by Pro.
        with patch.object(renew, "validate_snapshot", return_value=self.root), \
             patch.object(renew, "probe_device", return_value={"connected": True, "transport": "localNetwork"}):
            result = renew.monitor(self.config, requested=True)
        self.assertEqual(result["status"], "newer_version_installed")
        self.assertEqual(self.installs(), [])
        self.assertFalse(any(a[0] == "/usr/bin/xcodebuild" for a in self.calls))
        self.assertEqual(install.project_version(self.root), ("0.1.0", "9"))
        self.assertEqual(json.loads((self.local / "signing-status.json").read_text()), self.old_state)
        self.assertEqual(json.loads((self.local / "signing-monitor.json").read_text())["last_result"], "superseded")

    def test_force_cannot_relabel_an_old_checkout_as_a_newer_build(self):
        with self.assertRaises(install.StaleDeviceBuild):
            renew.run(self.config, force=True)
        self.assertEqual(install.project_version(self.root)[1], "9")
        self.assertEqual(self.installs(), [])

    def test_installation_rechecks_phone_after_a_build(self):
        # A phone updated by the other Mac while this build ran is still protected at install time.
        with self.assertRaises(install.StaleDeviceBuild):
            install.install_and_verify(self.app("21"), self.config, self.local / "build.log")
        self.assertEqual(self.installs(), [])

    def test_command_success_with_stale_device_metadata_is_not_recorded_as_installed(self):
        self.stale_after_install = True
        with self.assertRaisesRegex(RuntimeError, "expected app version"):
            renew.install_verified_app(self.app("23"), self.config, self.clock + dt.timedelta(days=7),
                                      self.clock + dt.timedelta(days=2), True, renew.config_binding(self.config),
                                      self.local / "build.log", "b" * 64)
        self.assertEqual(len(self.installs()), 1)
        self.assertEqual(json.loads((self.local / "signing-status.json").read_text()), self.old_state)
        self.assertEqual(json.loads((self.local / "signing-pending.json").read_text())["source_id"], "b" * 64)

    def test_same_version_renewal_preserves_build_and_verifies_the_device(self):
        result = renew.install_verified_app(self.app("22"), self.config, self.clock + dt.timedelta(days=7),
                                            self.clock + dt.timedelta(days=2), False, renew.config_binding(self.config),
                                            self.local / "build.log", "b" * 64)
        self.assertEqual((result["version"], result["build"]), self.phone)
        self.assertEqual(len(self.installs()), 1)
        self.assertFalse((self.local / "signing-pending.json").exists())

    def test_first_install_does_not_require_an_existing_app(self):
        self.phone = None
        result = install.install_and_verify(self.app("1"), self.config, self.local / "build.log")
        self.assertEqual(result, ("0.1.0", "1"))
        self.assertEqual(self.phone, result)

    def test_unreadable_device_version_is_not_treated_as_no_app(self):
        self.malformed_reply = True
        with self.assertRaises(ValueError):
            install.install_and_verify(self.app("1"), self.config, self.local / "build.log")
        self.assertEqual(self.installs(), [])

    def test_numeric_versions_and_apple_prerelease_build_order(self):
        ordered = [("0.1.0", "9"), ("0.1.0", "10"), ("0.1.0", "22"), ("0.1.0", "23d1"),
                   ("0.1.0", "23a1"), ("0.1.0", "23b1"), ("0.1.0", "23fc1"), ("0.1.0", "23"),
                   ("0.2.0", "1"), ("0.10.0", "1"), ("1.0.0", "1")]
        self.assertEqual(sorted(ordered, key=install.version_key), ordered)
        self.assertEqual(install.version_key(("1.0", "1.2")), install.version_key(("1.0.0", "1.2.0")))

    def test_manual_build_number_advances_without_changing_the_release(self):
        for original, following in [("22", "23"), ("1.2.3", "1.2.4"), ("23b4", "23b5")]:
            with self.subTest(original=original):
                self.project(original)
                self.assertEqual(install.bump_project_build(self.root), following)
                self.assertEqual(install.project_version(self.root), ("0.1.0", following))


if __name__ == "__main__":
    unittest.main(verbosity=2)
