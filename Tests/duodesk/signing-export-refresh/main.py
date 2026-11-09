#!/usr/bin/env python3
"""Simulate a stale Xcode-managed profile and an exported replacement, without signing."""
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("duodesk_renew_export", root / "Signing/renew.py")
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)
import device_install


class ExportRefresh(unittest.TestCase):
    def setUp(self):
        # These suites isolate signing/snapshot behavior; device-version checks have their own
        # simulated two-Mac regression tests in signing-device-version.
        for stub in (patch.object(renew, "installed_version", return_value=None),
                     patch.object(renew, "capture_snapshot", return_value=("a" * 64, Path("/tmp/duodesk-approved-source"))),
                     patch.object(renew, "project_version", return_value=("0.1.0", "1")),
                     patch.object(device_install, "installed_version", return_value=("0.1.0", "1")),
                     patch.object(device_install, "project_version", return_value=("0.1.0", "1"))):
            stub.start()
            self.addCleanup(stub.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.local = Path(self.temp.name)
        self.config = {"team_id": "TESTTEAM01", "device_id": "00000000-0000000000000000",
                       "bundle_id": "com.example.duodesk", "renew_before_hours": 48}
        self.current = dt.datetime(2026, 10, 29, tzinfo=dt.timezone.utc)
        self.old_expiry = self.current + dt.timedelta(hours=24)
        self.new_expiry = self.current + dt.timedelta(days=7)
        self.cached = self.local / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
        self.cached.mkdir(parents=True)
        (self.cached / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"], "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}))
        binding = hashlib.sha256(json.dumps({k: self.config[k] for k in ("team_id", "device_id", "bundle_id")},
                                            sort_keys=True).encode()).hexdigest()
        self.state = {"status": "installed", "binding": binding, "checked_at": self.current.isoformat(),
                      "expires_at": self.old_expiry.isoformat(), "source_id": "a" * 64}
        (self.local / "signing-status.json").write_text(json.dumps(self.state))
        self.calls = []
        self.export_expiry = self.new_expiry
        self.export_failure = False
        self.export_wrong_device = False
        self.export_count = 1
        self.install_failure = False

    def profile(self, app):
        expiry = self.export_expiry if "Payload" in app.parts else self.old_expiry
        devices = ["another-device"] if "Payload" in app.parts and self.export_wrong_device else [self.config["device_id"]]
        return {"Entitlements": {"application-identifier": self.config["team_id"] + "." + self.config["bundle_id"]},
                "TeamIdentifier": [self.config["team_id"]], "ProvisionedDevices": devices,
                "ExpirationDate": expiry}

    def command(self, args, **kwargs):
        self.calls.append(args)
        if args[0] == "/usr/bin/xcodebuild" and "-exportArchive" in args:
            if self.export_failure:
                raise subprocess.CalledProcessError(1, args)
            options = plistlib.loads(Path(args[args.index("-exportOptionsPlist") + 1]).read_bytes())
            self.assertEqual(options, {"method": "debugging", "destination": "export", "signingStyle": "automatic",
                                       "teamID": self.config["team_id"]})
            export = Path(args[args.index("-exportPath") + 1])
            export.mkdir(parents=True, exist_ok=True)
            for index in range(self.export_count):
                (export / f"Duo-{index}.ipa").write_bytes(b"test placeholder, not a real IPA")
        elif args[0] == "/usr/bin/ditto":
            app = Path(args[-1]) / "Payload/Sill.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"], "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}))
        elif args[0] == "/usr/bin/xcrun" and self.install_failure:
            raise subprocess.CalledProcessError(1, args)
        return subprocess.CompletedProcess(args, 0)

    def run_renewal(self):
        with patch.object(renew, "LOCAL", self.local), patch.object(renew, "now", return_value=self.current), \
             patch.object(renew, "validate_snapshot", return_value=Path("/tmp/duodesk-approved-source")), \
             patch.object(renew, "profile_cache_directories", return_value=[]), \
             patch.object(renew, "build_dir_for_source", return_value=self.local / "SignedBuild"), \
             patch.object(renew, "read_profile", side_effect=self.profile), patch.object(renew.subprocess, "run", side_effect=self.command):
            return renew.run(self.config)

    def test_exported_new_profile_installs_only_after_verification(self):
        result = self.run_renewal()
        self.assertEqual(result["expires_at"], self.new_expiry.isoformat())
        commands = [args[0] for args in self.calls]
        self.assertEqual(commands.count("/usr/bin/xcodebuild"), 3)  # build, archive, export
        self.assertIn("/usr/bin/ditto", commands)
        self.assertLess(commands.index("/usr/bin/codesign"), commands.index("/usr/bin/xcrun"))
        installed = next(args for args in self.calls if args[0] == "/usr/bin/xcrun")
        self.assertIn("Payload", Path(installed[-1]).parts)
        self.assertEqual(json.loads((self.local / "signing-status.json").read_text())["expires_at"], self.new_expiry.isoformat())
        self.assertFalse(any(p.name.startswith("duodesk-renew-export-") for p in self.local.iterdir()))

    def test_export_reusing_stale_profile_does_not_install(self):
        self.export_expiry = self.old_expiry
        with self.assertRaisesRegex(RuntimeError, "fresh profile"):
            self.run_renewal()
        self.assertFalse(any(args[0] == "/usr/bin/xcrun" for args in self.calls))
        self.assertEqual(json.loads((self.local / "signing-status.json").read_text()), self.state)

    def test_export_failure_preserves_installed_record(self):
        self.export_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_renewal()
        self.assertFalse(any(args[0] == "/usr/bin/xcrun" for args in self.calls))
        self.assertEqual(json.loads((self.local / "signing-status.json").read_text()), self.state)
        self.assertFalse((self.local / "signing-pending.json").exists())

    def test_export_for_another_device_never_installs(self):
        self.export_wrong_device = True
        with self.assertRaisesRegex(ValueError, "configured Duo"):
            self.run_renewal()
        self.assertFalse(any(args[0] == "/usr/bin/xcrun" for args in self.calls))
        self.assertEqual(json.loads((self.local / "signing-status.json").read_text()), self.state)

    def test_ambiguous_export_never_installs(self):
        self.export_count = 2
        with self.assertRaisesRegex(ValueError, "exactly one device app"):
            self.run_renewal()
        self.assertFalse(any(args[0] == "/usr/bin/xcrun" for args in self.calls))
        self.assertEqual(json.loads((self.local / "signing-status.json").read_text()), self.state)

    def test_failed_export_install_keeps_successful_record(self):
        self.install_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_renewal()
        self.assertEqual(json.loads((self.local / "signing-status.json").read_text()), self.state)
        self.assertEqual(json.loads((self.local / "signing-pending.json").read_text())["source_id"], self.state["source_id"])
        self.assertFalse(any(p.name.startswith("duodesk-renew-export-") for p in self.local.iterdir()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
