#!/usr/bin/env python3
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
"""Build the actual iOS target sources with an owned UIKit test entry point instead of SillApp."""
import json
import os
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parents[3]
os.chdir(root)
out = root / '.build/duodesk-input-owner-probe'
app = out / 'DUO Input Owner Checks.app'
app.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
env = dict(os.environ, SDKROOT=sdk)
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', 'iOSClient/Sill.xcodeproj/project.pbxproj']))
objects = project['objects']
targets = [obj for obj in objects.values() if obj['isa'] == 'PBXNativeTarget' and obj['name'] == 'Sill']
assert len(targets) == 1
sources = []
for phase_id in targets[0]['buildPhases']:
    phase = objects[phase_id]
    if phase['isa'] != 'PBXSourcesBuildPhase':
        continue
    for file_id in phase['files']:
        ref = objects[objects[file_id]['fileRef']]
        path = (root / 'iOSClient' / ref['path']).resolve()
        assert path.is_file(), path
        if path.name != 'SillApp.swift':
            sources.append(str(path))
assert any(Path(p).name == 'InputOverlay.swift' for p in sources)
assert any(Path(p).name == 'StreamTextInputView.swift' for p in sources)
(out / 'production-sources.json').write_text(json.dumps(sources, ensure_ascii=False, indent=2) + '\n')
common = ['swiftc', '-O', '-D', 'DEBUG', '-sdk', sdk, '-target', 'arm64-apple-ios27.1-simulator']
subprocess.run(common + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
    *map(str, sorted((root / 'Sources/StreamProtocol').glob('*.swift'))),
    '-emit-module-path', str(out / 'StreamProtocol.swiftmodule'),
    '-Xlinker', '-install_name', '-Xlinker', '@rpath/libStreamProtocol.dylib',
    '-o', str(app / 'libStreamProtocol.dylib')], env=env, check=True)
subprocess.run(common + ['-I', str(out), '-L', str(app), '-lStreamProtocol',
    '-Xlinker', '-rpath', '-Xlinker', '@executable_path', *sources,
    str(root / 'Tests/duodesk/input-owner-probe/ProbeApp.swift'), '-o', str(app / 'Probe')], env=env, check=True)
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.duodesk.tests.InputOwner', 'CFBundleExecutable': 'Probe',
    'CFBundleName': 'DUO Input Owner Checks', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'CFBundleDevelopmentRegion': 'en',
    'MinimumOSVersion': '27.1', 'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
    'CFBundleSupportedPlatforms': ['iPhoneSimulator'], 'DTPlatformName': 'iphonesimulator',
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}}))
for path in [app / 'libStreamProtocol.dylib', app]:
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(path)], check=True)
print(f'Built {len(sources)} actual production sources: {app}')
