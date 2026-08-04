# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# CocoaPods spec for the iOS Flutter plugin. This builds the C++ core from
# source and statically links it into the plugin, so all `flm_*` symbols end up
# in the app's main process image. Dart FFI then uses
# `DynamicLibrary.process()` to resolve them without opening a separate .dylib.

Pod::Spec.new do |s|
  s.name             = 'foundry_local_mobile'
  s.version          = '0.1.0'
  s.summary          = 'On-device AI for Flutter via Microsoft Foundry Local.'
  s.description      = <<-DESC
Flutter FFI plugin providing streaming chat, tool calling, speech-to-text and
embeddings on top of Microsoft Foundry Local's on-device ONNX Runtime GenAI.
                       DESC
  s.homepage         = 'https://github.com/microsoft/foundry-local-mobile'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Microsoft' => 'foundrylocal@microsoft.com' }

  s.platform         = :ios, '13.0'
  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.9'

  s.source           = { :path => '.' }

  # Swift + ObjC++ plugin sources.
  s.source_files     = 'Classes/**/*'

  # C++ core sources — kept as a monorepo relative reference; the .podspec is
  # consumed from bindings/flutter/ios, so ../../.. is the repo root.
  core_root          = '../../../core'
  bridge_root        = '../src'

  s.preserve_paths   = [
    "#{core_root}/**/*",
    "#{bridge_root}/**/*"
  ]

  s.source_files    += [
    "#{core_root}/src/**/*.{cc,cpp}",
    "#{core_root}/src/platform/device_profile_apple.cc",
    "#{bridge_root}/*.{c,h}"
  ]

  s.exclude_files    = [
    "#{core_root}/src/platform/device_profile_android.cc",
    "#{core_root}/src/platform/device_profile_desktop.cc"
  ]

  s.public_header_files = [
    "#{core_root}/include/foundry_local_mobile/*.h",
    "#{bridge_root}/*.h"
  ]

  s.dependency 'Flutter'
  s.frameworks       = 'Foundation'

  # nlohmann/json is a header-only dependency the C++ core relies on. The
  # simplest reproducible integration for a plugin build is to vendor a single
  # header at core/third_party/nlohmann and put it on the include path.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => [
      '"${PODS_TARGET_SRCROOT}/../../../core/include"',
      '"${PODS_TARGET_SRCROOT}/../../../core/src"',
      '"${PODS_TARGET_SRCROOT}/../../../core/third_party/nlohmann/include"',
      '"${PODS_TARGET_SRCROOT}/../../../third_party/foundry-local/include"',
      '"${PODS_TARGET_SRCROOT}/../src"'
    ].join(' '),
    'GCC_PREPROCESSOR_DEFINITIONS' => 'FLM_STATIC=1',
    # Keep the C ABI symbols; the Objective-C++ export unit
    # (FoundryLocalMobileExports.mm) is what actually stops the linker from
    # dropping them.
    'STRIP_INSTALLED_PRODUCT' => 'NO'
  }
end
