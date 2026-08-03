// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Tiny C adapter that lets the Dart FFI binding forward the flm_* callbacks
// through `NativeCallable.listener`. That API only supports void-returning
// callbacks, but three of the ABI's callback typedefs return int32_t:
//
//   * flm_progress_callback   (return non-zero to request cancellation)
//   * flm_delta_callback      (return non-zero to request cancellation)
//   * flm_transport_send      (return non-zero to fail the request fast)
//
// This file provides three trampolines with the C-side (int32_t-returning)
// signature. Each looks up a caller-supplied context, invokes a void-returning
// forwarder (the Dart `NativeCallable.listener`'s nativeFunction), and returns
// 0 unconditionally. Cancellation is expressed instead via `flm_job_cancel`,
// and transport failures are surfaced with `flm_transport_report_complete`.
//
// The forwarders are safe to invoke from the core's job-pool threads because
// they are exactly `NativeCallable.listener` — they only post a message onto
// the isolate's port and return.

#ifndef FOUNDRY_LOCAL_MOBILE_FLUTTER_DART_BRIDGE_H_
#define FOUNDRY_LOCAL_MOBILE_FLUTTER_DART_BRIDGE_H_

#include <stdint.h>

#include "foundry_local_mobile/flm_export.h"
#include "foundry_local_mobile/flm_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Void-returning signatures matching the shape of the corresponding int32_t
/// callbacks in flm_types.h — apart from the return type.
typedef void(FLM_CALLBACK* flm_dart_progress_forwarder)(flm_job job, const flm_progress* progress,
                                                       void* user_data);
typedef void(FLM_CALLBACK* flm_dart_delta_forwarder)(flm_job job, const flm_delta* delta, void* user_data);
typedef void(FLM_CALLBACK* flm_dart_send_forwarder)(const flm_http_request* request, void* user_data);

/// Context struct carried through the ABI as `user_data`. Dart owns the
/// allocation and must free it after the job is done and the listeners are
/// closed.
///
/// Fields the current job does not use may be NULL — the trampolines skip a
/// NULL forwarder.
typedef struct flm_dart_bridge_ctx {
  uint32_t version;  ///< Set to 1.
  flm_dart_progress_forwarder on_progress;
  flm_dart_delta_forwarder on_delta;
  flm_dart_send_forwarder on_send;
  void* user_data;  ///< Opaque Dart-side pointer, echoed back to the forwarders.
} flm_dart_bridge_ctx;

/// int32_t → void adapter for `flm_progress_callback`. Always returns 0.
FLM_EXPORT int32_t FLM_CALL flm_dart_bridge_progress(flm_job job, const flm_progress* progress,
                                                    void* user_data) FLM_NOEXCEPT;

/// int32_t → void adapter for `flm_delta_callback`. Always returns 0.
FLM_EXPORT int32_t FLM_CALL flm_dart_bridge_delta(flm_job job, const flm_delta* delta,
                                                  void* user_data) FLM_NOEXCEPT;

/// int32_t → void adapter for `flm_transport_send`. Always returns 0. The Dart
/// transport reports synchronous failure via `flm_transport_report_complete`
/// with a non-zero status code.
FLM_EXPORT int32_t FLM_CALL flm_dart_bridge_send(const flm_http_request* request,
                                                 void* user_data) FLM_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif  // FOUNDRY_LOCAL_MOBILE_FLUTTER_DART_BRIDGE_H_
