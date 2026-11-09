#!/usr/bin/env python3
"""Exercise the automatic schedule with fake time/devices; never signs or contacts a device."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("duodesk_renew_monitor", root / "Signing/renew.py")
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.local = Path(self.temp.name)
        self.config = {"team_id": "TESTTEAM01", "device_id": "00000000-0000000000000000",
                       "bundle_id": "com.example.duodesk"}
        self.clock = dt.datetime(2026, 11, 2, tzinfo=dt.timezone.utc)
        self.observation = {"connected": True, "transport": "localNetwork", "connection_date": 42}
        for stub in (patch.object(renew, "LOCAL", self.local),
                     patch.object(renew, "now", side_effect=lambda: self.clock),
                     patch.object(renew, "probe_device", side_effect=lambda _: self.observation)):
            stub.start()
            self.addCleanup(stub.stop)
        self.run = patch.object(renew, "run", return_value={"status": "installed"}).start()
        self.addCleanup(patch.stopall)

    def monitor(self):
        return renew.monitor(self.config)

    def test_daily_and_each_new_connection_without_repeated_builds(self):
        self.assertEqual(self.monitor()["status"], "installed")
        self.clock += dt.timedelta(minutes=1)
        self.assertEqual(self.monitor()["status"], "waiting_for_schedule")
        self.clock += dt.timedelta(hours=12)
        self.assertEqual(self.monitor()["status"], "waiting_for_schedule")
        self.clock += dt.timedelta(hours=12)
        self.assertEqual(self.monitor()["status"], "installed")
        self.assertEqual(self.run.call_count, 2)
        self.assertEqual(json.loads((self.local / "signing-monitor.json").read_text())["last_trigger"], "daily")
        self.observation = {"connected": False}
        self.clock += dt.timedelta(minutes=1)
        self.assertEqual(self.monitor()["status"], "waiting_for_device")
        self.observation = {"connected": True, "transport": "wired", "connection_date": 43}
        self.clock += dt.timedelta(minutes=1)
        self.assertEqual(self.monitor()["status"], "installed")
        self.assertEqual(self.run.call_count, 3)
        self.assertEqual(json.loads((self.local / "signing-monitor.json").read_text())["last_trigger"], "connected")
        self.assertTrue(all(call.kwargs == {"renew_now": True} for call in self.run.call_args_list))

    def test_unknown_probe_does_not_invent_a_disconnect_or_write_repeatedly(self):
        self.monitor()
        state_path = self.local / "signing-monitor.json"
        self.observation = None
        self.clock += dt.timedelta(minutes=1)
        self.assertEqual(self.monitor()["status"], "device_probe_unavailable")
        first = state_path.stat().st_mtime_ns
        self.clock += dt.timedelta(minutes=1)
        self.monitor()
        self.assertEqual(state_path.stat().st_mtime_ns, first)
        self.observation = {"connected": True, "transport": "localNetwork", "connection_date": 42}
        self.clock += dt.timedelta(minutes=1)
        self.assertEqual(self.monitor()["status"], "waiting_for_schedule")
        self.assertEqual(self.run.call_count, 1)

    def test_signing_connection_timestamp_does_not_trigger_another_build(self):
        self.monitor()
        self.clock += dt.timedelta(minutes=1)
        self.observation["connection_date"] = 43
        self.assertEqual(self.monitor()["status"], "waiting_for_schedule")
        self.clock += dt.timedelta(minutes=2)
        self.observation["connection_date"] = 44
        self.assertEqual(self.monitor()["status"], "waiting_for_schedule")
        self.observation["transport"] = "wired"
        self.assertEqual(self.monitor()["status"], "installed")
        self.assertEqual(self.run.call_count, 2)

    def mark_pending(self):
        path = self.local / "signing-pending.json"
        path.write_text(json.dumps({"binding": renew.config_binding(self.config), "source_id": "a" * 64}))
        return path

    def test_interrupted_install_is_retried_without_waiting_a_day(self):
        self.monitor()
        state_path = self.local / "signing-monitor.json"
        state = json.loads(state_path.read_text())
        state.update(last_result="running", last_trigger="daily")
        state_path.write_text(json.dumps(state))
        pending = self.mark_pending()
        self.clock += dt.timedelta(minutes=1)
        self.run.side_effect = lambda *args, **kwargs: (pending.unlink(), {"status": "installed"})[1]
        self.assertEqual(self.monitor()["status"], "installed")
        self.assertEqual(self.run.call_count, 2)
        self.assertEqual(json.loads(state_path.read_text())["last_trigger"], "interrupted")
        self.clock += dt.timedelta(minutes=1)
        self.assertEqual(self.monitor()["status"], "waiting_for_schedule")

    def test_interrupted_manual_install_is_retried_once(self):
        self.monitor()
        pending = self.mark_pending()
        self.clock += dt.timedelta(minutes=1)
        self.run.side_effect = lambda *args, **kwargs: (pending.unlink(), {"status": "installed"})[1]
        self.assertEqual(self.monitor()["status"], "installed")
        self.assertEqual(self.run.call_count, 2)

    def test_interrupted_recovery_or_failed_install_does_not_retry_every_minute(self):
        self.monitor()
        state_path = self.local / "signing-monitor.json"
        state = json.loads(state_path.read_text())
        self.mark_pending()
        for result, trigger in (("running", "interrupted"), ("failed", "interrupted")):
            state.update(last_result=result, last_trigger=trigger)
            state_path.write_text(json.dumps(state))
            self.clock += dt.timedelta(minutes=1)
            self.assertEqual(self.monitor()["status"], "waiting_for_schedule")
        self.assertEqual(self.run.call_count, 1)

    def test_interrupted_install_waits_for_device(self):
        self.monitor()
        self.mark_pending()
        self.observation = {"connected": False}
        self.clock += dt.timedelta(minutes=1)
        self.assertEqual(self.monitor()["status"], "waiting_for_device")
        self.assertEqual(self.run.call_count, 1)

    def test_failure_near_expiry_retries_after_six_hours(self):
        state = {"status": "installed", "binding": renew.config_binding(self.config),
                 "expires_at": (self.clock + dt.timedelta(hours=30)).isoformat()}
        (self.local / "signing-status.json").write_text(json.dumps(state))
        self.run.side_effect = [RuntimeError("simulated failure"), {"status": "installed"}]
        with self.assertRaisesRegex(RuntimeError, "simulated failure"):
            self.monitor()
        self.clock += dt.timedelta(hours=5)
        self.assertEqual(self.monitor()["status"], "waiting_for_schedule")
        self.clock += dt.timedelta(hours=1)
        self.assertEqual(self.monitor()["status"], "installed")
        self.assertEqual(self.run.call_count, 2)

    def test_disconnected_phone_never_builds(self):
        self.observation = {"connected": False}
        self.assertEqual(self.monitor()["status"], "waiting_for_device")
        self.run.assert_not_called()

    def test_available_phone_without_an_open_developer_tunnel_can_renew(self):
        expected = self.config["device_id"]
        capability = {"featureIdentifier": "com.apple.coredevice.feature.connectdevice"}
        # Xcode's UI says "available (paired)" while its JSON tunnel state is disconnected.
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                if legacy:
                    device = {"hardwareProperties": {"udid": expected, "reality": "physical"},
                              "connectionProperties": {"tunnelState": "disconnected", "pairingState": "paired"}}
                else:
                    device = {"properties": {"hardware": {"udid": expected, "reality": "physical"},
                              "connection": {"state": "disconnected", "pairingState": "paired"}}}
                document = {"result": {"devices": [device]}}
                self.assertFalse(renew.observed_device(document, expected)["connected"])
                device["capabilities"] = [capability]
                self.assertTrue(renew.observed_device(document, expected)["connected"])
                connection = device["connectionProperties"] if legacy else device["properties"]["connection"]
                connection["pairingState"] = "unpaired"
                self.assertFalse(renew.observed_device(document, expected)["connected"])
                connection["pairingState"] = "paired"
                connection["tunnelState" if legacy else "state"] = "unavailable"
                self.assertFalse(renew.observed_device(document, expected)["connected"])

    def test_only_the_paired_physical_target_can_trigger(self):
        def item(device_id, reality="physical", state="connected", pairing="paired"):
            return {"properties": {"hardware": {"udid": device_id, "reality": reality},
                                   "connection": {"state": state, "pairingState": pairing,
                                                  "transportType": "wired", "lastConnectionDate": 10}}}
        expected = self.config["device_id"]
        document = {"result": {"devices": [item("different"), item(expected)]}}
        self.assertTrue(renew.observed_device(document, expected)["connected"])
        document["result"]["devices"][-1] = item(expected, reality="simulated")
        self.assertIsNone(renew.observed_device(document, expected))
        document["result"]["devices"][-1] = item(expected, pairing="unpaired")
        self.assertFalse(renew.observed_device(document, expected)["connected"])
        document["result"]["devices"] = [item("different")]
        self.assertFalse(renew.observed_device(document, expected)["connected"])
        self.assertIsNone(renew.observed_device({"result": {}}, expected))

    def test_existing_agent_plist_is_restored_if_update_fails(self):
        home = self.local / "home"
        target = home / "Library/LaunchAgents" / (renew.LABEL + ".plist")
        target.parent.mkdir(parents=True)
        target.write_bytes(b"previous plist")
        commands = []
        def launchctl(command, **kwargs):
            commands.append(command)
            if command[1] == "print":
                return types.SimpleNamespace(returncode=0)
            if command[1] == "bootstrap" and sum(c[1] == "bootstrap" for c in commands) == 1:
                raise subprocess.CalledProcessError(1, command)
            return types.SimpleNamespace(returncode=0)
        with patch.object(Path, "home", return_value=home), patch.object(renew.subprocess, "run", side_effect=launchctl):
            with self.assertRaises(subprocess.CalledProcessError):
                renew.enable_agent(self.local / "config.json")
        self.assertEqual(target.read_bytes(), b"previous plist")
        self.assertEqual([command[1] for command in commands], ["print", "bootout", "bootstrap", "bootstrap"])
        self.assertTrue(commands[1][-1].endswith("/" + renew.LABEL))


if __name__ == "__main__":
    unittest.main(verbosity=2)
