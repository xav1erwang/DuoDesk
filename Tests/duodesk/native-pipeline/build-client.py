#!/usr/bin/env python3
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
"""Build the real iOS sources with a test-only loopback entry point."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
os.chdir(root)
if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--device'):
    raise SystemExit('usage: build-client.py NEW_OUTPUT_DIRECTORY [--device]')
device = len(sys.argv) == 3
out = Path(sys.argv[1]).absolute()
out.mkdir(parents=True, exist_ok=False)
app = out / 'Native Pipeline.app'
app.mkdir()
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos' if device else 'iphonesimulator', '--show-sdk-path'], text=True).strip()
env = dict(os.environ, SDKROOT=sdk)
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', 'iOSClient/Sill.xcodeproj/project.pbxproj']))
objects = project['objects']
target = next(obj for obj in objects.values() if obj['isa'] == 'PBXNativeTarget' and obj['name'] == 'Sill')
sources = []
for phase_id in target['buildPhases']:
    phase = objects[phase_id]
    if phase['isa'] == 'PBXSourcesBuildPhase':
        for file_id in phase['files']:
            ref = objects[objects[file_id]['fileRef']]
            if ref['path'] != 'SillApp.swift':
                sources.append(str(root / 'iOSClient' / ref['path']))
common = ['swiftc', '-Onone', '-D', 'DEBUG', '-sdk', sdk, '-target', 'arm64-apple-ios27.1' + ('' if device else '-simulator')]
library = out / 'libStreamProtocol.a' if device else app / 'libStreamProtocol.dylib'
subprocess.run(common + ['-emit-library', *(['-static'] if device else []), '-emit-module', '-module-name', 'StreamProtocol',
    *map(str, sorted((root / 'Sources/StreamProtocol').glob('*.swift'))),
    '-emit-module-path', str(out / 'StreamProtocol.swiftmodule'),
    *([] if device else ['-Xlinker', '-install_name', '-Xlinker', '@rpath/libStreamProtocol.dylib']),
    '-o', str(library)], env=env, check=True)
subprocess.run(common + ['-I', str(out), '-L', str(out if device else app), '-lStreamProtocol',
    '-Xlinker', '-rpath', '-Xlinker', '@executable_path', *sources,
    str(root / 'Tests/duodesk/native-pipeline/ClientProbe.swift'), '-o', str(app / 'Probe')], env=env, check=True)
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.duodesk.client' if device else 'com.duodesk.tests.NativePipeline', 'CFBundleExecutable': 'Probe',
    'CFBundleName': 'Native Pipeline', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'CFBundleDevelopmentRegion': 'en',
    'MinimumOSVersion': '27.1', 'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
    'NSBonjourServices': ['_sill._tcp'], 'NSLocalNetworkUsageDescription': '验证已配对 Mac 的真实串流管线。',
    'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
    'CFBundleSupportedPlatforms': ['iPhoneOS' if device else 'iPhoneSimulator'], 'DTPlatformName': 'iphoneos' if device else 'iphonesimulator',
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}}))
if not device:
    for path in [app / 'libStreamProtocol.dylib', app]:
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(path)], check=True)
print(f'Built {len(sources)} production sources: {app}', flush=True)
