// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'package:meta/meta.dart';

/// Compute placement of a model variant.
enum FlmDevice {
  unknown,
  cpu,
  gpu,
  npu;

  static FlmDevice fromJson(Object? value) {
    if (value is String) {
      switch (value.toLowerCase()) {
        case 'cpu':
          return FlmDevice.cpu;
        case 'gpu':
          return FlmDevice.gpu;
        case 'npu':
          return FlmDevice.npu;
      }
    }
    return FlmDevice.unknown;
  }
}

/// Thermal state as reported by the OS.
enum ThermalState {
  nominal,
  fair,
  serious,
  critical,
  unknown;

  static ThermalState fromJson(Object? value) {
    if (value is String) {
      for (final s in ThermalState.values) {
        if (s.name == value.toLowerCase()) return s;
      }
    }
    return ThermalState.unknown;
  }
}

/// Whether the active connection is metered.
enum NetworkStatus {
  unknown,
  offline,
  unmetered,
  metered;

  static NetworkStatus fromJson(Object? value) {
    if (value is String) {
      for (final s in NetworkStatus.values) {
        if (s.name == value.toLowerCase()) return s;
      }
    }
    return NetworkStatus.unknown;
  }
}

/// A single execution provider reported in the device profile.
@immutable
class ExecutionProvider {
  const ExecutionProvider({
    required this.name,
    required this.device,
    required this.available,
    required this.priority,
  });

  final String name;
  final FlmDevice device;
  final bool available;
  final int priority;

  factory ExecutionProvider.fromJson(Map<String, Object?> json) =>
      ExecutionProvider(
        name: json['name'] as String? ?? 'unknown',
        device: FlmDevice.fromJson(json['device']),
        available: json['available'] as bool? ?? false,
        priority: (json['priority'] as num?)?.toInt() ?? 0,
      );
}

/// Snapshot of what the core knows about the device — populated from
/// `flm_manager_get_device_profile_json`.
@immutable
class DeviceProfile {
  const DeviceProfile({
    required this.platform,
    required this.osVersion,
    required this.deviceModel,
    required this.soc,
    required this.abi,
    required this.cpuCores,
    required this.totalMemoryBytes,
    required this.availableMemoryBytes,
    required this.availableStorageBytes,
    required this.hasNpu,
    required this.hasGpu,
    required this.executionProviders,
    required this.thermalState,
    required this.lowPowerMode,
    required this.network,
    this.raw = const <String, Object?>{},
  });

  final String platform;
  final String osVersion;
  final String deviceModel;
  final String soc;
  final String abi;
  final int cpuCores;
  final int totalMemoryBytes;
  final int availableMemoryBytes;
  final int availableStorageBytes;
  final bool hasNpu;
  final bool hasGpu;
  final List<ExecutionProvider> executionProviders;
  final ThermalState thermalState;
  final bool lowPowerMode;
  final NetworkStatus network;
  final Map<String, Object?> raw;

  /// Convenience: whether the active connection is unmetered. Downloads on a
  /// metered connection are refused by default unless the caller opts in.
  bool get isUnmetered => network == NetworkStatus.unmetered;

  factory DeviceProfile.fromJson(Map<String, Object?> json) {
    final eps = (json['execution_providers'] as List?)
            ?.cast<Map<String, Object?>>()
            .map(ExecutionProvider.fromJson)
            .toList(growable: false) ??
        const <ExecutionProvider>[];
    return DeviceProfile(
      platform: json['platform'] as String? ?? 'unknown',
      osVersion: json['os_version'] as String? ?? '',
      deviceModel: json['device_model'] as String? ?? '',
      soc: json['soc'] as String? ?? '',
      abi: json['abi'] as String? ?? '',
      cpuCores: (json['cpu_cores'] as num?)?.toInt() ?? 0,
      totalMemoryBytes: (json['total_memory_bytes'] as num?)?.toInt() ?? 0,
      availableMemoryBytes:
          (json['available_memory_bytes'] as num?)?.toInt() ?? 0,
      availableStorageBytes:
          (json['available_storage_bytes'] as num?)?.toInt() ?? 0,
      hasNpu: json['has_npu'] as bool? ?? false,
      hasGpu: json['has_gpu'] as bool? ?? false,
      executionProviders: eps,
      thermalState: ThermalState.fromJson(json['thermal_state']),
      lowPowerMode: json['low_power_mode'] as bool? ?? false,
      network: NetworkStatus.fromJson(json['network']),
      raw: json,
    );
  }
}
