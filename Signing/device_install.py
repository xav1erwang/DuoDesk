#!/usr/bin/env python3
"""Read the phone's version before installing, then verify what the phone actually received."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


class StaleDeviceBuild(RuntimeError):
    pass


def version_key(version):
    release, build = version
    if not isinstance(release, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", release):
        raise ValueError("The app has no readable release version.")
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+){0,2})(?:(d|a|b|fc)([0-9]+))?", build) if isinstance(build, str) else None
    if match is None:
        raise ValueError("The app has no readable build version.")
    def numbers(value):
        parts = tuple(int(x) for x in value.split("."))
        return parts + (0,) * (3 - len(parts))
    stage = {"d": 0, "a": 1, "b": 2, "fc": 3, None: 4}[match[2]]
    return numbers(release), numbers(match[1]), stage, int(match[3] or 0)


def app_version(info):
    version = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
    version_key(version)
    return version


def project_version(root):
    project = Path(root) / "iOSClient/Sill.xcodeproj/project.pbxproj"
    source = project.read_text()
    values = []
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        found = set(re.findall(r"\b" + key + r'\s*=\s*"?([0-9.a-z]+)"?\s*;', source))
        if len(found) != 1:
            raise ValueError("Set one consistent " + key + " for the iOS target before installing.")
        values.append(found.pop())
    version = tuple(values)
    version_key(version)
    return version


def bump_project_build(root):
    _, build = project_version(root)
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+){0,2})(?:(d|a|b|fc)([0-9]+))?", build)
    if match[2]:
        following = match[1] + match[2] + str(int(match[3]) + 1)
    else:
        parts = build.split(".")
        parts[-1] = str(int(parts[-1]) + 1)
        following = ".".join(parts)
    project = Path(root) / "iOSClient/Sill.xcodeproj/project.pbxproj"
    source = project.read_text()
    updated, count = re.subn(r'(\bCURRENT_PROJECT_VERSION\s*=\s*)"?' + re.escape(build) + r'"?(\s*;)',
                             lambda m: m[1] + following + m[2], source)
    if count == 0:
        raise ValueError("The iOS build version could not be advanced.")
    project.write_text(updated)
    return following


def installed_version(config):
    with tempfile.TemporaryDirectory(prefix="duodesk-device-version-") as directory:
        output = Path(directory) / "apps.json"
        subprocess.run(["/usr/bin/xcrun", "devicectl", "device", "info", "apps", "--device", config["device_id"],
                        "--bundle-id", config["bundle_id"], "--json-output", str(output), "--timeout", "30"],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=45)
        result = json.loads(output.read_text()).get("result")
    if not isinstance(result, dict) or not isinstance(result.get("apps"), list):
        raise ValueError("The phone's installed app version could not be read.")
    apps = result["apps"]
    if not apps:
        return None
    if len(apps) != 1 or apps[0].get("bundleIdentifier") != config["bundle_id"]:
        raise ValueError("The phone returned an unexpected app for the version check.")
    version = apps[0].get("version"), apps[0].get("bundleVersion")
    version_key(version)
    return version


def require_current_build(candidate, installed):
    candidate_key = version_key(candidate)
    if installed is not None and candidate_key < version_key(installed):
        raise StaleDeviceBuild("The phone already has " + installed[0] + " (" + installed[1] + "); this Mac's "
                               + candidate[0] + " (" + candidate[1] + ") was not installed. Update this Mac's source first.")


def install_and_verify(app, config, log):
    info = plistlib.loads((Path(app) / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != config["bundle_id"]:
        raise ValueError("The built app identifier does not match the target app.")
    candidate = app_version(info)
    # A second check just before installation also covers a newer install during a long build.
    require_current_build(candidate, installed_version(config))
    with Path(log).open("ab") as output:
        subprocess.run(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device",
                        config["device_id"], str(app)], stdout=output, stderr=subprocess.STDOUT, check=True, timeout=180)
    actual = installed_version(config)
    if actual != candidate:
        raise RuntimeError("The phone did not report the expected app version after installation; no successful install was recorded.")
    return candidate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--bundle-id", required=True)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check-project", type=Path)
    action.add_argument("--app", type=Path)
    parser.add_argument("--log", type=Path)
    args = parser.parse_args()
    config = {"device_id": args.device, "bundle_id": args.bundle_id}
    if args.check_project is not None:
        require_current_build(project_version(args.check_project), installed_version(config))
    else:
        if args.log is None:
            parser.error("--app requires --log")
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.app)], check=True, timeout=30)
        version = install_and_verify(args.app, config, args.log)
        print("Verified installed " + version[0] + " (" + version[1] + ")")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
