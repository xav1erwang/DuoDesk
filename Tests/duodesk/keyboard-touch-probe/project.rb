#!/usr/bin/env ruby
# Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
require 'fileutils'
require 'xcodeproj'

root = File.expand_path('../../..', __dir__)
output = File.join(root, '.build/duodesk-keyboard-touch-ui')
FileUtils.mkdir_p(output)
path = File.join(output, 'KeyboardTouch.xcodeproj')
project = Xcodeproj::Project.new(path)
app = project.new_target(:application, 'KeyboardTouchFixture', :ios, '27.1')
framework = project.new_target(:framework, 'StreamProtocol', :ios, '27.1')
tests = project.new_target(:ui_test_bundle, 'KeyboardTouchUITests', :ios, '27.1')

def add_sources(project, target, files)
  files.each do |path|
    ref = project.main_group.new_file(path)
    target.source_build_phase.add_file_reference(ref)
  end
end

add_sources(project, framework, Dir[File.join(root, 'Sources/StreamProtocol/*.swift')].sort)
add_sources(project, app, %w[KeyChords.swift DuoControlModel.swift DuoControlDeck.swift].map { |name|
  File.join(root, 'iOSClient', name)
} + [File.join(__dir__, 'ProbeApp.swift')])
add_sources(project, tests, [File.join(__dir__, 'KeyboardTouchUITests.swift')])
app.add_dependency(framework)
app.frameworks_build_phase.add_file_reference(framework.product_reference)
embed = app.new_copy_files_build_phase('Embed Frameworks')
embed.dst_subfolder_spec = '10'
embed.add_file_reference(framework.product_reference).settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }
tests.add_dependency(app)

[app, framework, tests].each do |target|
  target.build_configurations.each do |config|
    config.build_settings.merge!(
      'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'CODE_SIGN_IDENTITY' => '-', 'SUPPORTED_PLATFORMS' => 'iphonesimulator',
      'TARGETED_DEVICE_FAMILY' => '1,2', 'IPHONEOS_DEPLOYMENT_TARGET' => '27.1'
    )
  end
end
app.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.duodesk.tests.KeyboardTouchUI',
    'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
    'INFOPLIST_KEY_UIApplicationSceneManifest_Generation' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks']
  )
end
framework.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.duodesk.tests.KeyboardTouchProtocol'
  config.build_settings['DEFINES_MODULE'] = 'YES'
end
tests.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.duodesk.tests.KeyboardTouchUITests'
  config.build_settings['TEST_TARGET_NAME'] = app.name
end

project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(path, 'KeyboardTouch')
puts path
