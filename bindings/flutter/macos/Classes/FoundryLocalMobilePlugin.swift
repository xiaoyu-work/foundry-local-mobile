// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Cocoa
import FlutterMacOS
import Foundation
import Network

/// Method / event channel host on macOS. Same responsibilities as the iOS
/// plugin, but uses AppKit lifecycle rather than UIKit.
public class FoundryLocalMobilePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.microsoft.ai.foundry.local.mobile.monitor")

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FoundryLocalMobilePlugin()

        let methodChannel = FlutterMethodChannel(
            name: "com.microsoft.ai.foundry.local.mobile/plugin",
            binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: "com.microsoft.ai.foundry.local.mobile/events",
            binaryMessenger: registrar.messenger)
        eventChannel.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getSandboxDirectory":
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            result(dir)
        case "refreshState":
            emitInitialState()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

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

    private func attachObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onThermalChange),
                       name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        monitor.pathUpdateHandler = { [weak self] path in
            self?.emit(path.isExpensive ? "network_metered" : "network_unmetered")
        }
        monitor.start(queue: monitorQueue)
    }

    private func detachObservers() {
        NotificationCenter.default.removeObserver(self)
        monitor.cancel()
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
        if monitor.currentPath.status == .satisfied {
            emit(monitor.currentPath.isExpensive ? "network_metered" : "network_unmetered")
        }
    }
}
