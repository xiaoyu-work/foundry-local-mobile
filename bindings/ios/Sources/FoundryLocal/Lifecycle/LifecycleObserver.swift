// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Bridges platform lifecycle notifications to the ABI's `flm_manager_notify_lifecycle`.
//
// The core uses these to unload models under memory pressure, pause downloads on a
// metered link, and prefer efficiency cores when the device is low-power or hot. Apps
// almost never call the ABI directly for these transitions — this observer wires the
// standard `UIApplication`, `ProcessInfo` and `NWPathMonitor` notifications for you.

import Foundation
import FoundryLocalMobile

#if canImport(Network)
import Network

#if canImport(UIKit)
import UIKit
#endif

/// Observes OS notifications and forwards each into
/// `flm_manager_notify_lifecycle(manager, event)`.
///
/// Owned by the ``FoundryLocal`` root object. Not typically constructed by apps.
final class LifecycleObserver: @unchecked Sendable {
    private let manager: flm_manager
    private var observers: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "FoundryLocal.NWPathMonitor")
    private let lock = NSLock()
    private var lastNetworkExpensive: Bool?

    init(manager: flm_manager) {
        self.manager = manager
        installObservers()
        startPathMonitor()
    }

    deinit {
        stop()
    }

    /// Detach all observers and cancel the path monitor. Called when the ``FoundryLocal``
    /// owner is closed. Idempotent.
    func stop() {
        lock.lock()
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
        lock.unlock()
        pathMonitor.cancel()
    }

    // MARK: - Wiring

    private func installObservers() {
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []

        #if canImport(UIKit) && !os(watchOS)
        tokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.notify(FLM_LIFECYCLE_FOREGROUND)
        })
        tokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.notify(FLM_LIFECYCLE_BACKGROUND)
        })
        tokens.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            // The Apple contract for memory warnings promises no specific severity, so
            // we err on the side of the milder event; the core will escalate to
            // MEMORY_CRITICAL on its own if allocation still fails.
            self?.notify(FLM_LIFECYCLE_MEMORY_WARNING)
        })
        #endif

        tokens.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.forwardThermalState(ProcessInfo.processInfo.thermalState)
        })

        #if os(iOS) || os(tvOS) || os(visionOS)
        tokens.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                self?.notify(FLM_LIFECYCLE_LOW_POWER)
            }
            // We deliberately don't send a "power state normal" event; the core treats
            // absence of LOW_POWER as normal, and firing on every restore would spam
            // the log.
        })
        #endif

        lock.lock()
        observers.append(contentsOf: tokens)
        lock.unlock()

        // Prime the core with the current thermal state on start, so a hot device is
        // seen from the first lifecycle notification instead of the second.
        forwardThermalState(ProcessInfo.processInfo.thermalState)
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let expensive = path.isExpensive || path.isConstrained
            self.lock.lock()
            let prior = self.lastNetworkExpensive
            self.lastNetworkExpensive = expensive
            self.lock.unlock()
            if prior != expensive {
                self.notify(expensive ? FLM_LIFECYCLE_NETWORK_METERED : FLM_LIFECYCLE_NETWORK_UNMETERED)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func forwardThermalState(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal, .fair:
            // Not a lifecycle event the core acts on; skipping avoids noise.
            break
        case .serious, .critical:
            notify(FLM_LIFECYCLE_THERMAL_THROTTLING)
        @unknown default:
            break
        }
    }

    private func notify(_ event: flm_lifecycle_event) {
        _ = flm_manager_notify_lifecycle(manager, event)
    }
}

#endif // canImport(Network)
