import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("renew", Path(__file__).resolve().parents[2] / "Signing/renew.py")
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.config = {"team_id": "TESTTEAM01", "device_id": "00000000-0000000000000000", "bundle_id": "com.example.duodesk"}
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
        self.assertEqual(agent["StartInterval"], 21600)
        self.assertEqual(agent["ProgramArguments"][-1], str(path.resolve()))
        self.assertNotIn("/bin/sh", agent["ProgramArguments"])

    def test_failed_install_does_not_mark_signature_renewed(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(renew, "LOCAL", Path(directory)), patch.object(renew, "now", return_value=self.time):
            app = Path(directory) / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.config["bundle_id"]}))
            with patch.object(renew, "read_profile", return_value=self.profile), patch.object(renew.subprocess, "run") as run:
                run.side_effect = [None, subprocess.CalledProcessError(1, ["devicectl"])]
                with self.assertRaises(subprocess.CalledProcessError):
                    renew.run(self.config)
                self.assertFalse((Path(directory) / "signing-status.json").exists())
                run.side_effect = None
                renew.run(self.config)
                state = json.loads((Path(directory) / "signing-status.json").read_text())
                self.assertEqual(state["status"], "installed")
                self.assertEqual(run.call_args.args[0][1:4], ["devicectl", "device", "install"])

    def test_unextended_profile_never_reinstalled(self):
        self.profile["ExpirationDate"] = self.time + dt.timedelta(hours=6)
        with tempfile.TemporaryDirectory() as directory, patch.object(renew, "LOCAL", Path(directory)), patch.object(renew, "now", return_value=self.time):
            app = Path(directory) / "SignedBuild/Build/Products/Debug-iphoneos/Sill.app"
            app.mkdir(parents=True)
            with patch.object(renew, "read_profile", return_value=self.profile), patch.object(renew.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "fresh profile"):
                    renew.run(self.config)
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][0], "/usr/bin/xcodebuild")


if __name__ == "__main__":
    unittest.main()
