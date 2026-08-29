# Foundry Local Mobile iOS example

This SwiftUI app consumes the public `FoundryLocal` Swift package. It presents
model selection as a one-time setup step, loads the caller-owned ONNX Runtime
GenAI model through `FoundryLocal.loadModel(at:)`, then switches to a chat-first
screen with persistent user and assistant messages, streamed output, and a
bottom-pinned composer.

Build the two native XCFrameworks first, then open the project:

```bash
./bindings/ios/scripts/build_xcframework.sh --build-type Release --macos
open samples/ios/FoundryLocalExample.xcodeproj
```

The project references `bindings/ios` as a local Swift package. In a released
consumer app, replace that local package reference with the published package.

List the installed destinations, then run the transcript-state tests with a
matching device and OS (the example below matches an iOS 18.3.1 runtime):

```bash
xcodebuild -showdestinations \
  -project samples/ios/FoundryLocalExample.xcodeproj \
  -scheme FoundryLocalExample

xcodebuild test \
  -project samples/ios/FoundryLocalExample.xcodeproj \
  -scheme FoundryLocalExample \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3.1'
```
