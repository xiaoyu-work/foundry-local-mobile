# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

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

  s.platform         = :osx, '10.15'
  s.osx.deployment_target = '10.15'
  s.swift_version    = '5.9'

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  core_root          = '../../../core'
  bridge_root        = '../src'

  s.preserve_paths   = [
    "#{core_root}/**/*",
    "#{bridge_root}/**/*"
  ]

  s.source_files    += [
    "#{core_root}/src/**/*.{cc,cpp}",
    "#{bridge_root}/*.{c,h}"
  ]

  s.exclude_files    = [
    "#{core_root}/src/platform/device_profile_android.cc",
    # Desktop-only path is fine on macOS; keep it. Only Android must be excluded.
  ]

  s.public_header_files = [
    "#{core_root}/include/foundry_local_mobile/*.h",
    "#{bridge_root}/*.h"
  ]

  s.dependency 'FlutterMacOS'
  s.frameworks       = 'Foundation'

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
    'STRIP_INSTALLED_PRODUCT' => 'NO'
  }
end
