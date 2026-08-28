require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "FoundryLocal"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["repository"]
  s.license      = package["license"]
  s.author       = "Microsoft Corporation"
  # Matches the Swift binding's minimum (see bindings/ios/Package.swift). The
  # binding uses `AsyncThrowingStream` and `withTaskCancellationHandler`,
  # both iOS 15+.
  s.platforms    = { :ios => "15.0" }
  s.swift_versions = ["5.9"]

  swift_sources = File.directory?(File.join(__dir__, "ios", "FoundryLocal")) \
    ? "ios/FoundryLocal/**/*.swift" \
    : "../ios/Sources/FoundryLocal/**/*.swift"
  s.source_files = [
    "ios/RNFoundryLocal*.{h,m,mm,swift}",
    swift_sources,
  ]

  framework_root = File.directory?(File.join(__dir__, "ios", "Frameworks")) \
    ? "ios/Frameworks" \
    : "../ios/Frameworks"
  s.vendored_frameworks = [
    "#{framework_root}/FoundryLocalMobile.xcframework",
    "#{framework_root}/onnxruntime-genai.xcframework",
  ]

  # Match the Swift binding's compilation environment (`Package.swift`
  # enables the same upcoming features). Keeps behaviour identical whether a
  # consumer uses SwiftPM directly or reaches the binding through this pod.
  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS" => "$(inherited) FOUNDRY_LOCAL_MOBILE_RN",
    "OTHER_SWIFT_FLAGS" => "$(inherited) -enable-upcoming-feature StrictConcurrency -enable-upcoming-feature ExistentialAny -enable-upcoming-feature InferSendableFromCaptures",
  }

  # New Architecture / TurboModule wiring. `install_modules_dependencies` is
  # the RN 0.73+ helper that adds React-Core, ReactCommon/turbomodule/core
  # and the codegen'd Swift/Obj-C++ headers to the pod without every app
  # having to enumerate them.
  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  else
    s.dependency "React-Core"
  end
end
