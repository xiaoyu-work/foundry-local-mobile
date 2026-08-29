import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let modelChannelName =
    "com.microsoft.ai.foundry.local.mobile.example/model-assets"
  private static let modelConfigAsset =
    "assets/models/qwen3_cpu_int4/genai_config.json"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: Self.modelChannelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "getBundledModelDirectory" else {
        result(FlutterMethodNotImplemented)
        return
      }

      let assetKey = FlutterDartProject.lookupKey(forAsset: Self.modelConfigAsset)
      guard let configPath = Bundle.main.path(forResource: assetKey, ofType: nil) else {
        result(
          FlutterError(
            code: "MODEL_ASSET_MISSING",
            message: "Bundled model config was not found.",
            details: assetKey
          )
        )
        return
      }
      result(URL(fileURLWithPath: configPath).deletingLastPathComponent().path)
    }
  }
}
