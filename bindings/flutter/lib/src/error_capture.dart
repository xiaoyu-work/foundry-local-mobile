// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';
import 'dart:ffi';

import 'bindings/bindings.dart' as raw;
import 'bindings/native_library.dart';
import 'models/errors.dart';
import 'native_strings.dart';

/// Read the last-error state on the calling thread and raise the appropriate
/// [FoundryLocalException]. Must be called on the SAME isolate thread as the
/// failing ABI call — the core's error slot is thread-local, so a deferred
/// read on another isolate would see stale or empty data.
Never throwLastError(int status, {String? fallbackMessage}) {
  throw captureLastError(status, fallbackMessage: fallbackMessage);
}

/// Same as [throwLastError], but returns the exception rather than throwing,
/// for callers that want to complete a Completer with an error.
FoundryLocalException captureLastError(int status, {String? fallbackMessage}) {
  final lib = NativeLibrary.instance.bindings;
  final msgPtr = lib.flm_last_error_message();
  final message = cStringToDart(msgPtr).ifEmpty(
      fallbackMessage ?? 'flm_status ${FoundryLocalStatus.name(status)}');
  final detailPtr = lib.flm_last_error_detail_json();
  Map<String, Object?>? detail;
  if (detailPtr != nullptr) {
    final s = cStringToDart(detailPtr);
    if (s.isNotEmpty) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map<String, Object?>) {
          detail = decoded;
        } else if (decoded is Map) {
          detail = decoded.cast<String, Object?>();
        }
      } on FormatException {
        // Malformed JSON is a core bug; surface the raw string instead.
        detail = <String, Object?>{'raw': s};
      }
    }
  }
  lib.flm_clear_last_error();
  return buildException(status, message: message, detail: detail);
}

/// Parse the `error_json` payload passed to the completion callback into a
/// [FoundryLocalException]. Unlike [captureLastError], this does NOT touch
/// the thread-local error slot — the JSON is what the core hands us on the
/// callback thread.
FoundryLocalException exceptionFromErrorJson(int status, String? errorJson) {
  String message = FoundryLocalStatus.name(status);
  Map<String, Object?>? detail;
  if (errorJson != null && errorJson.isNotEmpty) {
    try {
      final decoded = jsonDecode(errorJson);
      if (decoded is Map<String, Object?>) {
        detail = decoded;
      } else if (decoded is Map) {
        detail = decoded.cast<String, Object?>();
      }
      final m = detail?['message'];
      if (m is String && m.isNotEmpty) {
        message = m;
      }
    } on FormatException {
      detail = <String, Object?>{'raw': errorJson};
    }
  }
  return buildException(status, message: message, detail: detail);
}

/// Raise if `status` is anything other than `FLM_OK`.
void checkStatus(int status, {String? fallbackMessage}) {
  if (status != raw.FlmStatus.ok) {
    throwLastError(status, fallbackMessage: fallbackMessage);
  }
}

extension _StringIfEmpty on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
