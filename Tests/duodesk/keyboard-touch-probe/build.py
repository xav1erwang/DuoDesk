#!/usr/bin/env python3
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
"""Build a simulator fixture around the production control deck, with an in-memory input sink."""
import os
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parents[3]
out = root / '.build/duodesk-keyboard-touch-probe'
app = out / 'DUO Keyboard Touch Checks.app'
app.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
env = dict(os.environ, SDKROOT=sdk)
common = ['swiftc', '-swift-version', '5', '-sdk', sdk, '-target', 'arm64-apple-ios27.1-simulator']
subprocess.run(common + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
    *map(str, sorted((root / 'Sources/StreamProtocol').glob('*.swift'))),
    '-emit-module-path', str(out / 'StreamProtocol.swiftmodule'),
    '-Xlinker', '-install_name', '-Xlinker', '@rpath/libStreamProtocol.dylib',
    '-o', str(app / 'libStreamProtocol.dylib')], env=env, check=True)
subprocess.run(common + ['-I', str(out), '-L', str(app), '-lStreamProtocol',
    '-Xlinker', '-rpath', '-Xlinker', '@executable_path',
    *map(str, (root / 'iOSClient' / name for name in ['KeyChords.swift', 'DuoControlModel.swift', 'DuoControlDeck.swift'])),
    str(root / 'Tests/duodesk/keyboard-touch-probe/ProbeApp.swift'), '-o', str(app / 'Probe')], env=env, check=True)
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.duodesk.tests.KeyboardTouch', 'CFBundleExecutable': 'Probe',
    'CFBundleName': 'DUO Keyboard Touch Checks', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'CFBundleDevelopmentRegion': 'en',
    'MinimumOSVersion': '27.1', 'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
    'CFBundleSupportedPlatforms': ['iPhoneSimulator'], 'DTPlatformName': 'iphonesimulator',
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}}))
for path in [app / 'libStreamProtocol.dylib', app]:
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(path)], check=True)
print(app)
