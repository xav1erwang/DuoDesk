import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("renew", Path(__file__).resolve().parents[2] / "Signing/renew.py")
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)
import device_install


class SigningTests(unittest.TestCase):
    def setUp(self):
        # These suites isolate signing/snapshot behavior; device-version checks have their own
        # simulated two-Mac regression tests in signing-device-version.
        for stub in (patch.object(renew, "installed_version", return_value=None),
                     patch.object(renew, "project_version", return_value=("0.1.0", "1")),
                     patch.object(device_install, "installed_version", return_value=("0.1.0", "1")),
                     patch.object(device_install, "project_version", return_value=("0.1.0", "1"))):
            stub.start()
            self.addCleanup(stub.stop)
        self.config = {"team_id": "TESTTEAM01", "device_id": "00000000-0000000000000000", "bundle_id": "com.example.duodesk"}
        self.source_id = "a" * 64
        self.source_root = Path("/tmp/duodesk-approved-source")
        for stub in (patch.object(renew, "capture_snapshot", return_value=(self.source_id, self.source_root)),
                     patch.object(renew, "validate_snapshot", return_value=self.source_root),
                     patch.object(renew, "profile_cache_directories", return_value=[]),
                     patch.object(renew, "build_dir_for_source", side_effect=lambda _: renew.LOCAL / "SignedBuild")):
            stub.start()
            self.addCleanup(stub.stop)
        self.time = dt.datetime(2026, 10, 25, tzinfo=dt.timezone.utc)
        self.profile = {"Entitlements": {"application-identifier": "TESTTEAM01.com.example.duodesk"},
                        "TeamIdentifier": ["TESTTEAM01"], "ProvisionedDevices": [self.config["device_id"]],
                        "ExpirationDate": self.time + dt.timedelta(days=7)}

    def test_expiry_threshold(self):
        self.assertTrue(renew.renewal_due(None, self.time, 48))
        self.assertTrue(renew.renewal_due(self.time - dt.timedelta(days=1), self.time, 48))
        self.assertTrue(renew.renewal_due(self.time + dt.timedelta(hours=48), self.time, 48))
        self.assertFalse(renew.renewal_due(self.time + dt.timedelta(hours=49), self.time, 48))

    def test_naive_profile_dates_are_utc(self):
        self.profile["ExpirationDate"] = self.profile["ExpirationDate"].replace(tzinfo=None)
        self.assertEqual(renew.profile_expiration(self.profile, self.config), self.time + dt.timedelta(days=7))

    def test_wrong_team_app_or_device_refused(self):
        for key, value in [("team_id", "OTHERTEAM1"), ("bundle_id", "com.other.app"), ("device_id", "otherdevice")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                renew.profile_expiration(self.profile, dict(self.config, **{key: value}))

    def test_malformed_profile_lists_are_not_accepted_as_membership(self):
        for field, value in [("TeamIdentifier", "prefixTESTTEAM01suffix"), ("ProvisionedDevices", None)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                renew.profile_expiration(dict(self.profile, **{field: value}), self.config)

    def test_config_rejects_shell_and_password_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            for field, value in [("bundle_id", "com.example.app;touch /tmp/evil"), ("password", "do-not-store"), ("renew_before_hours", -1)]:
                path.write_text(json.dumps(dict(self.config, **{field: value})))
                with self.subTest(field=field), self.assertRaises(ValueError):
                    renew.load_config(path)
            path.write_text(json.dumps(self.config))
            self.assertEqual(renew.load_config(path), self.config)

    def test_command_uses_local_account_and_specific_device(self):
        command = renew.build_command(self.config)
        self.assertIn("-allowProvisioningUpdates", command)
        self.assertIn("-allowProvisioningDeviceRegistration", command)
        self.assertIn("id=" + self.config["device_id"], command)
        self.assertFalse(any("password" in part.lower() for part in command))
        self.assertNotIn("uninstall", command)

    def test_schedule_is_opt_in_with_argument_paths(self):
        path = Path("/tmp/project with spaces/config.json")
        agent = renew.agent_plist(path)
        self.assertEqual(agent["StartInterval"], 60)
        self.assertEqual(agent["ProgramArguments"][-2:], [str(path.resolve()), "--monitor"])
        self.assertNotIn("/bin/sh", agent["ProgramArguments"])

    def test_schedule_preserves_selected_xcode_without_other_environment(self):
        developer = "/Applications/Xcode-27.1.app/Contents/Developer"
        with patch.dict(os.environ, {"DEVELOPER_DIR": developer, "TEST_ACCOUNT_SECRET": "do-not-copy"}):
            agent = renew.agent_plist(Path("/tmp/duodesk-signing.json"))
        self.assertEqual(agent.get("EnvironmentVariables"), {"DEVELOPER_DIR": developer})

    def test_failed_install_does_not_mark_signature_renewed(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(renew, "LOCAL", Path(directory)), patch.object(renew, "now", return_value=self.time):
            app = Path(directory) / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"], "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}))
            with patch.object(renew, "read_profile", return_value=self.profile), patch.object(renew.subprocess, "run") as run:
                run.side_effect = [None, None, subprocess.CalledProcessError(1, ["devicectl"])]
                with self.assertRaises(subprocess.CalledProcessError):
                    renew.run(self.config)
                self.assertFalse((Path(directory) / "signing-status.json").exists())
                self.assertEqual(json.loads((Path(directory) / "signing-pending.json").read_text())["source_id"], self.source_id)
                run.side_effect = None
                renew.run(self.config)
                state = json.loads((Path(directory) / "signing-status.json").read_text())
                self.assertEqual(state["status"], "installed")
                self.assertFalse((Path(directory) / "signing-pending.json").exists())
                self.assertEqual(run.call_args.args[0][1:4], ["devicectl", "device", "install"])

    def test_unextended_profile_never_reinstalled(self):
        self.profile["ExpirationDate"] = self.time + dt.timedelta(hours=6)
        with tempfile.TemporaryDirectory() as directory, patch.object(renew, "LOCAL", Path(directory)), patch.object(renew, "now", return_value=self.time):
            app = Path(directory) / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
            app.mkdir(parents=True)
            with patch.object(renew, "read_profile", return_value=self.profile), patch.object(renew.subprocess, "run") as run, \
                 patch.object(renew, "export_refreshed_app", return_value=app) as export:
                with self.assertRaisesRegex(RuntimeError, "fresh profile"):
                    renew.run(self.config)
                export.assert_called_once()
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][0], "/usr/bin/xcodebuild")

    def install_record(self, expiration):
        binding = hashlib.sha256(json.dumps({key: self.config[key] for key in ("team_id", "device_id", "bundle_id")},
                                            sort_keys=True).encode()).hexdigest()
        return {"status": "installed", "binding": binding, "checked_at": self.time.isoformat(),
                "expires_at": expiration.isoformat(), "source_id": self.source_id}

    def test_cli_failure_preserves_last_successful_install(self):
        # Execute the actual command in an isolated copy with a fake Xcode failure. No signing,
        # account, device service or real project state is accessed.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); signing = root / "Signing"; local = root / "Local"
            signing.mkdir(); local.mkdir()
            script = signing / "renew.py"
            shutil.copyfile(Path(renew.__file__), script)
            shutil.copyfile(Path(renew.__file__).with_name("source_snapshot.py"), signing / "source_snapshot.py")
            (local / "signing.json").write_text(json.dumps(self.config))
            app = local / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
            app.mkdir(parents=True)
            (app / "embedded.mobileprovision").write_bytes(b"synthetic profile")
            current = dt.datetime.now(dt.timezone.utc)
            old = self.install_record(current + dt.timedelta(hours=24))
            (local / "signing-status.json").write_text(json.dumps(old))
            profile = dict(self.profile, ExpirationDate=current + dt.timedelta(hours=24))
            failure = subprocess.CalledProcessError(1, ["xcodebuild"])
            with patch.object(sys, "argv", [str(script)]), \
                 patch.object(subprocess, "check_output", return_value=plistlib.dumps(profile)), \
                 patch("source_snapshot.capture_snapshot", return_value=(self.source_id, self.source_root)), \
                 patch("source_snapshot.validate_snapshot", return_value=self.source_root), \
                 patch.object(subprocess, "run", side_effect=failure) as run, redirect_stderr(StringIO()):
                with self.assertRaises(SystemExit) as exit_code:
                    runpy.run_path(str(script), run_name="__main__")
            self.assertEqual(exit_code.exception.code, 1)
            self.assertEqual(run.call_args.args[0][0], "/usr/bin/xcodebuild")
            self.assertEqual(json.loads((local / "signing-status.json").read_text()), old)
            self.assertEqual(json.loads((local / "signing-error.json").read_text())["status"], "failed")

    def test_manual_renewal_reports_busy_without_claiming_success(self):
        with tempfile.TemporaryDirectory() as directory:
            signing = Path(directory) / "Signing"
            signing.mkdir()
            script = signing / "renew.py"
            shutil.copyfile(Path(renew.__file__), script)
            shutil.copyfile(Path(renew.__file__).with_name("source_snapshot.py"), signing / "source_snapshot.py")
            with patch.object(sys, "argv", [str(script), "--renew-now"]), \
                 patch.object(renew.fcntl, "flock", side_effect=BlockingIOError()), redirect_stderr(StringIO()):
                with self.assertRaises(SystemExit) as exit_code:
                    runpy.run_path(str(script), run_name="__main__")
            self.assertEqual(exit_code.exception.code, 75)
            self.assertFalse((Path(directory) / "Local/signing-status.json").exists())

    def test_manual_renewal_reports_disconnected_phone_without_claiming_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); signing = root / "Signing"; local = root / "Local"
            signing.mkdir(); local.mkdir()
            script = signing / "renew.py"
            shutil.copyfile(Path(renew.__file__), script)
            shutil.copyfile(Path(renew.__file__).with_name("source_snapshot.py"), signing / "source_snapshot.py")
            (local / "signing.json").write_text(json.dumps(self.config))
            response = subprocess.CompletedProcess([], 0, stdout=json.dumps({"result": {"devices": []}}), stderr="")
            output = StringIO()
            with patch.object(sys, "argv", [str(script), "--renew-now"]), \
                 patch.object(subprocess, "run", return_value=response), redirect_stdout(output):
                with self.assertRaises(SystemExit) as exit_code:
                    runpy.run_path(str(script), run_name="__main__")
            self.assertEqual(exit_code.exception.code, 75)
            self.assertEqual(json.loads(output.getvalue())["status"], "waiting_for_device")
            self.assertFalse((local / "signing-status.json").exists())

    def test_force_refuses_a_fresh_but_older_profile(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(renew, "LOCAL", Path(directory)), patch.object(renew, "now", return_value=self.time):
            app = Path(directory) / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"], "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}))
            (Path(directory) / "signing-status.json").write_text(json.dumps(self.install_record(self.time + dt.timedelta(days=6))))
            older = dict(self.profile, ExpirationDate=self.time + dt.timedelta(days=4))
            with patch.object(renew, "read_profile", return_value=older), patch.object(renew.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "not extended"):
                    renew.run(self.config, force=True)
                self.assertFalse(any(call.args[0][1:4] == ["devicectl", "device", "install"] for call in run.call_args_list))

    def test_force_updates_code_with_the_same_still_valid_profile(self):
        # Rebuilding source does not necessarily cause Xcode to issue a new profile. A manual
        # force may install that updated build while preserving the installed expiration; the
        # automatic renewal path still requires an extension.
        with tempfile.TemporaryDirectory() as directory, patch.object(renew, "LOCAL", Path(directory)), patch.object(renew, "now", return_value=self.time):
            app = Path(directory) / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"], "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}))
            expiration = self.time + dt.timedelta(days=6)
            state_path = Path(directory) / "signing-status.json"
            old = self.install_record(expiration)
            state_path.write_text(json.dumps(old))
            profile = dict(self.profile, ExpirationDate=expiration)
            with patch.object(renew, "read_profile", return_value=profile), patch.object(renew.subprocess, "run") as run:
                run.side_effect = [None, None, subprocess.CalledProcessError(1, ["devicectl"])]
                with self.assertRaises(subprocess.CalledProcessError):
                    renew.run(self.config, force=True)
                self.assertEqual(json.loads(state_path.read_text()), old)
                run.reset_mock(); run.side_effect = None
                result = renew.run(self.config, force=True)
                self.assertEqual(result["expires_at"], expiration.isoformat())
                self.assertEqual(result["status"], "installed")
                self.assertEqual(run.call_args_list[0].args[0][0], "/usr/bin/xcodebuild")
                self.assertEqual(run.call_args_list[-1].args[0][1:4], ["devicectl", "device", "install"])

    def test_manual_update_inside_renewal_window_requires_only_an_unexpired_profile(self):
        for hours in (24, 0, -1):
            with self.subTest(hours=hours), tempfile.TemporaryDirectory() as directory, \
                 patch.object(renew, "LOCAL", Path(directory)), patch.object(renew, "now", return_value=self.time):
                app = Path(directory) / "Sill.app"
                app.mkdir()
                (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"], "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}))
                expiration = self.time + dt.timedelta(hours=hours)
                state_path = Path(directory) / "signing-status.json"
                original = self.install_record(expiration)
                state_path.write_text(json.dumps(original))
                with patch.object(renew.subprocess, "run") as run:
                    if hours > 0:
                        result = renew.install_verified_app(app, self.config, expiration, expiration, True,
                                                            "test-binding", Path(directory) / "build.log", self.source_id)
                        self.assertEqual(result["expires_at"], expiration.isoformat())
                        self.assertEqual(run.call_args_list[-1].args[0][1:4], ["devicectl", "device", "install"])
                    else:
                        with self.assertRaisesRegex(RuntimeError, "expired"):
                            renew.install_verified_app(app, self.config, expiration, expiration, True,
                                                       "test-binding", Path(directory) / "build.log", self.source_id)
                        run.assert_not_called()
                        self.assertEqual(json.loads(state_path.read_text()), original)

    def test_daily_attempt_does_not_call_an_unchanged_profile_a_renewal(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(renew, "LOCAL", Path(directory)), patch.object(renew, "now", return_value=self.time):
            app = Path(directory) / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"], "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}))
            expiration = self.time + dt.timedelta(days=6)
            state = self.install_record(expiration)
            (Path(directory) / "signing-status.json").write_text(json.dumps(state))
            profile = dict(self.profile, ExpirationDate=expiration)
            with patch.object(renew, "read_profile", return_value=profile), patch.object(renew.subprocess, "run") as run, \
                 patch.object(renew, "export_refreshed_app", return_value=app) as export:
                with self.assertRaisesRegex(RuntimeError, "not extended"):
                    renew.run(self.config, renew_now=True)
                export.assert_called_once()
                self.assertFalse(any(call.args[0][1:4] == ["devicectl", "device", "install"] for call in run.call_args_list))
                self.assertEqual(json.loads((Path(directory) / "signing-status.json").read_text()), state)

    def test_status_does_not_depend_on_an_invalid_cached_build(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(renew, "LOCAL", Path(directory)), patch.object(renew, "now", return_value=self.time):
            app = Path(directory) / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
            app.mkdir(parents=True)
            (Path(directory) / "signing-status.json").write_text(json.dumps(self.install_record(self.time + dt.timedelta(days=6))))
            with patch.object(renew, "read_profile", side_effect=ValueError("invalid cached profile")) as read:
                self.assertEqual(renew.run(self.config, status_only=True)["status"], "valid")
                read.assert_not_called()

    def test_due_renewal_rebuilds_from_approved_source(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(renew, "LOCAL", Path(directory)), patch.object(renew, "now", return_value=self.time):
            app = Path(directory) / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"], "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}))
            (Path(directory) / "signing-status.json").write_text(json.dumps(self.install_record(self.time + dt.timedelta(hours=24))))
            with patch.object(renew, "read_profile", return_value=self.profile) as read, \
                 patch.object(renew.subprocess, "run") as run:
                result = renew.run(self.config)
                self.assertEqual(result["status"], "installed")
                self.assertEqual(run.call_args_list[0].args[0][0], "/usr/bin/xcodebuild")
                self.assertIn(str(self.source_root / "iOSClient/Sill.xcodeproj"), run.call_args_list[0].args[0])
                read.assert_called_once_with(app)
                self.assertEqual(run.call_args_list[-1].args[0][1:4], ["devicectl", "device", "install"])


if __name__ == "__main__":
    unittest.main()
