# Example apps

Each example uses only its platform's public SDK. All four accept a
caller-provided local ONNX Runtime GenAI model directory and stream chat output.

| SDK | App | SDK dependency |
|---|---|---|
| Kotlin / Android | [`android`](android) | `com.microsoft.ai.foundry.local:foundry-local-mobile` |
| Swift / iOS | [`ios`](ios) | local `FoundryLocal` Swift package |
| Dart / Flutter | [`../bindings/flutter/example`](../bindings/flutter/example) | `foundry_local_mobile` path package |
| TypeScript / React Native | [`react-native`](react-native) | local `@foundry-local/react-native` package |

The examples intentionally do not download models. Put a compatible OGA model
directory on the target and enter or select its absolute path in the app.
