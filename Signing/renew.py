#!/usr/bin/env python3
"""Mac-assisted development signing. No passwords, private keys, or cloud service.

The scheduled process uses Xcode's existing account session and builds a fresh, coherent snapshot
of the current project's latest source. Old successful or interrupted snapshots are never reused.
It never uninstalls an app or removes any cached signing profile.
"""
import argparse
from contextlib import contextmanager
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
import uuid

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "Local"
UTC = dt.timezone.utc
LABEL = "com.duodesk.signing-renewal"
MONITOR_INTERVAL_SECONDS = 60
DEFAULT_RENEW_INTERVAL_HOURS = 24
EXPIRY_RETRY_HOURS = 6
sys.path.insert(0, str(Path(__file__).resolve().parent))
from source_snapshot import capture_snapshot, validate_snapshot
from device_install import (StaleDeviceBuild, project_version, bump_project_build,
                           installed_version, require_current_build, install_and_verify, version_key)


def now():
    return dt.datetime.now(UTC)


def load_config(path):
    config = json.loads(path.read_text())
    allowed = {"team_id", "device_id", "bundle_id", "configuration", "renew_before_hours", "renew_interval_hours"}
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
    interval = config.get("renew_interval_hours", DEFAULT_RENEW_INTERVAL_HOURS)
    if isinstance(interval, bool) or not isinstance(interval, (int, float)) or not 1 <= interval <= 168:
        raise ValueError("renew_interval_hours must be between 1 and 168.")
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


def build_dir_for_source(source_id):
    return LOCAL / "SigningBuilds" / source_id


def build_command(config, source_root=None, build_root=None):
    source_root = ROOT if source_root is None else source_root
    build_root = LOCAL / "SignedBuild" if build_root is None else build_root
    return ["/usr/bin/xcodebuild", "-project", str(source_root / "iOSClient/Sill.xcodeproj"),
            "-scheme", "Sill", "-configuration", config.get("configuration", "Debug"),
            "-destination", "id=" + config["device_id"],
            "-derivedDataPath", str(build_root),
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
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def export_refreshed_app(config, work, log, source_root=None, build_root=None):
    """Ask Xcode to re-sign an archive for debugging when an ordinary build reused a stale profile.

    This uses Xcode's automatic-signing export, never removes cached profiles and never uploads an
    app. Everything exported remains in a private temporary directory until installation finishes.
    A successful export still needs the same profile, app identity and signature checks as a build.
    """
    archive = work / "DUO.xcarchive"
    output = work / "Export"
    extracted = work / "Extracted"
    options = work / "ExportOptions.plist"
    options.write_bytes(plistlib.dumps({"method": "debugging", "destination": "export",
                                        "signingStyle": "automatic", "teamID": config["team_id"]}))
    command = build_command(config, source_root, build_root)
    command[-1] = "archive"
    index = command.index("-derivedDataPath")
    command[index:index] = ["-archivePath", str(archive)]
    with log.open("ab") as output_log:
        subprocess.run(command, stdout=output_log, stderr=subprocess.STDOUT, check=True, timeout=1800)
        subprocess.run(["/usr/bin/xcodebuild", "-exportArchive", "-archivePath", str(archive),
                        "-exportPath", str(output), "-exportOptionsPlist", str(options),
                        "-allowProvisioningUpdates"], stdout=output_log, stderr=subprocess.STDOUT,
                       check=True, timeout=1800)
    ipas = [path for path in output.glob("*.ipa") if path.is_file()]
    if len(ipas) != 1:
        raise ValueError("Xcode did not export exactly one device app.")
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(ipas[0]), str(extracted)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=180)
    payload = extracted / "Payload"
    apps = [path for path in payload.glob("*.app") if path.is_dir()]
    if len(apps) != 1:
        raise ValueError("The Xcode export does not contain exactly one app bundle.")
    return apps[0]


def profile_cache_directories():
    return [Path.home() / "Library/MobileDevice/Provisioning Profiles",
            Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"]


def matching_cached_profiles(config, keep_at_or_after=None):
    """Find only this app/team/device's unexpired profiles; never move wildcard profiles."""
    result = []
    expected = config["team_id"] + "." + config["bundle_id"]
    for directory in profile_cache_directories():
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if path.is_symlink() or not path.is_file() or path.suffix not in {".mobileprovision", ".provisionprofile"}:
                continue
            try:
                if path.stat().st_size > 4 * 1024 * 1024:
                    continue
                raw = path.read_bytes()
                decoded = subprocess.check_output(["/usr/bin/security", "cms", "-D", "-i", str(path)],
                                                  stderr=subprocess.PIPE, timeout=30)
                profile = plistlib.loads(decoded)
                if not isinstance(profile, dict):
                    continue
                entitlements = profile.get("Entitlements", {})
                expiration = profile.get("ExpirationDate")
                teams, devices = profile.get("TeamIdentifier"), profile.get("ProvisionedDevices")
                if (not isinstance(entitlements, dict) or not isinstance(expiration, dt.datetime)
                    or not isinstance(teams, list) or not all(isinstance(value, str) for value in teams)
                    or not isinstance(devices, list) or not all(isinstance(value, str) for value in devices)):
                    continue
                if (entitlements.get("application-identifier") == expected
                    and config["team_id"] in teams and config["device_id"] in devices
                    and aware(expiration) > now()
                    and (keep_at_or_after is None or aware(expiration) < keep_at_or_after)
                    and path.read_bytes() == raw):
                    result.append((path.resolve(), raw, path.stat().st_mode & 0o777))
            except (OSError, ValueError, TypeError, plistlib.InvalidFileException, subprocess.SubprocessError):
                continue
    return result


def restore_profile_bytes(source, data, mode, transaction, index):
    """Restore without overwriting a file Xcode or the user created in the meantime."""
    candidates = [source, source.with_name(source.stem + ".duodesk-restored-" + transaction[:12] + "-" + str(index) + source.suffix)]
    for candidate in candidates:
        if candidate.is_symlink():
            continue
        try:
            fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
        except FileExistsError:
            if candidate.is_file() and candidate.read_bytes() == data:
                return
            continue
        created = os.fstat(fd)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
        except OSError:
            try:
                current = candidate.lstat()
                if current.st_ino == created.st_ino and current.st_dev == created.st_dev:
                    candidate.unlink()
            except OSError:
                pass
            raise
        return
    raise RuntimeError("A cached profile could not be restored without overwriting another file.")


def recover_profile_cache(config):
    """Idempotently restore only a previous, app-scoped cache transaction after interruption."""
    active = LOCAL / "signing-profile-active.json"
    if not active.exists():
        return
    pointer = json.loads(active.read_text())
    transaction = pointer.get("transaction") if isinstance(pointer, dict) else None
    if not isinstance(transaction, str) or not re.fullmatch(r"[a-f0-9]{32}", transaction):
        raise ValueError("The profile-cache recovery pointer is malformed.")
    directory = LOCAL / "signing-profile-backups" / transaction
    manifest = json.loads((directory / "manifest.json").read_text())
    if not isinstance(manifest, dict) or manifest.get("binding") != config_binding(config) or not isinstance(manifest.get("profiles"), list):
        raise ValueError("The profile-cache backup belongs to a different configuration or is malformed.")
    allowed = {path.resolve() for path in profile_cache_directories()}
    for index, entry in enumerate(manifest["profiles"]):
        if not isinstance(entry, dict) or not isinstance(entry.get("source"), str):
            raise ValueError("The profile-cache backup entry is malformed.")
        source = Path(entry["source"])
        if (not source.is_absolute() or source.parent.resolve() not in allowed
            or source.suffix not in {".mobileprovision", ".provisionprofile"}):
            raise ValueError("The profile-cache backup has an unexpected destination.")
        backup = directory / ("profile-" + str(index) + ".backup")
        held = directory / ("profile-" + str(index) + ".held")
        if backup.is_symlink() or not backup.is_file():
            raise ValueError("The profile-cache backup is missing.")
        saved = backup.read_bytes()
        if hashlib.sha256(saved).hexdigest() != entry.get("sha256"):
            raise ValueError("The profile-cache backup changed and was not restored.")
        mode = entry.get("mode")
        if not isinstance(mode, int) or not 0 <= mode <= 0o777:
            raise ValueError("The profile-cache backup mode is invalid.")
        if held.exists():
            if held.is_symlink() or not held.is_file():
                raise ValueError("The held profile is not a regular file.")
            held_data = held.read_bytes()
            restore_profile_bytes(source, held_data, mode, transaction, index * 2)
            if held_data != saved:
                restore_profile_bytes(source, saved, mode, transaction, index * 2 + 1)
        else:
            restore_profile_bytes(source, saved, mode, transaction, index * 2 + 1)
    active.unlink()


@contextmanager
def temporarily_hide_cached_profiles(config, keep_at_or_after=None):
    """Follow Xcode's documented cache-refresh path while retaining crash-recoverable copies."""
    recover_profile_cache(config)
    profiles = matching_cached_profiles(config, keep_at_or_after=keep_at_or_after)
    if not profiles:
        yield False
        return
    parent = LOCAL / "signing-profile-backups"
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    transaction = uuid.uuid4().hex
    directory = parent / transaction
    directory.mkdir(mode=0o700)
    entries = []
    for index, (source, raw, mode) in enumerate(profiles):
        backup = directory / ("profile-" + str(index) + ".backup")
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        entries.append({"source": str(source), "sha256": hashlib.sha256(raw).hexdigest(), "mode": mode})
    atomic_json(directory / "manifest.json", {"binding": config_binding(config), "profiles": entries})
    atomic_json(LOCAL / "signing-profile-active.json", {"transaction": transaction})
    try:
        for index, (source, raw, _) in enumerate(profiles):
            if source.is_symlink() or source.read_bytes() != raw:
                raise RuntimeError("A cached profile changed before refresh; it was left in place.")
            held = directory / ("profile-" + str(index) + ".held")
            os.replace(source, held)
            if held.read_bytes() != raw:
                raise RuntimeError("A cached profile changed during refresh; both copies will be restored.")
        yield True
    finally:
        recover_profile_cache(config)


class InvalidSignedBundle(RuntimeError):
    pass


def install_verified_app(app, config, expiration, old_expiration, force, binding, log, source_id=None):
    if expiration <= now():
        raise RuntimeError("The development profile has expired; the build was not installed.")
    # --force updates source as well as signing. The renewal lead time must not prevent a
    # manual code update with the same, still-valid signature already installed on the phone.
    if not force and expiration <= now() + dt.timedelta(hours=config.get("renew_before_hours", 48)):
        raise RuntimeError("Xcode did not issue a sufficiently fresh profile; see Local/signing-build.log.")
    if old_expiration is not None and (expiration < old_expiration or (not force and expiration == old_expiration)):
        raise RuntimeError("The profile was not extended or would shorten the existing installation. The existing device app was left installed.")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != config["bundle_id"]:
        raise ValueError("The built app identifier does not match the local config.")
    try:
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=30)
    except subprocess.CalledProcessError as error:
        raise InvalidSignedBundle("The built app failed signature verification; it was not installed.") from error
    pending = LOCAL / "signing-pending.json"
    if source_id is not None:
        # Record an interrupted attempt so the monitor retries promptly. The retry captures
        # the current project again; this receipt never selects an older build source.
        atomic_json(pending, {"binding": binding, "source_id": source_id})
    release, build = install_and_verify(app, config, log)
    result = {"status": "installed", "binding": binding, "checked_at": now().isoformat(), "expires_at": expiration.isoformat(),
              "version": release, "build": build}
    if source_id is not None:
        result["source_id"] = source_id
    # Only advance successful-install state after the device reports success.
    atomic_json(LOCAL / "signing-status.json", result)
    if source_id is not None:
        pending.unlink(missing_ok=True)
    print(json.dumps(result))
    return result


def fresh_signed_build(config, source_root, source_id, log, old_expiration, force, binding,
                       require_hidden=False, keep_at_or_after=None):
    """Build in an isolated directory so a changed profile is sealed into a new signature."""
    with tempfile.TemporaryDirectory(prefix="duodesk-signing-fresh-", dir=LOCAL) as directory:
        build_root = Path(directory) / "DerivedData"
        app = build_root / "Build/Products" / (config.get("configuration", "Debug") + "-iphoneos/Sill.app")
        with temporarily_hide_cached_profiles(config, keep_at_or_after=keep_at_or_after) as hidden:
            if require_hidden and not hidden:
                raise RuntimeError("The profile was not extended and no fresh profile was available from the matching cache.")
            with log.open("ab") as output:
                subprocess.run(build_command(config, source_root, build_root), stdout=output, stderr=subprocess.STDOUT,
                               check=True, timeout=1800)
            validate_snapshot(LOCAL, source_id)
            expiration = profile_expiration(read_profile(app), config)
        return install_verified_app(app, config, expiration, old_expiration, force, binding, log, source_id)


def config_binding(config):
    return hashlib.sha256(json.dumps({key: config[key] for key in ("team_id", "device_id", "bundle_id")}, sort_keys=True).encode()).hexdigest()


def run(config, force=False, status_only=False, renew_now=False):
    binding = config_binding(config)
    state_path = LOCAL / "signing-status.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if not isinstance(state, dict):
        raise ValueError("The successful-install record is malformed.")
    pending_path = LOCAL / "signing-pending.json"
    pending = json.loads(pending_path.read_text()) if pending_path.exists() else None
    if pending is not None and (not isinstance(pending, dict) or pending.get("binding") != binding):
        raise ValueError("The pending installation belongs to a different signing configuration.")
    # A fresh build is not evidence that the phone received it. Only the successful install record
    # can defer renewal; an interrupted/failed install must be retried on the next run.
    old_expiration = None
    if state.get("status") == "installed" and state.get("binding") == binding:
        try:
            old_expiration = aware(dt.datetime.fromisoformat(state.get("expires_at")))
        except (TypeError, ValueError) as error:
            raise ValueError("The successful-install expiration is malformed.") from error
    pending_source = pending.get("source_id") if pending else None
    if pending is not None and not pending_source:
        raise ValueError("The pending installation has no source snapshot.")
    due = renewal_due(old_expiration, now(), config.get("renew_before_hours", 48))
    # An interrupted update is retried promptly, using the latest project source at that attempt.
    pending_update = pending_source is not None and pending_source != state.get("source_id")
    due = due or pending_update
    if status_only or (not force and not renew_now and not due):
        result = {"status": "renewal_due" if due else "valid",
                  "expires_at": old_expiration.isoformat() if old_expiration else None}
        print(json.dumps(result))
        return result

    current = installed_version(config)
    candidate = project_version(ROOT)
    # Check before advancing the build number: stale source must not be relabelled to appear newer.
    require_current_build(candidate, current)
    source_id, source_root = capture_snapshot(ROOT, LOCAL)
    changed = state.get("binding") != binding or source_id != state.get("source_id")
    if current is not None and version_key(candidate) == version_key(current) and (force or changed):
        print("Building latest source as build " + bump_project_build(ROOT))
        source_id, source_root = capture_snapshot(ROOT, LOCAL)
    require_current_build(project_version(source_root), installed_version(config))
    build_root = build_dir_for_source(source_id)
    app = build_root / "Build/Products" / (config.get("configuration", "Debug") + "-iphoneos/Sill.app")
    # No shell interpolation: even paths containing spaces and a Chinese checkout name are safe.
    log = LOCAL / "signing-build.log"
    with log.open("ab") as output:
        subprocess.run(build_command(config, source_root, build_root), stdout=output, stderr=subprocess.STDOUT, check=True, timeout=1800)
    # Detect mutation of this attempt's snapshot during an Xcode build before any install.
    validate_snapshot(LOCAL, source_id)
    expiration = profile_expiration(read_profile(app), config)
    needs_refresh = renewal_due(expiration, now(), config.get("renew_before_hours", 48))
    if old_expiration is not None and expiration <= old_expiration:
        needs_refresh = True
    if not force and needs_refresh:
        # Xcode can reuse an eligible cached profile. Prefer the documented, app-scoped cache
        # refresh and a clean build over an archive/export when matching profiles are present.
        if matching_cached_profiles(config):
            return fresh_signed_build(config, source_root, source_id, log, old_expiration, force, binding,
                                      require_hidden=True)
        # With no app-scoped cached profile, automatic export is still allowed to request one.
        with tempfile.TemporaryDirectory(prefix="duodesk-renew-export-", dir=LOCAL) as directory:
            exported = export_refreshed_app(config, Path(directory), log, source_root, build_root)
            refreshed = profile_expiration(read_profile(exported), config)
            validate_snapshot(LOCAL, source_id)
            if (refreshed > now() + dt.timedelta(hours=config.get("renew_before_hours", 48))
                and (old_expiration is None or refreshed > old_expiration)):
                try:
                    return install_verified_app(exported, config, refreshed, old_expiration, force, binding, log, source_id)
                except InvalidSignedBundle:
                    return fresh_signed_build(config, source_root, source_id, log, old_expiration, force, binding,
                                              keep_at_or_after=refreshed)
        raise RuntimeError("The profile was not extended and no fresh profile was available from the matching cache.")
    try:
        return install_verified_app(app, config, expiration, old_expiration, force, binding, log, source_id)
    except InvalidSignedBundle:
        # A reused build directory can copy a newly issued profile without re-signing the bundle.
        # Keep that profile available and build afresh; never install the invalid product.
        return fresh_signed_build(config, source_root, source_id, log, old_expiration, force, binding,
                                  keep_at_or_after=expiration)


def observed_device(document, device_id):
    """Return a paired physical target's current connection, or None for an unreadable result."""
    if not isinstance(document, dict) or not isinstance(document.get("result"), dict):
        return None
    devices = document["result"].get("devices")
    if not isinstance(devices, list):
        return None
    matches = []
    for device in devices:
        if not isinstance(device, dict):
            return None
        properties = device.get("properties") if isinstance(device.get("properties"), dict) else {}
        hardware = properties.get("hardware") if isinstance(properties.get("hardware"), dict) else {}
        legacy_hardware = device.get("hardwareProperties") if isinstance(device.get("hardwareProperties"), dict) else {}
        if (hardware.get("udid") or legacy_hardware.get("udid")) == device_id:
            matches.append((device, properties, hardware, legacy_hardware))
    if not matches:
        return {"connected": False}
    if len(matches) != 1:
        return None
    device, properties, hardware, legacy_hardware = matches[0]
    reality = hardware.get("reality") or legacy_hardware.get("reality")
    if reality != "physical":
        return None
    connection = properties.get("connection") if isinstance(properties.get("connection"), dict) else {}
    legacy = device.get("connectionProperties") if isinstance(device.get("connectionProperties"), dict) else {}
    state = connection.get("state") or legacy.get("tunnelState")
    pairing = connection.get("pairingState") or legacy.get("pairingState")
    if not isinstance(state, str) or not isinstance(pairing, str):
        return None
    if state not in {"connected", "available", "disconnected", "unavailable"}:
        return None
    # CoreDevice reports an available, paired phone as "disconnected" until a developer
    # tunnel opens. Its connect capability distinguishes this from an offline phone.
    capabilities = device.get("capabilities", [])
    can_connect = isinstance(capabilities, list) and any(
        isinstance(item, dict) and item.get("featureIdentifier") == "com.apple.coredevice.feature.connectdevice"
        for item in capabilities)
    connected = pairing == "paired" and (state in {"connected", "available"} or (state == "disconnected" and can_connect))
    result = {"connected": connected}
    if connected:
        transport = connection.get("transportType") or legacy.get("transportType")
        stamp = connection.get("lastConnectionDate") or legacy.get("lastConnectionDate")
        if isinstance(transport, str):
            result["transport"] = transport
        if isinstance(stamp, (str, int, float)) and not isinstance(stamp, bool):
            result["connection_date"] = stamp
    return result


def probe_device(device_id):
    """Only inspect CoreDevice's local JSON; identifiers and network addresses stay in memory."""
    try:
        output = subprocess.run(["/usr/bin/xcrun", "devicectl", "list", "devices", "--json-output", "-",
                                 "--timeout", "5"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, check=True, timeout=8)
        return observed_device(json.loads(output.stdout), device_id)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def monitor(config, requested=False):
    """Check presence cheaply; only a daily deadline or a new connection attempts renewal."""
    path = LOCAL / "signing-monitor.json"
    state = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(state, dict):
        raise ValueError("The renewal monitor record is malformed.")
    binding = config_binding(config)
    if state.get("binding") != binding:
        state = {"binding": binding}
    before = dict(state)
    observation = probe_device(config["device_id"])
    if observation is None:
        state["probe"] = "unavailable"
        if state != before:
            atomic_json(path, state)
        return {"status": "device_probe_unavailable"}
    state["probe"] = "ok"
    current = now()
    last_attempt = None
    if state.get("last_attempt_at") is not None:
        try:
            last_attempt = aware(dt.datetime.fromisoformat(state["last_attempt_at"]))
        except (TypeError, ValueError) as error:
            raise ValueError("The renewal monitor timestamp is malformed.") from error
    connected = observation["connected"]
    connection_reason = "connected" if connected and state.get("connected") is not True else None
    if connected and state.get("connected") is True:
        # CoreDevice's lastConnectionDate can also advance when our own signing job talks to the
        # device. Treating that as a reconnect can cause repeated signing while it stays connected.
        if (observation.get("transport") is not None and state.get("transport") is not None
            and observation["transport"] != state["transport"]):
            connection_reason = "changed_transport"
    interval = config.get("renew_interval_hours", DEFAULT_RENEW_INTERVAL_HOURS)
    # When an attempt failed near expiry, retry sooner than a day while the phone remains reachable.
    if state.get("last_result") in {"failed", "running"}:
        installed_path = LOCAL / "signing-status.json"
        installed = json.loads(installed_path.read_text()) if installed_path.exists() else {}
        if not isinstance(installed, dict):
            raise ValueError("The successful-install record is malformed.")
        try:
            expiration = aware(dt.datetime.fromisoformat(installed.get("expires_at")))
        except (TypeError, ValueError):
            expiration = None
        if installed.get("binding") == binding and renewal_due(expiration, current, config.get("renew_before_hours", 48)):
            interval = min(interval, EXPIRY_RETRY_HOURS)
    daily_due = last_attempt is None or last_attempt > current or current - last_attempt >= dt.timedelta(hours=interval)
    # The CLI holds the signing lock around this function, so a previous "running" attempt has
    # ended. A pending install can also be left by a manually interrupted --force operation.
    # Retry it once promptly; if the recovery itself is interrupted, retain the usual schedule
    # rather than starting a new Xcode build on every one-minute probe.
    last_result, last_trigger = state.get("last_result"), state.get("last_trigger")
    pending_recovery = (LOCAL / "signing-pending.json").exists() and (
        last_result in {None, "installed"} or (last_result == "running" and last_trigger != "interrupted"))
    state["connected"] = connected
    if connected:
        for key in ("connection_date", "transport"):
            if observation.get(key) is not None:
                state[key] = observation[key]
    else:
        state.pop("connection_date", None)
        state.pop("transport", None)
    if not connected or not (connection_reason or daily_due or requested or pending_recovery):
        if state != before:
            atomic_json(path, state)
        return {"status": "waiting_for_device" if not connected else "waiting_for_schedule"}
    state["last_attempt_at"] = current.isoformat()
    state["last_result"] = "running"
    state["last_trigger"] = "manual" if requested else (connection_reason or ("interrupted" if pending_recovery else "daily"))
    atomic_json(path, state)
    try:
        # Both manual and automatic attempts capture the latest project source afresh.
        result = run(config, renew_now=True)
    except StaleDeviceBuild as error:
        state["last_result"] = "superseded"
        state["last_completed_at"] = now().isoformat()
        atomic_json(path, state)
        result = {"status": "newer_version_installed", "message": str(error)}
        print(json.dumps(result))
        return result
    except Exception:
        state["last_result"] = "failed"
        state["last_completed_at"] = now().isoformat()
        atomic_json(path, state)
        raise
    state["last_result"] = "installed"
    state["last_completed_at"] = now().isoformat()
    atomic_json(path, state)
    return result


def agent_plist(config_path):
    agent = {"Label": LABEL,
             "ProgramArguments": [sys.executable, str(Path(__file__).resolve()), "--config", str(config_path.resolve()), "--monitor"],
             "WorkingDirectory": str(ROOT), "StartInterval": MONITOR_INTERVAL_SECONDS, "RunAtLoad": True,
             "StandardOutPath": str(LOCAL / "renewal.log"), "StandardErrorPath": str(LOCAL / "renewal-error.log"),
             "ProcessType": "Background"}
    # launchd doesn't inherit the shell's selected Xcode. Preserve only this nonsecret override,
    # not the account or other environment; without it, use the system-selected developer dir.
    if os.environ.get("DEVELOPER_DIR"):
        agent["EnvironmentVariables"] = {"DEVELOPER_DIR": os.environ["DEVELOPER_DIR"]}
    return agent


def atomic_agent_write(target, data):
    fd, temporary = tempfile.mkstemp(prefix=".duodesk-renew-", dir=target.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def enable_agent(config_path):
    # Explicit opt-in only. Updating an existing agent keeps a rollback copy of its plist in memory.
    target = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    target.parent.mkdir(parents=True, exist_ok=True)
    previous = target.read_bytes() if target.exists() else None
    domain = "gui/" + str(os.getuid())
    service = domain + "/" + LABEL
    loaded = subprocess.run(["/bin/launchctl", "print", service], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, check=False).returncode == 0
    if loaded and previous is None:
        raise ValueError("The existing renewal agent has no plist to restore; it was left unchanged.")
    if loaded:
        subprocess.run(["/bin/launchctl", "bootout", service], check=True)
    try:
        atomic_agent_write(target, plistlib.dumps(agent_plist(config_path)))
        subprocess.run(["/bin/launchctl", "bootstrap", domain, str(target)], check=True)
    except (OSError, subprocess.SubprocessError):
        if previous is None:
            target.unlink(missing_ok=True)
        else:
            atomic_agent_write(target, previous)
            if loaded:
                try:
                    subprocess.run(["/bin/launchctl", "bootstrap", domain, str(target)], check=True)
                except subprocess.SubprocessError as error:
                    raise RuntimeError("The previous renewal plist was restored, but its agent did not restart.") from error
        raise
    print("Renewal enabled for this Mac login: daily and after a device reconnect.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=LOCAL / "signing.json")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--status", action="store_true")
    action.add_argument("--force", action="store_true")
    action.add_argument("--monitor", action="store_true", help=argparse.SUPPRESS)
    action.add_argument("--renew-now", action="store_true", help="Build the latest project source and attempt renewal now.")
    action.add_argument("--enable-auto", action="store_true")
    action.add_argument("--disable-auto", action="store_true")
    args = parser.parse_args()
    LOCAL.mkdir(parents=True, exist_ok=True, mode=0o700)
    if LOCAL.stat().st_mode & 0o777 != 0o700:
        os.chmod(LOCAL, 0o700)
    if args.disable_auto:
        with (LOCAL / "signing.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError("A signing job is running; the renewal agent was left enabled.") from error
            if (LOCAL / "signing-profile-active.json").exists():
                recover_profile_cache(load_config(args.config))
            target = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
            if target.exists():
                subprocess.run(["/bin/launchctl", "bootout", "gui/" + str(os.getuid()), str(target)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                target.unlink()
        print("Renewal disabled. The app, profile, and signing keys remain intact.")
        return
    with (LOCAL / "signing.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("A signing job is already running; no additional job was started.", file=sys.stderr)
            if args.monitor:
                return
            raise SystemExit(75)
        config = load_config(args.config)
        if not args.status:
            recover_profile_cache(config)
        if args.enable_auto:
            enable_agent(args.config)
        elif args.monitor:
            monitor(config)
        elif args.renew_now:
            result = monitor(config, requested=True)
            if result.get("status") == "newer_version_installed":
                raise SystemExit(75)
            if result.get("status") in {"waiting_for_device", "device_probe_unavailable"}:
                print(json.dumps(result))
                raise SystemExit(75)
        else:
            run(config, force=args.force, status_only=args.status)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        # A failure is not an installation: retain the last successful expiry so retries cannot
        # silently replace it with an older profile. Details stay in a separate ignored file.
        atomic_json(LOCAL / "signing-error.json", {"status": "failed", "checked_at": now().isoformat(), "reason": str(error)})
        print(str(error), file=sys.stderr)
        print("Signing could not finish. See Local/signing-error.json and Local/signing-build.log.", file=sys.stderr)
        sys.exit(1)
