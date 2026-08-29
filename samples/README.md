# Example apps

Each example uses only its platform's public SDK and presents the same
chat-first flow: model identity and status, persistent user and assistant
messages, streamed output, and a composer fixed at the bottom of the screen.

| SDK | App | Model setup |
|---|---|---|
| Kotlin / Android | [`android`](android) | Enter an on-device model directory |
| Swift / iOS | [`ios`](ios) | Enter or select an on-device model directory |
| Dart / Flutter | [`../bindings/flutter/example`](../bindings/flutter/example) | Stage a bundled model asset before building |
| TypeScript / React Native | [`react-native`](react-native) | Enter an on-device model directory |

The examples intentionally do not download models. See each app's README for
the platform-specific model staging and build steps.
