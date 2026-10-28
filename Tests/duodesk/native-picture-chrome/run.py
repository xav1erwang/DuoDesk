#!/usr/bin/env python3
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
"""Run the production picture modifier in a separate synthetic iOS simulator app."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import time
import uuid

root = Path(__file__).resolve().parents[3]
if len(sys.argv) != 4:
    raise SystemExit('usage: run.py SIMULATOR_UDID NEW_OUTPUT_DIRECTORY DISPLAY (for example primary or primary-1)')
device, output, display = sys.argv[1], Path(sys.argv[2]).absolute(), sys.argv[3]
output.mkdir(parents=True, exist_ok=False)
app = output / 'NativePictureChromeFixture.app'
app.mkdir()
bundle = 'com.duodesk.tests.NativePictureChrome'
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
env = dict(os.environ, SDKROOT=sdk)
subprocess.run(['xcrun', 'swiftc', '-O', '-sdk', sdk, '-target', 'arm64-apple-ios27.1-simulator',
                str(root / 'iOSClient/DesktopPictureChrome.swift'), str(root / 'Tests/duodesk/native-picture-chrome/Fixture.swift'),
                '-o', str(app / 'Fixture')], env=env, check=True)
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'Fixture', 'CFBundleName': 'Native Picture Fixture',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'CFBundleDevelopmentRegion': 'en', 'MinimumOSVersion': '27.1', 'UIDeviceFamily': [1, 2],
    'UILaunchScreen': {}, 'CFBundleSupportedPlatforms': ['iPhoneSimulator'], 'DTPlatformName': 'iphonesimulator',
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}}))
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True)
subprocess.run(['xcrun', 'simctl', 'install', device, str(app)], check=True)
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', device, bundle, 'data'], text=True).strip())
run_id = uuid.uuid4().hex
launch_env = dict(os.environ, SIMCTL_CHILD_NATIVE_FRAME_RUN_ID=run_id)
subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', device, bundle], env=launch_env, check=True)
try:
    report = None
    for _ in range(100):
        result = container / 'Documents/result.json'
        if result.exists():
            candidate = json.loads(result.read_text())
            if candidate.get('runID') == run_id:
                report = candidate
                break
        time.sleep(0.2)
    if report is None:
        raise RuntimeError('fixture did not write a fresh result')
    for name in ['result.json', 'reference.png', 'native.png', 'legacy.png']:
        shutil.copyfile(container / 'Documents' / name, output / name)
    # The report can be ready before the scene's first presentation reaches the framebuffer.
    time.sleep(1)
    subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot', '--display=' + display,
                    str(output / 'simulator.png')], check=True)
    header = (output / 'simulator.png').read_bytes()[:24]
    if header[:8] != b'\x89PNG\r\n\x1a\n' or header[12:16] != b'IHDR':
        raise RuntimeError('simulator screenshot is not PNG')
    screenshot_size = struct.unpack('>II', header[16:24])
    if sorted(screenshot_size) != sorted(report['sceneNativePixels']):
        raise RuntimeError(f'screenshot is from {screenshot_size}, fixture scene is on {report["sceneNativePixels"]}')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if not report['passed']:
        raise SystemExit(1)
finally:
    subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['xcrun', 'simctl', 'uninstall', device, bundle], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
