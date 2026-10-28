#!/usr/bin/env python3
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
"""Generate a disposable Touch Bar view fixture; copied sources use a black video stub and no network."""
import hashlib
import json
import sys
import shutil
from pathlib import Path

root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]).absolute() if len(sys.argv) == 2 else root / '.build/duodesk-touchbar-view-fixture'
out.mkdir(parents=True, exist_ok=False)
fixtures = root / 'Tests/duodesk/touch-bar-view'
for name in ['FixtureApp.swift', 'InitialUITests.swift', 'HEVCDisplayViewStub.swift']:
    shutil.copyfile(fixtures / name, out / name)
for name in ['TouchBar.swift', 'StreamMessage.swift']:
    shutil.copyfile(root / 'Sources/StreamProtocol' / name, out / name)
for name in ['DuoTouchBarTouchView.swift', 'DuoTouchBarRemoteView.swift']:
    source = (root / 'iOSClient' / name).read_text()
    assert source.count('import StreamProtocol\n') == 1
    (out / name).write_text(source.replace('import StreamProtocol\n', ''))
shutil.copyfile(root / 'iOSClient/TouchBarPictureChrome.swift', out / 'TouchBarPictureChrome.swift')
project = out / 'SystemKeyboard.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
objects = {}

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def obj(key_name, isa, **fields):
    key = ident(key_name)
    objects[key] = dict(isa=isa, **fields)
    return key

def sources(name, paths):
    refs = [obj(name + path.name, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=str(path), sourceTree='<absolute>') for path in paths]
    files = [obj(name + ref, 'PBXBuildFile', fileRef=ref) for ref in refs]
    return obj(name + 'Sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0), refs

def configs(name, extra):
    ids = []
    for variant in ['Debug', 'Release']:
        settings = dict(SDKROOT='iphonesimulator', IPHONEOS_DEPLOYMENT_TARGET='27.1', SWIFT_VERSION='5.0',
            ALWAYS_SEARCH_USER_PATHS='NO',
            CODE_SIGN_IDENTITY='-', CODE_SIGNING_ALLOWED='YES', SUPPORTED_PLATFORMS='iphonesimulator',
            TARGETED_DEVICE_FAMILY='1,2', GENERATE_INFOPLIST_FILE='YES', PRODUCT_NAME='$(TARGET_NAME)',
            SWIFT_OPTIMIZATION_LEVEL='-Onone' if variant == 'Debug' else '-O', **extra)
        ids.append(obj(name + variant, 'XCBuildConfiguration', name=variant, buildSettings=settings))
    return obj(name + 'Configurations', 'XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')

app_phase, app_refs = sources('App', [out / 'FixtureApp.swift', out / 'TouchBar.swift', out / 'StreamMessage.swift', out / 'DuoTouchBarTouchView.swift', out / 'DuoTouchBarRemoteView.swift', out / 'TouchBarPictureChrome.swift', out / 'HEVCDisplayViewStub.swift'])
test_phase, test_refs = sources('Test', [out / 'InitialUITests.swift'])
app_product = obj('AppProduct', 'PBXFileReference', explicitFileType='wrapper.application', path='InputSystemFixture.app', sourceTree='BUILT_PRODUCTS_DIR')
test_product = obj('TestProduct', 'PBXFileReference', explicitFileType='wrapper.cfbundle', path='KeyboardUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
app_config = configs('App', {'PRODUCT_BUNDLE_IDENTIFIER': 'com.duodesk.tests.InitialUIHarness', 'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES'})
test_config = configs('Test', {'PRODUCT_BUNDLE_IDENTIFIER': 'com.duodesk.tests.InitialUIUITests', 'TEST_TARGET_NAME': 'InputSystemFixture', 'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']})
app_target = obj('AppTarget', 'PBXNativeTarget', name='InputSystemFixture', productName='InputSystemFixture', productReference=app_product, productType='com.apple.product-type.application', buildConfigurationList=app_config, buildPhases=[app_phase], buildRules=[], dependencies=[])
proxy = obj('AppProxy', 'PBXContainerItemProxy', containerPortal=ident('Project'), proxyType=1, remoteGlobalIDString=app_target, remoteInfo='InputSystemFixture')
dep = obj('AppDependency', 'PBXTargetDependency', target=app_target, targetProxy=proxy)
test_target = obj('TestTarget', 'PBXNativeTarget', name='KeyboardUITests', productName='KeyboardUITests', productReference=test_product, productType='com.apple.product-type.bundle.ui-testing', buildConfigurationList=test_config, buildPhases=[test_phase], buildRules=[], dependencies=[dep])
products = obj('Products', 'PBXGroup', children=[app_product, test_product], name='Products', sourceTree='<group>')
group = obj('RootGroup', 'PBXGroup', children=app_refs + test_refs + [products], sourceTree='<group>')
project_config = configs('Project', {})
project_id = obj('Project', 'PBXProject', attributes={'LastUpgradeCheck': '2710'}, buildConfigurationList=project_config, compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en', 'Base'], mainGroup=group, productRefGroup=products, projectDirPath='', projectRoot='', targets=[app_target, test_target])

def encode(value):
    if isinstance(value, dict):
        return '{\n' + ''.join(json.dumps(k) + ' = ' + encode(v) + ';\n' for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '(' + ','.join(encode(v) for v in value) + ')'
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)

(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project_id)) + '\n')
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'SystemKeyboard.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="InputSystemFixture.app" BlueprintName="InputSystemFixture" ReferencedContainer="container:SystemKeyboard.xcodeproj"/></BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
    <TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="KeyboardUITests.xctest" BlueprintName="KeyboardUITests" ReferencedContainer="container:SystemKeyboard.xcodeproj"/></TestableReference>
  </Testables></TestAction>
</Scheme>''')
print(project)
