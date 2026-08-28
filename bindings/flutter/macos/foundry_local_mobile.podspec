# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

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

  # macOS 12.0 matches the Swift binding's minimum.
  s.platform         = :osx, '12.0'
  s.osx.deployment_target = '12.0'
  s.swift_version    = '5.9'

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  s.dependency 'FlutterMacOS'
  s.frameworks       = ['Foundation', 'CoreML', 'CoreGraphics', 'ImageIO']
  s.libraries        = 'c++'

  # The core links against ONNX Runtime GenAI at runtime. Vendor the
  # XCFrameworks built by `scripts/build_apple.sh --macos`.
  framework_root = File.directory?(File.join(__dir__, "Frameworks")) \
    ? "Frameworks" \
    : "../../ios/Frameworks"
  s.vendored_frameworks = [
    "#{framework_root}/FoundryLocalMobile.xcframework",
    "#{framework_root}/onnxruntime-genai.xcframework",
  ]

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'STRIP_INSTALLED_PRODUCT' => 'NO'
  }
end
