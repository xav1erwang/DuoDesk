#!/usr/bin/env python3
"""Mac-assisted development signing. No passwords, private keys, or cloud service.

The scheduled process only reads a local config, uses Xcode's existing account session,
builds this checkout and installs the verified application onto the configured paired device.
It never uninstalls an app or removes any cached signing profile.
"""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "Local"
UTC = dt.timezone.utc
LABEL = "com.duodesk.signing-renewal"


def now():
    return dt.datetime.now(UTC)


def load_config(path):
    config = json.loads(path.read_text())
    allowed = {"team_id", "device_id", "bundle_id", "configuration", "renew_before_hours"}
    if set(config) - allowed:
        raise ValueError("Unknown config fields. Do not put account passwords in this file.")
    if not re.fullmatch(r"[A-Z0-9]{10}", config.get("team_id", "")):
        raise ValueError("Set team_id to the team selected in Xcode.")
    if not re.fullmatch(r"[A-Za-z0-9-]{16,64}", config.get("device_id", "")):
        raise ValueError("Set device_id to the paired physical Duo device identifier.")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}", config.get("bundle_id", "")):
        raise ValueError("Use your own reverse-DNS bundle_id.")
    if config.get("configuration", "Debug") not in {"Debug", "Release"}:
        raise ValueError("configuration must be Debug or Release.")
    hours = config.get("renew_before_hours", 48)
    if isinstance(hours, bool) or not isinstance(hours, (int, float)) or not 1 <= hours <= 120:
        raise ValueError("renew_before_hours must be between 1 and 120.")
    return config


def aware(value):
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def profile_expiration(profile, config):
    """Reject an unrelated team, app, or device before any installation."""
    if not isinstance(profile, dict) or not isinstance(profile.get("Entitlements"), dict):
        raise ValueError("The development profile is malformed.")
    entitlements = profile.get("Entitlements", {})
    expected = config["team_id"] + "." + config["bundle_id"]
    if entitlements.get("application-identifier") != expected:
        raise ValueError("The built profile belongs to a different app or signing team.")
    teams, devices = profile.get("TeamIdentifier"), profile.get("ProvisionedDevices")
    if not isinstance(teams, list) or not all(isinstance(value, str) for value in teams):
        raise ValueError("The development profile has no valid team list.")
    if not isinstance(devices, list) or not all(isinstance(value, str) for value in devices):
        raise ValueError("The development profile has no valid device list.")
    if config["team_id"] not in teams:
        raise ValueError("The profile does not authorize the configured team.")
    if config["device_id"] not in devices:
        raise ValueError("The profile does not authorize the configured Duo.")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        raise ValueError("The development profile has no readable expiration date.")
    return aware(expiration)


def renewal_due(expiration, current, hours):
    return expiration is None or expiration <= current + dt.timedelta(hours=hours)


def build_command(config):
    return ["/usr/bin/xcodebuild", "-project", str(ROOT / "iOSClient/Sill.xcodeproj"),
            "-scheme", "Sill", "-configuration", config.get("configuration", "Debug"),
            "-destination", "id=" + config["device_id"],
            "-derivedDataPath", str(LOCAL / "SignedBuild"),
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            "DEVELOPMENT_TEAM=" + config["team_id"],
            "PRODUCT_BUNDLE_IDENTIFIER=" + config["bundle_id"],
            "CODE_SIGN_STYLE=Automatic", "build"]


def read_profile(app):
    path = app / "embedded.mobileprovision"
    if not path.is_file():
        raise ValueError("No signed device build is available yet.")
    decoded = subprocess.check_output(["/usr/bin/security", "cms", "-D", "-i", str(path)],
                                      stderr=subprocess.PIPE, timeout=30)
    return plistlib.loads(decoded)


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(config, force=False, status_only=False):
    app = LOCAL / "SignedBuild/Build/Products" / (config.get("configuration", "Debug") + "-iphoneos/Sill.app")
    binding = hashlib.sha256(json.dumps({key: config[key] for key in ("team_id", "device_id", "bundle_id")}, sort_keys=True).encode()).hexdigest()
    state_path = LOCAL / "signing-status.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if not isinstance(state, dict):
        raise ValueError("The successful-install record is malformed.")
    # A fresh build is not evidence that the phone received it. Only the successful install record
    # can defer renewal; an interrupted/failed install must be retried on the next run.
    old_expiration = None
    if state.get("status") == "installed" and state.get("binding") == binding:
        try:
            old_expiration = aware(dt.datetime.fromisoformat(state.get("expires_at")))
        except (TypeError, ValueError) as error:
            raise ValueError("The successful-install expiration is malformed.") from error
    due = renewal_due(old_expiration, now(), config.get("renew_before_hours", 48))
    if status_only or (not force and not due):
        result = {"status": "renewal_due" if due else "valid",
                  "expires_at": old_expiration.isoformat() if old_expiration else None}
        print(json.dumps(result))
        return result

    # A missing or invalid cache does not prevent the next renewal from making a clean build.
    # Do not read it merely to report the last successful install or when a build is forced.
    built_expiration = None
    if not force and app.exists():
        try:
            built_expiration = profile_expiration(read_profile(app), config)
        except (OSError, ValueError, TypeError, subprocess.SubprocessError):
            pass
    # No shell interpolation: even paths containing spaces and a Chinese checkout name are safe.
    log = LOCAL / "signing-build.log"
    if force or renewal_due(built_expiration, now(), config.get("renew_before_hours", 48)):
        with log.open("ab") as output:
            subprocess.run(build_command(config), stdout=output, stderr=subprocess.STDOUT, check=True, timeout=1800)
    expiration = profile_expiration(read_profile(app), config)
    if expiration <= now() + dt.timedelta(hours=config.get("renew_before_hours", 48)):
        raise RuntimeError("Xcode did not issue a sufficiently fresh profile; see Local/signing-build.log.")
    if old_expiration is not None and expiration <= old_expiration:
        raise RuntimeError("The profile was not extended. The existing device app was left installed.")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != config["bundle_id"]:
        raise ValueError("The built app identifier does not match the local config.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=30)
    with log.open("ab") as output:
        subprocess.run(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device",
                        config["device_id"], str(app)], stdout=output, stderr=subprocess.STDOUT, check=True, timeout=180)
    result = {"status": "installed", "binding": binding, "checked_at": now().isoformat(), "expires_at": expiration.isoformat()}
    # Only advance successful-install state after the device reports success.
    atomic_json(LOCAL / "signing-status.json", result)
    print(json.dumps(result))
    return result


def agent_plist(config_path):
    agent = {"Label": LABEL,
             "ProgramArguments": [sys.executable, str(Path(__file__).resolve()), "--config", str(config_path.resolve())],
             "WorkingDirectory": str(ROOT), "StartInterval": 21600, "RunAtLoad": True,
             "StandardOutPath": str(LOCAL / "renewal.log"), "StandardErrorPath": str(LOCAL / "renewal-error.log"),
             "ProcessType": "Background"}
    # launchd doesn't inherit the shell's selected Xcode. Preserve only this nonsecret override,
    # not the account or other environment; without it, use the system-selected developer dir.
    if os.environ.get("DEVELOPER_DIR"):
        agent["EnvironmentVariables"] = {"DEVELOPER_DIR": os.environ["DEVELOPER_DIR"]}
    return agent


def enable_agent(config_path):
    # Explicit opt-in only. Development/CI and --status never install a background process.
    target = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    if target.exists():
        raise ValueError("The renewal agent is already installed. Disable it before updating its config path.")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(plistlib.dumps(agent_plist(config_path)))
    os.chmod(target, 0o600)
    try:
        subprocess.run(["/bin/launchctl", "bootstrap", "gui/" + str(os.getuid()), str(target)], check=True)
    except subprocess.SubprocessError:
        target.unlink(missing_ok=True)
        raise
    print("Renewal enabled for this Mac login. It checks every six hours and retries after failures.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=LOCAL / "signing.json")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--status", action="store_true")
    action.add_argument("--force", action="store_true")
    action.add_argument("--enable-auto", action="store_true")
    action.add_argument("--disable-auto", action="store_true")
    args = parser.parse_args()
    LOCAL.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(LOCAL, 0o700)
    if args.disable_auto:
        target = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
        if target.exists():
            subprocess.run(["/bin/launchctl", "bootout", "gui/" + str(os.getuid()), str(target)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            target.unlink()
        print("Renewal disabled. The app, profile, and signing keys remain intact.")
        return
    with (LOCAL / "signing.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("A signing job is already running.")
            return
        config = load_config(args.config)
        if args.enable_auto:
            enable_agent(args.config)
        else:
            run(config, force=args.force, status_only=args.status)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        # A failure is not an installation: retain the last successful expiry so retries cannot
        # silently replace it with an older profile. Details stay in a separate ignored file.
        atomic_json(LOCAL / "signing-error.json", {"status": "failed", "checked_at": now().isoformat(), "reason": str(error)})
        print("Signing could not finish. See Local/signing-error.json and Local/signing-build.log.", file=sys.stderr)
        sys.exit(1)
