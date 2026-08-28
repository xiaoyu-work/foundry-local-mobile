# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# CocoaPods spec for the iOS Flutter plugin. This builds the C++ core from
# source and statically links it into the plugin, so all `flm_*` symbols end up
# in the app's main process image. Dart FFI then uses
# `DynamicLibrary.process()` to resolve them without opening a separate .dylib.

Pod::Spec.new do |s|
  s.name             = 'foundry_local_mobile'
  s.version          = '0.2.0'
  s.summary          = 'On-device AI for Flutter via Microsoft Foundry Local.'
  s.description      = <<-DESC
Flutter FFI plugin providing streaming chat, tool calling, speech-to-text and
embeddings on top of Microsoft Foundry Local's on-device ONNX Runtime GenAI.
                       DESC
  s.homepage         = 'https://github.com/microsoft/foundry-local-mobile'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Microsoft' => 'foundrylocal@microsoft.com' }

  # iOS 15.0 matches the Swift binding and OGA's supported floor.
  s.platform         = :ios, '15.0'
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'

  s.source           = { :path => '.' }

  # Swift + ObjC++ plugin sources.
  s.source_files     = 'Classes/**/*'

  s.dependency 'Flutter'
  s.frameworks       = ['Foundation', 'CoreML', 'CoreGraphics', 'ImageIO']
  s.libraries        = 'c++'

  # The core links against ONNX Runtime GenAI at runtime. Vendor both
  # XCFrameworks built by `scripts/build_apple.sh` so the dynamic linker
  # can resolve them. The same frameworks are referenced by the Swift
  # Package and React Native pod.
  framework_root = File.directory?(File.join(__dir__, "Frameworks")) \
    ? "Frameworks" \
    : "../../ios/Frameworks"
  s.vendored_frameworks = [
    "#{framework_root}/FoundryLocalMobile.xcframework",
    "#{framework_root}/onnxruntime-genai.xcframework",
  ]

  # nlohmann/json is a header-only dependency the C++ core relies on. The
  # simplest reproducible integration for a plugin build is to vendor a single
  # header at core/third_party/nlohmann and put it on the include path.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'STRIP_INSTALLED_PRODUCT' => 'NO'
  }
end
