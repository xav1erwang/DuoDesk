#!/usr/bin/env python3
"""Exercise only temporary fake profile files; no real profile, account or device is touched."""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("duodesk_profile_cache", root / "Signing/renew.py")
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)


class ProfileCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.local = self.root / "local"
        self.local.mkdir()
        self.cache = self.root / "profiles"
        self.cache.mkdir()
        self.config = {"team_id": "TESTTEAM01", "device_id": "00000000-0000000000000000",
                       "bundle_id": "com.example.duodesk"}
        self.clock = dt.datetime(2026, 11, 2, tzinfo=dt.timezone.utc)
        self.target = self.cache / "target.mobileprovision"
        self.other = self.cache / "other.mobileprovision"
        self.wildcard = self.cache / "wildcard.mobileprovision"
        self.target.write_bytes(b"target-profile")
        self.other.write_bytes(b"other-app-profile")
        self.wildcard.write_bytes(b"wildcard-profile")
        self.valid = {"Entitlements": {"application-identifier": "TESTTEAM01.com.example.duodesk"},
                      "TeamIdentifier": ["TESTTEAM01"], "ProvisionedDevices": [self.config["device_id"]],
                      "ExpirationDate": (self.clock + dt.timedelta(days=4)).replace(tzinfo=None)}
        def decode(args, **kwargs):
            value = Path(args[-1]).read_bytes()
            profile = dict(self.valid)
            if value == b"other-app-profile":
                profile["Entitlements"] = {"application-identifier": "TESTTEAM01.com.example.other"}
            elif value == b"wildcard-profile":
                profile["Entitlements"] = {"application-identifier": "TESTTEAM01.*"}
            elif value != b"target-profile":
                raise subprocess.CalledProcessError(1, args)
            return plistlib.dumps(profile)
        for stub in (patch.object(renew, "LOCAL", self.local),
                     patch.object(renew, "now", return_value=self.clock),
                     patch.object(renew, "profile_cache_directories", return_value=[self.cache]),
                     patch.object(renew.subprocess, "check_output", side_effect=decode)):
            stub.start()
            self.addCleanup(stub.stop)

    def test_matching_profile_is_hidden_only_during_refresh(self):
        with renew.temporarily_hide_cached_profiles(self.config) as hidden:
            self.assertTrue(hidden)
            self.assertFalse(self.target.exists())
            self.assertEqual(self.other.read_bytes(), b"other-app-profile")
            self.assertEqual(self.wildcard.read_bytes(), b"wildcard-profile")
            self.assertTrue((self.local / "signing-profile-active.json").exists())
        self.assertEqual(self.target.read_bytes(), b"target-profile")
        self.assertFalse((self.local / "signing-profile-active.json").exists())
        self.assertEqual(len(list((self.local / "signing-profile-backups").glob("*/profile-0.backup"))), 1)

    def test_exception_restores_the_profile(self):
        with self.assertRaisesRegex(RuntimeError, "simulated Xcode failure"):
            with renew.temporarily_hide_cached_profiles(self.config):
                raise RuntimeError("simulated Xcode failure")
        self.assertEqual(self.target.read_bytes(), b"target-profile")
        self.assertFalse((self.local / "signing-profile-active.json").exists())

    def test_recovery_after_interruption_is_idempotent(self):
        transaction = renew.temporarily_hide_cached_profiles(self.config)
        self.assertTrue(transaction.__enter__())
        self.assertFalse(self.target.exists())
        renew.recover_profile_cache(self.config)
        renew.recover_profile_cache(self.config)
        self.assertEqual(self.target.read_bytes(), b"target-profile")
        transaction.__exit__(None, None, None)

    def test_new_file_at_original_path_is_not_overwritten(self):
        with renew.temporarily_hide_cached_profiles(self.config):
            self.target.write_bytes(b"new-file-from-xcode")
        self.assertEqual(self.target.read_bytes(), b"new-file-from-xcode")
        restored = list(self.cache.glob("target.duodesk-restored-*.mobileprovision"))
        self.assertEqual(len(restored), 1)
        self.assertEqual(restored[0].read_bytes(), b"target-profile")

    def test_racing_replacement_preserves_both_versions(self):
        rename = os.replace
        def race(source, destination):
            if Path(source).resolve() == self.target.resolve():
                self.target.write_bytes(b"replacement-from-another-process")
            return rename(source, destination)
        with patch.object(renew.os, "replace", side_effect=race):
            with self.assertRaisesRegex(RuntimeError, "changed during refresh"):
                with renew.temporarily_hide_cached_profiles(self.config):
                    self.fail("A changed profile must not be hidden for the build")
        self.assertEqual(self.target.read_bytes(), b"replacement-from-another-process")
        restored = list(self.cache.glob("target.duodesk-restored-*.mobileprovision"))
        self.assertEqual(len(restored), 1)
        self.assertEqual(restored[0].read_bytes(), b"target-profile")

    def test_recovery_refuses_a_destination_outside_profile_caches(self):
        transaction = "a" * 32
        directory = self.local / "signing-profile-backups" / transaction
        directory.mkdir(parents=True)
        (directory / "manifest.json").write_text(json.dumps({
            "binding": renew.config_binding(self.config),
            "profiles": [{"source": str(self.root / "outside.mobileprovision"), "sha256": "x", "mode": 0o600}]}))
        (self.local / "signing-profile-active.json").write_text(json.dumps({"transaction": transaction}))
        with self.assertRaisesRegex(ValueError, "unexpected destination"):
            renew.recover_profile_cache(self.config)
        self.assertFalse((self.root / "outside.mobileprovision").exists())

    def test_no_exact_profile_does_not_touch_other_apps(self):
        self.target.unlink()
        with renew.temporarily_hide_cached_profiles(self.config) as hidden:
            self.assertFalse(hidden)
        self.assertEqual(self.other.read_bytes(), b"other-app-profile")
        self.assertEqual(self.wildcard.read_bytes(), b"wildcard-profile")
        self.assertFalse((self.local / "signing-profile-active.json").exists())

    def test_newer_matching_profile_remains_available_for_the_clean_rebuild(self):
        fresh = self.cache / "fresh.mobileprovision"
        fresh.write_bytes(b"newer-profile")
        earlier_decode = renew.subprocess.check_output.side_effect
        expiry = self.clock + dt.timedelta(days=7)
        def decode(args, **kwargs):
            if Path(args[-1]) == fresh:
                return plistlib.dumps(dict(self.valid, ExpirationDate=expiry.replace(tzinfo=None)))
            return earlier_decode(args, **kwargs)
        with patch.object(renew.subprocess, "check_output", side_effect=decode):
            with renew.temporarily_hide_cached_profiles(self.config, keep_at_or_after=expiry) as hidden:
                self.assertTrue(hidden)
                self.assertFalse(self.target.exists())
                self.assertEqual(fresh.read_bytes(), b"newer-profile")
        self.assertEqual(self.target.read_bytes(), b"target-profile")
        self.assertEqual(fresh.read_bytes(), b"newer-profile")

    def exercise_renewal_after_stale_export(self, newer):
        app = self.local / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"]}))
        old_expiration = self.clock + dt.timedelta(days=4)
        (self.local / "signing-status.json").write_text(json.dumps({
            "status": "installed", "binding": renew.config_binding(self.config),
            "expires_at": old_expiration.isoformat(), "source_id": "a" * 64}))
        new_profile = dict(self.valid)
        if newer:
            new_profile["ExpirationDate"] = (self.clock + dt.timedelta(days=7)).replace(tzinfo=None)
        commands = []
        def command(args, **kwargs):
            commands.append(args)
            if args[0] == "/usr/bin/xcodebuild" and len([c for c in commands if c[0] == args[0]]) == 2:
                self.assertFalse(self.target.exists())
                self.assertTrue(self.other.exists())
                self.assertTrue(self.wildcard.exists())
                fresh_root = Path(args[args.index("-derivedDataPath") + 1])
                fresh_app = fresh_root / "Build/Products/Debug-iphoneos/Sill.app"
                fresh_app.mkdir(parents=True)
                (fresh_app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"]}))
            if args[0] in {"/usr/bin/codesign", "/usr/bin/xcrun"}:
                self.assertEqual(self.target.read_bytes(), b"target-profile")
            return types.SimpleNamespace(returncode=0)
        with patch.object(renew, "validate_snapshot", return_value=self.root), \
             patch.object(renew, "build_dir_for_source", return_value=self.local / "SignedBuild"), \
             patch.object(renew, "read_profile", side_effect=[self.valid, new_profile]), \
             patch.object(renew, "export_refreshed_app", return_value=app) as export, \
             patch.object(renew.subprocess, "run", side_effect=command):
            if newer:
                result = renew.run(self.config, renew_now=True)
                self.assertEqual(result["status"], "installed")
            else:
                with self.assertRaisesRegex(RuntimeError, "not extended"):
                    renew.run(self.config, renew_now=True)
            export.assert_not_called()
        self.assertEqual(self.target.read_bytes(), b"target-profile")
        self.assertEqual(sum(command[0] == "/usr/bin/xcrun" for command in commands), 1 if newer else 0)

    def test_stale_export_retries_only_the_matching_cache_then_installs_a_newer_profile(self):
        self.exercise_renewal_after_stale_export(newer=True)

    def test_refresh_that_still_reuses_the_old_profile_does_not_install(self):
        self.exercise_renewal_after_stale_export(newer=False)

    def test_invalid_incremental_signature_is_rebuilt_and_verified_before_install(self):
        app = self.local / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"]}))
        (self.local / "signing-status.json").write_text(json.dumps({
            "status": "installed", "binding": renew.config_binding(self.config),
            "expires_at": (self.clock + dt.timedelta(days=4)).isoformat(), "source_id": "a" * 64}))
        newer = dict(self.valid, ExpirationDate=(self.clock + dt.timedelta(days=7)).replace(tzinfo=None))
        commands = []
        def command(args, **kwargs):
            commands.append(args)
            if args[0] == "/usr/bin/codesign" and sum(c[0] == args[0] for c in commands) == 1:
                raise subprocess.CalledProcessError(1, args)
            if args[0] == "/usr/bin/xcodebuild" and sum(c[0] == args[0] for c in commands) == 2:
                self.assertFalse(self.target.exists())
                fresh_root = Path(args[args.index("-derivedDataPath") + 1])
                fresh_app = fresh_root / "Build/Products/Debug-iphoneos/Sill.app"
                fresh_app.mkdir(parents=True)
                (fresh_app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"]}))
            if args[0] == "/usr/bin/xcrun":
                self.assertEqual(self.target.read_bytes(), b"target-profile")
            return types.SimpleNamespace(returncode=0)
        with patch.object(renew, "validate_snapshot", return_value=self.root), \
             patch.object(renew, "build_dir_for_source", return_value=self.local / "SignedBuild"), \
             patch.object(renew, "read_profile", side_effect=[newer, newer]), \
             patch.object(renew.subprocess, "run", side_effect=command):
            result = renew.run(self.config, renew_now=True)
        self.assertEqual(result["status"], "installed")
        self.assertEqual(sum(c[0] == "/usr/bin/codesign" for c in commands), 2)
        self.assertEqual(sum(c[0] == "/usr/bin/xcrun" for c in commands), 1)
        self.assertFalse((self.local / "signing-profile-active.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
