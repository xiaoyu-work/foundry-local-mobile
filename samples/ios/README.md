# Foundry Local Mobile iOS example

This SwiftUI app consumes the public `FoundryLocal` Swift package. It selects a
caller-owned ONNX Runtime GenAI model directory, loads it through
`FoundryLocal.loadModel(at:)`, and streams a multi-turn chat response.

Build the two native XCFrameworks first, then open the project:

```bash
./bindings/ios/scripts/build_xcframework.sh --build-type Release --macos
open samples/ios/FoundryLocalExample.xcodeproj
```

The project references `bindings/ios` as a local Swift package. In a released
consumer app, replace that local package reference with the published package.
