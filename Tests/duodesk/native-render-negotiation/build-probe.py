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
if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in ('--launch-only', '--transition-only', '--legacy-order-only', '--terminal-goodbye-only', '--physical-fallback-only', '--fullscreen-mirror-only')):
    raise SystemExit('usage: build-probe.py NEW_OUTPUT_DIRECTORY [--launch-only|--transition-only|--legacy-order-only|--terminal-goodbye-only|--physical-fallback-only|--fullscreen-mirror-only]')
transition_only = len(sys.argv) == 3 and sys.argv[2] == '--transition-only'
launch_only = len(sys.argv) == 3 and sys.argv[2] == '--launch-only'
legacy_order_only = len(sys.argv) == 3 and sys.argv[2] == '--legacy-order-only'
terminal_goodbye_only = len(sys.argv) == 3 and sys.argv[2] == '--terminal-goodbye-only'
physical_fallback_only = len(sys.argv) == 3 and sys.argv[2] == '--physical-fallback-only'
fullscreen_mirror_only = len(sys.argv) == 3 and sys.argv[2] == '--fullscreen-mirror-only'
out = Path(sys.argv[1]).absolute()
out.mkdir(parents=True, exist_ok=False)
app = out / 'Native Render Probe.app'
app.mkdir()
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
assert any(Path(path).name == 'StreamClient.swift' for path in sources)
(out / 'production-sources.json').write_text(json.dumps(sources, ensure_ascii=False, indent=2) + '\n')
common = ['swiftc', '-Onone', '-D', 'DEBUG', '-D', 'DUO_NATIVE_SIZING_TESTING',
          '-sdk', sdk, '-target', 'arm64-apple-ios27.1-simulator']
if launch_only:
    common += ['-D', 'DUO_LAUNCH_ORDER_TESTING']
if transition_only:
    common += ['-D', 'DUO_EXTENSION_TRANSITION_TESTING']
if legacy_order_only:
    common += ['-D', 'DUO_LEGACY_ORDER_TESTING']
if terminal_goodbye_only:
    common += ['-D', 'DUO_TERMINAL_GOODBYE_TESTING']
if physical_fallback_only:
    common += ['-D', 'DUO_PHYSICAL_FALLBACK_TESTING']
if fullscreen_mirror_only:
    common += ['-D', 'DUO_FULLSCREEN_MIRROR_TESTING']
subprocess.run(common + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
    *map(str, sorted((root / 'Sources/StreamProtocol').glob('*.swift'))),
    '-emit-module-path', str(out / 'StreamProtocol.swiftmodule'),
    '-Xlinker', '-install_name', '-Xlinker', '@rpath/libStreamProtocol.dylib',
    '-o', str(app / 'libStreamProtocol.dylib')], env=env, check=True)
subprocess.run(common + ['-I', str(out), '-L', str(app), '-lStreamProtocol',
    '-Xlinker', '-rpath', '-Xlinker', '@executable_path', *sources,
    str(root / 'Tests/duodesk/native-render-negotiation/ProbeApp.swift'), '-o', str(app / 'Probe')], env=env, check=True)
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': ('com.duodesk.tests.NativeLaunchOrder' if launch_only else
                           'com.duodesk.tests.ExtensionTransition' if transition_only else
                           'com.duodesk.tests.LegacyViewportOrder' if legacy_order_only else
                           'com.duodesk.tests.TerminalGoodbye' if terminal_goodbye_only else
                           'com.duodesk.tests.PhysicalFallback' if physical_fallback_only else
                           'com.duodesk.tests.FullscreenMirror' if fullscreen_mirror_only else
                           'com.duodesk.tests.NativeRenderNegotiation'),
    'CFBundleExecutable': 'Probe',
    'CFBundleName': 'Native Render Probe', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'CFBundleDevelopmentRegion': 'en',
    'MinimumOSVersion': '27.1', 'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
    'CFBundleSupportedPlatforms': ['iPhoneSimulator'], 'DTPlatformName': 'iphonesimulator',
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}}))
for path in [app / 'libStreamProtocol.dylib', app]:
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(path)], check=True)
print(f'Built {len(sources)} production sources: {app}', flush=True)
