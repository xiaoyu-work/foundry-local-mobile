require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "FoundryLocal"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["repository"]
  s.license      = package["license"]
  s.author       = "Microsoft Corporation"
  # This podspec is intentionally local-path-only for now. It compiles source
  # from the sibling Swift binding under `bindings/ios/`, which exists in this
  # repository layout but would not be present in a CocoaPods trunk checkout or
  # in the npm package tarball. Do not add a git `s.source` here until the Swift
  # binding ships its own pod (for example `FoundryLocalKit`) that this React
  # Native pod can depend on instead of reaching outside its pod root.

  # Matches the Swift binding's minimum (see bindings/ios/Package.swift). The
  # binding uses `AsyncThrowingStream` and `withTaskCancellationHandler`,
  # both iOS 15+.
  s.platforms    = { :ios => "15.0" }
  s.swift_versions = ["5.9"]

  # In a local checkout, two source trees are compiled into this single pod
  # module:
  #
  #   1. `ios/**` — the React Native wrapper we own (this file's directory).
  #   2. `../ios/Sources/FoundryLocal/**` — the Swift binding at
  #      `bindings/ios/Sources/FoundryLocal/`. We vendor its sources rather
  #      than depending on a separately published CocoaPod because none
  #      exists today; the binding is distributed as a Swift Package for
  #      direct iOS apps. When a `FoundryLocalKit.podspec` ships in
  #      `bindings/ios/` we can switch to a `s.dependency` and drop the
  #      vendored path.
  s.source_files = [
    "ios/**/*.{h,m,mm,swift}",
    "../ios/Sources/FoundryLocal/**/*.swift",
  ]

  # The native core (flat C ABI + ONNX Runtime) is delivered as two
  # XCFrameworks. Consumers must build them once with
  # `scripts/build_apple.sh` and copy or symlink the results into
  # `bindings/ios/Frameworks/`. Same expectation as the standalone Swift
  # Package — see `bindings/ios/Frameworks/README.md`.
  s.vendored_frameworks = [
    "../ios/Frameworks/FoundryLocalMobile.xcframework",
    "../ios/Frameworks/onnxruntime-genai.xcframework",
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
