# Foundry Local Mobile React Native example

This bare React Native New Architecture app consumes
`@foundry-local/react-native` through the local package in
`bindings/react-native`. Model selection is a one-time setup step; after the
model loads, the app switches to a chat-first screen with model status,
persistent user and assistant messages, streamed output, and a bottom-pinned
composer.

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
