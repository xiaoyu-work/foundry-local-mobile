// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Tiny C adapter that lets the Dart FFI binding forward the flm_* callbacks
// through `NativeCallable.listener`. Two things this shim solves that Dart
// cannot solve on its own:
//
// 1. `NativeCallable.listener` only supports void-returning callbacks, but
//    two ABI typedefs return int32_t (`flm_progress_callback`,
//    `flm_delta_callback`). The listener needs to post to the isolate and
//    return synchronously — there is no value it could plausibly synthesise
//    for the caller. This shim wraps each with an int32_t-returning C
//    trampoline that always returns 0. Cancellation is expressed via
//    `flm_job_cancel`.
//
// 2. `NativeCallable.listener` dispatches ASYNCHRONOUSLY — it queues a message
//    onto the isolate's port and returns immediately. By the time Dart runs
//    the listener body the core has already destroyed the struct and every
//    string on the callback's stack. If the trampoline handed Dart the raw
//    pointer it would be reading freed memory.
//
//    So each trampoline copies the payload onto the heap synchronously — on
//    the core thread while the borrowed data is still valid — and passes the
//    OWNED heap pointer to Dart. Dart frees it via the matching
//    `flm_dart_bridge_free_*` helper below.

#ifndef FOUNDRY_LOCAL_MOBILE_FLUTTER_DART_BRIDGE_H_
#define FOUNDRY_LOCAL_MOBILE_FLUTTER_DART_BRIDGE_H_

#include <stdint.h>

#include "foundry_local_mobile/flm_export.h"
#include "foundry_local_mobile/flm_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Void-returning forwarders that Dart supplies via
/// `NativeCallable.listener.nativeFunction`. Each is invoked from the
/// trampoline with an OWNED pointer the Dart side must eventually free with
/// the matching `flm_dart_bridge_free_*` helper.
typedef void(FLM_CALLBACK* flm_dart_progress_forwarder)(flm_job job, flm_progress* owned,
                                                       void* user_data);
typedef void(FLM_CALLBACK* flm_dart_delta_forwarder)(flm_job job, flm_delta* owned, void* user_data);
typedef void(FLM_CALLBACK* flm_dart_completion_forwarder)(flm_job job, int32_t status,
                                                         char* owned_error_json, void* user_data);

/// Context struct carried through the ABI as `user_data`. Dart owns the
/// allocation and must free it after the job is done and the listeners are
/// closed.
typedef struct flm_dart_bridge_ctx {
  uint32_t version;  ///< Set to 1.
  flm_dart_progress_forwarder on_progress;
  flm_dart_delta_forwarder on_delta;
  flm_dart_completion_forwarder on_complete;
  void* user_data;  ///< Opaque Dart-side pointer, echoed back to the forwarders.
} flm_dart_bridge_ctx;

/// int32_t → void adapter for `flm_progress_callback`. Deep-copies the
/// borrowed `flm_progress` (and its `stage`/`detail` strings) onto the heap
/// and hands the OWNED pointer to `ctx->on_progress`. Always returns 0.
FLM_EXPORT int32_t FLM_CALL flm_dart_bridge_progress(flm_job job, const flm_progress* progress,
                                                    void* user_data) FLM_NOEXCEPT;

/// int32_t → void adapter for `flm_delta_callback`. Deep-copies the borrowed
/// `flm_delta` (including `text` — length-aware because `text_length` is
/// authoritative and the fragment is not guaranteed NUL-terminated — plus
/// the three optional tool-call strings) onto the heap. Always returns 0.
FLM_EXPORT int32_t FLM_CALL flm_dart_bridge_delta(flm_job job, const flm_delta* delta,
                                                  void* user_data) FLM_NOEXCEPT;

/// Void adapter for `flm_completion_callback`. Deep-copies the borrowed
/// `error_json` string (NULL when status is FLM_OK) onto the heap and hands
/// it to `ctx->on_complete`.
FLM_EXPORT void FLM_CALL flm_dart_bridge_complete(flm_job job, flm_status status,
                                                  const char* error_json,
                                                  void* user_data) FLM_NOEXCEPT;

/// Release an owned progress copy handed to a forwarder. Dart calls this
/// after reading the fields, always inside a try/finally so a parse error
/// cannot leak the heap allocation.
FLM_EXPORT void FLM_CALL flm_dart_bridge_free_progress(flm_progress* owned) FLM_NOEXCEPT;

/// Release an owned delta copy handed to a forwarder.
FLM_EXPORT void FLM_CALL flm_dart_bridge_free_delta(flm_delta* owned) FLM_NOEXCEPT;

/// Release an owned string previously handed to a forwarder (currently just
/// the completion `error_json`; NULL is accepted).
FLM_EXPORT void FLM_CALL flm_dart_bridge_free_string(char* owned) FLM_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif  // FOUNDRY_LOCAL_MOBILE_FLUTTER_DART_BRIDGE_H_
