# Foundry Local Mobile React Native example

This bare React Native New Architecture app consumes
`@foundry-local/react-native` through the local package in
`bindings/react-native`. It loads a caller-owned ONNX Runtime GenAI model
directory and streams chat output.

```bash
npm install
npm run typecheck
npm run android
```

For iOS, build the native XCFrameworks before installing pods:

```bash
../../bindings/ios/scripts/build_xcframework.sh --build-type Release
cd ios
bundle install
bundle exec pod install
cd ..
npm run ios
```

The SDK requires the New Architecture, Android API 26+, and iOS 15+.
