#!/usr/bin/env python3
"""Exercise snapshot selection and failure recovery without signing or touching a device."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Signing"))
spec = importlib.util.spec_from_file_location("duodesk_pinned_renew", ROOT / "Signing/renew.py")
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)
import source_snapshot


class PinnedSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="duodesk-source-pin-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "source"
        self.local = Path(self.temp.name) / "local"
        self.local.mkdir()
        for name, content in {
            "Package.swift": "package",
            "iOSClient/Sill.xcodeproj/project.pbxproj": "project",
            "iOSClient/Feature.swift": "version-one",
            "Sources/StreamProtocol/Viewport.swift": "viewport",
            "Signing/Simulator.entitlements": "simulator entitlement",
            "LICENSE": "license",
            "NOTICE": "notice",
        }.items():
            file = self.root / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(content)
        self.config = {"team_id": "TESTTEAM01", "device_id": "00000000-0000000000000000",
                       "bundle_id": "com.example.duodesk", "configuration": "Release"}
        self.clock = dt.datetime(2026, 11, 2, tzinfo=dt.timezone.utc)
        self.expiry = self.clock + dt.timedelta(days=7)
        self.build_sources = []
        self.install_fail = False
        self.commands = []

    def profile(self, _):
        return {"Entitlements": {"application-identifier": self.config["team_id"] + "." + self.config["bundle_id"]},
                "TeamIdentifier": [self.config["team_id"]], "ProvisionedDevices": [self.config["device_id"]],
                "ExpirationDate": self.expiry}

    def command(self, args, **kwargs):
        self.commands.append(args)
        if args[0] == "/usr/bin/xcodebuild":
            project = Path(args[args.index("-project") + 1])
            source = project.parent.parent
            self.build_sources.append((source / "iOSClient/Feature.swift").read_text())
            build = Path(args[args.index("-derivedDataPath") + 1])
            app = build / "Build/Products/Release-iphoneos/Sill.app"
            app.mkdir(parents=True, exist_ok=True)
            import plistlib
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"]}))
        elif args[0] == "/usr/bin/xcrun" and self.install_fail:
            raise subprocess.CalledProcessError(1, args)
        return types.SimpleNamespace(returncode=0)

    def run_tool(self, force=False, renew_now=False):
        with patch.object(renew, "ROOT", self.root), patch.object(renew, "LOCAL", self.local), \
             patch.object(renew, "now", side_effect=lambda: self.clock), \
             patch.object(renew, "read_profile", side_effect=self.profile), \
             patch.object(renew.subprocess, "run", side_effect=self.command):
            return renew.run(self.config, force=force, renew_now=renew_now)

    def test_automatic_renewal_builds_installed_snapshot_not_live_edits(self):
        first = self.run_tool(force=True)
        (self.root / "iOSClient/Feature.swift").write_text("unverified-version-two")
        self.clock += dt.timedelta(days=6)
        self.expiry = self.clock + dt.timedelta(days=7)
        second = self.run_tool()
        self.assertEqual(self.build_sources, ["version-one", "version-one"])
        self.assertEqual(first["source_id"], second["source_id"])
        updated = self.run_tool(force=True)
        self.assertEqual(self.build_sources[-1], "unverified-version-two")
        self.assertNotEqual(updated["source_id"], first["source_id"])

    def test_daily_attempt_keeps_the_installed_snapshot_before_expiry_threshold(self):
        first = self.run_tool(force=True)
        (self.root / "iOSClient/Feature.swift").write_text("unverified-version-two")
        self.clock += dt.timedelta(hours=24)
        self.expiry += dt.timedelta(hours=24)
        daily = self.run_tool(renew_now=True)
        self.assertEqual(self.build_sources, ["version-one", "version-one"])
        self.assertEqual(daily["source_id"], first["source_id"])

    def test_failed_install_leaves_pending_source_for_retry(self):
        first = self.run_tool(force=True)
        (self.root / "iOSClient/Feature.swift").write_text("version-two")
        self.install_fail = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_tool(force=True)
        pending = json.loads((self.local / "signing-pending.json").read_text())
        self.assertNotEqual(pending["source_id"], first["source_id"])
        self.assertEqual(json.loads((self.local / "signing-status.json").read_text())["source_id"], first["source_id"])
        self.install_fail = False
        self.expiry += dt.timedelta(days=1)
        retried = self.run_tool()
        self.assertEqual(self.build_sources[-1], "version-two")
        self.assertEqual(retried["source_id"], pending["source_id"])
        self.assertFalse((self.local / "signing-pending.json").exists())

    def test_monitor_recovers_pending_manual_version_not_later_worktree_edits(self):
        first = self.run_tool(force=True)
        binding = renew.config_binding(self.config)
        (self.local / "signing-monitor.json").write_text(json.dumps({
            "binding": binding, "connected": True, "transport": "wired",
            "last_attempt_at": self.clock.isoformat(), "last_result": "installed", "last_trigger": "daily"}))
        (self.root / "iOSClient/Feature.swift").write_text("version-two")
        self.install_fail = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_tool(force=True)
        pending = json.loads((self.local / "signing-pending.json").read_text())
        self.assertNotEqual(pending["source_id"], first["source_id"])
        (self.root / "iOSClient/Feature.swift").write_text("unverified-version-three")
        self.clock += dt.timedelta(minutes=1)
        self.expiry += dt.timedelta(days=1)
        self.install_fail = False
        with patch.object(renew, "ROOT", self.root), patch.object(renew, "LOCAL", self.local), \
             patch.object(renew, "now", side_effect=lambda: self.clock), \
             patch.object(renew, "probe_device", return_value={"connected": True, "transport": "wired"}), \
             patch.object(renew, "read_profile", side_effect=self.profile), \
             patch.object(renew.subprocess, "run", side_effect=self.command):
            recovered = renew.monitor(self.config)
        self.assertEqual(recovered["status"], "installed")
        self.assertEqual(recovered["source_id"], pending["source_id"])
        self.assertEqual(self.build_sources[-1], "version-two")
        self.assertFalse((self.local / "signing-pending.json").exists())

    def test_changed_snapshot_is_rejected_before_build_or_install(self):
        installed = self.run_tool(force=True)
        pinned = self.local / "signing-sources" / installed["source_id"] / "source/iOSClient/Feature.swift"
        pinned.write_text("tampered")
        self.clock += dt.timedelta(days=6)
        self.commands.clear()
        with self.assertRaisesRegex(ValueError, "changed or is incomplete"):
            self.run_tool()
        self.assertEqual(self.commands, [])

    def test_snapshot_changed_during_build_is_never_installed(self):
        command = self.command

        def change_during_build(args, **kwargs):
            result = command(args, **kwargs)
            if args[0] == "/usr/bin/xcodebuild":
                project = Path(args[args.index("-project") + 1])
                (project.parent / "Feature.swift").write_text("changed during build")
            return result

        with patch.object(renew, "ROOT", self.root), patch.object(renew, "LOCAL", self.local), \
             patch.object(renew, "now", side_effect=lambda: self.clock), \
             patch.object(renew, "read_profile", side_effect=self.profile), \
             patch.object(renew.subprocess, "run", side_effect=change_during_build):
            with self.assertRaisesRegex(ValueError, "changed or is incomplete"):
                renew.run(self.config, force=True)
        self.assertFalse(any(args[0] == "/usr/bin/xcrun" for args in self.commands))
        self.assertFalse((self.local / "signing-status.json").exists())

    def test_legacy_due_without_verified_source_fails_closed(self):
        first = self.run_tool(force=True)
        state_path = self.local / "signing-status.json"
        legacy = dict(first)
        legacy.pop("source_id")
        state_path.write_text(json.dumps(legacy))
        self.clock += dt.timedelta(days=6)
        self.commands.clear()
        with self.assertRaisesRegex(RuntimeError, "no verified source snapshot"):
            self.run_tool()
        self.assertEqual(self.commands, [])

    def test_pending_other_device_is_never_installed(self):
        first = self.run_tool(force=True)
        (self.local / "signing-pending.json").write_text(json.dumps({"binding": "other", "source_id": first["source_id"]}))
        self.commands.clear()
        with self.assertRaisesRegex(ValueError, "different signing configuration"):
            self.run_tool()
        self.assertEqual(self.commands, [])

    def test_snapshot_excludes_secrets_and_refuses_external_symlink(self):
        (self.root / "iOSClient/private.key").write_text("not for snapshot")
        (self.root / "Package.resolved").write_text("pinned dependency revisions")
        source_id, source = source_snapshot.capture_snapshot(self.root, self.local)
        self.assertFalse((source / "iOSClient/private.key").exists())
        self.assertEqual((source / "Package.resolved").read_text(), "pinned dependency revisions")
        self.assertEqual(source_snapshot.validate_snapshot(self.local, source_id), source)
        outside = Path(self.temp.name) / "outside.swift"
        outside.write_text("outside")
        (self.root / "iOSClient/escape.swift").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "outside"):
            source_snapshot.capture_snapshot(self.root, self.local)


if __name__ == "__main__":
    unittest.main(verbosity=2)
