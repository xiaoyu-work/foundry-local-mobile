// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'bindings/bindings.dart' as raw;
import 'bindings/native_library.dart';
import 'platform_channel.dart';

/// Forwards OS lifecycle transitions and memory-pressure notifications to the
/// core.
///
/// [FoundryLocal.create] attaches one of these to the manager and detaches it
/// on dispose. The bridge listens to Flutter's [WidgetsBinding] for lifecycle
/// state, and to the Kotlin/Swift plugin classes (via [PlatformBridge]) for
/// memory warnings and connectivity changes — things Dart cannot observe on
/// its own.
class LifecycleBridge with WidgetsBindingObserver {
  LifecycleBridge._(this._managerHandle);

  final int _managerHandle;
  StreamSubscription<PlatformEvent>? _platformSub;
  bool _attached = false;

  static LifecycleBridge attach(int managerHandle) {
    final bridge = LifecycleBridge._(managerHandle);
    bridge._attach();
    return bridge;
  }

  void _attach() {
    if (_attached) return;
    _attached = true;

    // WidgetsBinding is not available in a pure-Dart host (unit tests running
    // the plugin code in a plain isolate). Guard against that.
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);

    _platformSub = PlatformBridge.events.listen(_onPlatformEvent);
    // Ask the platform side for its current network state up front so the
    // core knows whether background downloads are allowed.
    PlatformBridge.refreshInitialState();
  }

  Future<void> detach() async {
    if (!_attached) return;
    _attached = false;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } on FlutterError {
      // No binding — pure Dart host. Nothing to remove.
    }
    await _platformSub?.cancel();
    _platformSub = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        _notify(raw.FlmLifecycleEvent.foreground);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _notify(raw.FlmLifecycleEvent.background);
        break;
    }
  }

  @override
  void didHaveMemoryPressure() {
    _notify(raw.FlmLifecycleEvent.memoryWarning);
  }

  void _onPlatformEvent(PlatformEvent event) {
    switch (event.kind) {
      case PlatformEventKind.memoryWarning:
        _notify(raw.FlmLifecycleEvent.memoryWarning);
        break;
      case PlatformEventKind.memoryCritical:
        _notify(raw.FlmLifecycleEvent.memoryCritical);
        break;
      case PlatformEventKind.lowPower:
        _notify(raw.FlmLifecycleEvent.lowPower);
        break;
      case PlatformEventKind.thermalThrottling:
        _notify(raw.FlmLifecycleEvent.thermalThrottling);
        break;
      case PlatformEventKind.networkMetered:
        _notify(raw.FlmLifecycleEvent.networkMetered);
        break;
      case PlatformEventKind.networkUnmetered:
        _notify(raw.FlmLifecycleEvent.networkUnmetered);
        break;
    }
  }

  void _notify(int event) {
    if (!_attached) return;
    NativeLibrary.instance.bindings
        .flm_manager_notify_lifecycle(_managerHandle, event);
    if (kDebugMode) {
      // A missed lifecycle notification is a common cause of "the model was
      // unloaded and my next inference call fails" — leave a breadcrumb.
      debugPrint('foundry_local_mobile: notify_lifecycle event=$event');
    }
  }
}
