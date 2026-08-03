// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'package:meta/meta.dart';

import '../bindings/bindings.dart' as raw;

/// Base class for every error the SDK raises across the FFI boundary.
///
/// The core reports errors as `flm_status` plus a JSON detail document; that
/// document is captured on the same thread that saw the failure and carried
/// across to the Dart isolate here.
@immutable
class FoundryLocalException implements Exception {
  const FoundryLocalException(
    this.status, {
    required this.message,
    required this.retryable,
    this.detail,
  });

  /// Numeric `flm_status` code returned by the C ABI. See [FoundryLocalStatus].
  final int status;

  /// Human-readable message, as reported by `flm_last_error_message`.
  final String message;

  /// The `retryable` bit from the JSON detail. Bindings use this to decide
  /// whether an operation is worth automatically retrying.
  final bool retryable;

  /// Raw `flm_last_error_detail_json` payload, if any. Includes a `context`
  /// object with operation-specific fields (URLs, HTTP statuses, model ids…).
  final Map<String, Object?>? detail;

  /// Whether this exception represents a retryable failure.
  bool get isRetryable => retryable;

  /// Symbolic name of the status code (e.g. `FLM_ERROR_NETWORK`).
  String get statusName => FoundryLocalStatus.name(status);

  @override
  String toString() {
    final buf = StringBuffer('FoundryLocalException($statusName): $message');
    if (detail != null && detail!.isNotEmpty) {
      buf.write(' — detail: $detail');
    }
    return buf.toString();
  }
}

/// Raised when a request is cancelled before it completes. Kept as a subclass
/// so callers can `on CancelledException catch (_)` without having to inspect
/// the numeric status code.
class CancelledException extends FoundryLocalException {
  const CancelledException({required super.message, super.detail})
      : super(raw.FlmStatus.cancelled, retryable: false);
}

/// Raised when the device cannot run any variant of a package.
class IncompatibleModelException extends FoundryLocalException {
  const IncompatibleModelException({required super.message, super.detail})
      : super(raw.FlmStatus.incompatible, retryable: false);
}

/// Raised when the OS reclaimed the model. The caller should reload and retry.
class MemoryPressureException extends FoundryLocalException {
  const MemoryPressureException({required super.message, super.detail})
      : super(raw.FlmStatus.memoryPressure, retryable: true);
}

/// Raised when the manager is shutting down and refuses new work.
class ShutdownException extends FoundryLocalException {
  const ShutdownException({required super.message, super.detail})
      : super(raw.FlmStatus.shutdown, retryable: false);
}

/// Symbolic names for the numeric status codes. Kept out of the public enum so
/// unknown values (returned by a newer runtime) still round-trip cleanly.
abstract class FoundryLocalStatus {
  static const int ok = raw.FlmStatus.ok;

  static const Map<int, String> _names = <int, String>{
    raw.FlmStatus.ok: 'FLM_OK',
    raw.FlmStatus.internal: 'FLM_ERROR_INTERNAL',
    raw.FlmStatus.invalidArgument: 'FLM_ERROR_INVALID_ARGUMENT',
    raw.FlmStatus.invalidHandle: 'FLM_ERROR_INVALID_HANDLE',
    raw.FlmStatus.invalidState: 'FLM_ERROR_INVALID_STATE',
    raw.FlmStatus.notFound: 'FLM_ERROR_NOT_FOUND',
    raw.FlmStatus.notImplemented: 'FLM_ERROR_NOT_IMPLEMENTED',
    raw.FlmStatus.cancelled: 'FLM_ERROR_CANCELLED',
    raw.FlmStatus.network: 'FLM_ERROR_NETWORK',
    raw.FlmStatus.storage: 'FLM_ERROR_STORAGE',
    raw.FlmStatus.outOfMemory: 'FLM_ERROR_OUT_OF_MEMORY',
    raw.FlmStatus.incompatible: 'FLM_ERROR_INCOMPATIBLE',
    raw.FlmStatus.timeout: 'FLM_ERROR_TIMEOUT',
    raw.FlmStatus.unsupportedVersion: 'FLM_ERROR_UNSUPPORTED_VERSION',
    raw.FlmStatus.memoryPressure: 'FLM_ERROR_MEMORY_PRESSURE',
    raw.FlmStatus.shutdown: 'FLM_ERROR_SHUTDOWN',
  };

  static String name(int status) =>
      _names[status] ?? 'FLM_STATUS($status)';
}

/// Build the correct exception subclass for a status code.
FoundryLocalException buildException(
  int status, {
  required String message,
  Map<String, Object?>? detail,
}) {
  final retryable = detail?['retryable'] as bool? ?? _defaultRetryable(status);
  switch (status) {
    case raw.FlmStatus.cancelled:
      return CancelledException(message: message, detail: detail);
    case raw.FlmStatus.incompatible:
      return IncompatibleModelException(message: message, detail: detail);
    case raw.FlmStatus.memoryPressure:
      return MemoryPressureException(message: message, detail: detail);
    case raw.FlmStatus.shutdown:
      return ShutdownException(message: message, detail: detail);
    default:
      return FoundryLocalException(
        status,
        message: message,
        retryable: retryable,
        detail: detail,
      );
  }
}

bool _defaultRetryable(int status) {
  switch (status) {
    case raw.FlmStatus.network:
    case raw.FlmStatus.timeout:
    case raw.FlmStatus.memoryPressure:
      return true;
    default:
      return false;
  }
}
