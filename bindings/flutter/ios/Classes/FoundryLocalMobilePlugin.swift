// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Flutter
import Foundation
import UIKit

/// Method / event channel host for the Flutter FFI plugin on iOS.
///
/// Everything on the data path (chat completion, streaming, embeddings) goes
/// through the C ABI over `dart:ffi`. This class exists solely
/// to forward the OS notifications Dart cannot observe on its own:
///
///   * app foreground / background transitions,
///   * `didReceiveMemoryWarning`,
///   * low-power mode changes,
///   * thermal-state transitions.
public class FoundryLocalMobilePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FoundryLocalMobilePlugin()

        let methodChannel = FlutterMethodChannel(
            name: "com.microsoft.ai.foundry.local.mobile/plugin",
            binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: "com.microsoft.ai.foundry.local.mobile/events",
            binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
    }

    // MARK: - MethodChannel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getSandboxDirectory":
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
            result(dir)
        case "refreshState":
            emitInitialState()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - EventChannel

    public func onListen(withArguments _: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink
        attachObservers()
        emitInitialState()
        return nil
    }

    public func onCancel(withArguments _: Any?) -> FlutterError? {
        detachObservers()
        eventSink = nil
        return nil
    }

    // MARK: - Observers

    private func attachObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onMemoryWarning),
                       name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        nc.addObserver(self, selector: #selector(onLowPowerChange),
                       name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        nc.addObserver(self, selector: #selector(onThermalChange),
                       name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

    }

    private func detachObservers() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onMemoryWarning() { emit("memory_warning") }

    @objc private func onLowPowerChange() {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            emit("low_power")
        }
    }

    @objc private func onThermalChange() {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            emit("thermal_throttling")
        default:
            break
        }
    }

    private func emit(_ kind: String) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(["kind": kind])
        }
    }

    private func emitInitialState() {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            emit("low_power")
        }
    }
}
