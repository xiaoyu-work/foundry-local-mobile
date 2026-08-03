// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

/// Method channel used for things the C ABI cannot ask the OS directly:
/// sandbox paths, lifecycle transitions, memory-pressure notifications, and
/// metered-network detection.
///
/// The data path — chat streaming, downloads, embeddings — does NOT go through
/// this channel. FFI is used for all of that so we avoid the platform-channel
/// hop and the per-message JSON encoding it forces.
///
/// The channel surface is deliberately narrow. A message-channel-driven plugin
/// would look bigger and be worse: platform channels serialise every payload
/// through JSON, and for streaming deltas that would defeat the point of an
/// on-device runtime.
class PlatformBridge {
  PlatformBridge._();

  static const MethodChannel _channel =
      MethodChannel('com.microsoft.ai.foundry.local.mobile/plugin');

  static const EventChannel _events =
      EventChannel('com.microsoft.ai.foundry.local.mobile/events');

  static Stream<PlatformEvent>? _cachedStream;

  /// Stream of platform-side lifecycle events (memory warnings, connectivity
  /// changes, thermal transitions). Broadcast; subscribing does not start any
  /// native work.
  static Stream<PlatformEvent> get events {
    return _cachedStream ??= _events.receiveBroadcastStream().map((event) {
      if (event is Map) {
        final kind = event['kind'];
        if (kind is String) {
          return PlatformEvent(kind: PlatformEventKind.fromString(kind));
        }
      }
      return const PlatformEvent(kind: PlatformEventKind.memoryWarning);
    }).where((e) => e.kind != PlatformEventKind._unknown);
  }

  /// Kick the native side to emit the current network state as an initial
  /// event. Called after each attach so the manager picks up the right
  /// starting policy.
  static Future<void> refreshInitialState() async {
    try {
      await _channel.invokeMethod<void>('refreshState');
    } on MissingPluginException {
      // The host is not a Flutter app — pure Dart test host, for example.
    } on PlatformException {
      // Ignore; a missing platform hook is not fatal.
    }
  }

  /// Ask the platform for its app sandbox directory. Used as a fallback when
  /// [FoundryLocalConfig.appDataDir] is not set and `path_provider` is not
  /// available.
  static Future<String?> getSandboxDirectory() async {
    try {
      return await _channel.invokeMethod<String>('getSandboxDirectory');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

@immutable
class PlatformEvent {
  const PlatformEvent({required this.kind});
  final PlatformEventKind kind;
}

enum PlatformEventKind {
  memoryWarning,
  memoryCritical,
  lowPower,
  thermalThrottling,
  networkMetered,
  networkUnmetered,
  _unknown;

  static PlatformEventKind fromString(String s) {
    switch (s) {
      case 'memory_warning':
        return PlatformEventKind.memoryWarning;
      case 'memory_critical':
        return PlatformEventKind.memoryCritical;
      case 'low_power':
        return PlatformEventKind.lowPower;
      case 'thermal_throttling':
        return PlatformEventKind.thermalThrottling;
      case 'network_metered':
        return PlatformEventKind.networkMetered;
      case 'network_unmetered':
        return PlatformEventKind.networkUnmetered;
      default:
        return PlatformEventKind._unknown;
    }
  }
}
