require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "FoundryLocal"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["repository"]
  s.license      = package["license"]
  s.author       = "Microsoft Corporation"
  s.source       = { :git => "https://github.com/microsoft/foundry-local-mobile.git", :tag => "v#{s.version}" }
  s.platforms    = { :ios => "14.0" }
  s.source_files = "ios/**/*.{h,m,mm,swift}"

  # New Architecture / TurboModule wiring. `install_modules_dependencies` is
  # the RN 0.73+ helper that adds React-Core, ReactCommon/turbomodule/core
  # and the codegen'd Swift/Obj-C++ headers to the pod without every app
  # having to enumerate them.
  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  else
    s.dependency "React-Core"
  end

  # The iOS native implementation is intentionally not yet wired; every
  # method rejects with a "notImplemented" error at runtime. The Swift
  # binding this module will wrap is landing in a follow-up PR — see the
  # package README's "iOS status" section.
end
