// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Types for the Foundry Local Mobile C ABI.
//
// Design notes (see docs/architecture.md for the full rationale):
//   * Handles are 64-bit integers, not pointers. They are validated against a handle
//     table on every call, so a stale handle produces FLM_ERROR_INVALID_HANDLE instead
//     of undefined behaviour. This also lets bindings store them in a Java `long`, a
//     Dart `int` or a Swift `UInt64` with no pointer-provenance concerns.
//   * Structured data (model info, variants, device profile, messages) crosses the
//     boundary as UTF-8 JSON. It is read once and marshalling dozens of struct fields
//     through four different FFI systems is not worth the bug surface.
//   * Streaming deltas cross as a plain struct with borrowed strings, because that is
//     the hot path and must not allocate a JSON document per token.
//   * Every struct starts with `version`, set to FLM_API_VERSION by the caller.
//     Structs only ever grow at the end.

#ifndef FOUNDRY_LOCAL_MOBILE_FLM_TYPES_H_
#define FOUNDRY_LOCAL_MOBILE_FLM_TYPES_H_

#include <stddef.h>
#include <stdint.h>

#include "flm_export.h"

#ifdef __cplusplus
extern "C" {
#endif

/** ABI version. Bumped when the meaning of existing entries changes (never for additions). */
#define FLM_API_VERSION 2

/* -------------------------------------------------------------------------
 * Handles
 *
 * FLM_INVALID_HANDLE (0) is never a valid handle. All handle types are the same
 * underlying integer type; distinct typedefs exist for documentation and for
 * bindings that generate typed wrappers.
 *
 * A handle is an opaque 64-bit value, not a pointer and not a small index. It
 * encodes a kind tag in its high bits, so **every valid handle exceeds 2^56**.
 *
 * That matters for any binding whose host language lacks a 64-bit integer.
 * JavaScript's `number` is an IEEE-754 double and is exact only to 2^53, where
 * the spacing between representable values at handle magnitude is 16 — passing
 * a handle through one silently rounds away the low bits of the slot index. It
 * does not raise; it resolves to a different slot or to none, depending on what
 * happens to be live. Bindings in that position must keep their own registry of
 * small integer ids and never let a raw handle cross the boundary.
 * ------------------------------------------------------------------------- */

typedef uint64_t flm_handle;
#define FLM_INVALID_HANDLE ((flm_handle)0)

typedef flm_handle flm_manager;  ///< Root object. Owns the runtime, model registry and job pool.
typedef flm_handle flm_model;    ///< A model loaded from a caller-owned directory.
typedef flm_handle flm_session;  ///< An inference session bound to a loaded model.
typedef flm_handle flm_job;      ///< An in-flight asynchronous operation.

/* -------------------------------------------------------------------------
 * Status codes
 *
 * Every entry point returns flm_status. On a non-OK return, call
 * flm_last_error_message() / flm_last_error_detail_json() on the *same thread*
 * for details.
 * ------------------------------------------------------------------------- */

typedef enum flm_status {
  FLM_OK = 0,
  FLM_ERROR_INTERNAL = 1,           ///< Unexpected failure inside the runtime.
  FLM_ERROR_INVALID_ARGUMENT = 2,   ///< A NULL pointer, malformed JSON or out-of-range value.
  FLM_ERROR_INVALID_HANDLE = 3,     ///< Handle is unknown, released, or of the wrong type.
  FLM_ERROR_INVALID_STATE = 4,      ///< Operation is not legal right now (e.g. infer before load).
  FLM_ERROR_NOT_FOUND = 5,          ///< Model, alias, variant or tool does not exist.
  FLM_ERROR_NOT_IMPLEMENTED = 6,    ///< Not supported on this platform or runtime build.
  FLM_ERROR_CANCELLED = 7,          ///< Cancelled via flm_job_cancel or a callback returning non-zero.
  FLM_ERROR_NETWORK = 8,            ///< Reserved compatibility status; the SDK performs no network I/O.
  FLM_ERROR_STORAGE = 9,            ///< Filesystem failure, or insufficient free space.
  FLM_ERROR_OUT_OF_MEMORY = 10,     ///< Allocation failed, or the OS refused the model's footprint.
  FLM_ERROR_INCOMPATIBLE = 11,      ///< No model-package variant is runnable on this device.
  FLM_ERROR_TIMEOUT = 12,           ///< A bounded wait expired.
  FLM_ERROR_UNSUPPORTED_VERSION = 13,  ///< Struct `version` is newer than this build understands.
  FLM_ERROR_MEMORY_PRESSURE = 14,   ///< The OS reclaimed the model; reload and retry.
  FLM_ERROR_SHUTDOWN = 15,          ///< The manager is shutting down; no new work is accepted.
} flm_status;

typedef enum flm_log_level {
  FLM_LOG_VERBOSE = 0,
  FLM_LOG_DEBUG = 1,
  FLM_LOG_INFO = 2,
  FLM_LOG_WARNING = 3,
  FLM_LOG_ERROR = 4,
  FLM_LOG_FATAL = 5,
  FLM_LOG_OFF = 6,
} flm_log_level;

/** Compute device a model variant targets. Mirrors the upstream device taxonomy. */
typedef enum flm_device {
  FLM_DEVICE_UNKNOWN = 0,
  FLM_DEVICE_CPU = 1,
  FLM_DEVICE_GPU = 2,
  FLM_DEVICE_NPU = 3,
} flm_device;

/* -------------------------------------------------------------------------
 * Asynchronous jobs
 * ------------------------------------------------------------------------- */

typedef enum flm_job_state {
  FLM_JOB_PENDING = 0,    ///< Queued, not started.
  FLM_JOB_RUNNING = 1,    ///< Executing on a job-pool thread.
  FLM_JOB_SUCCEEDED = 2,  ///< Finished; a result may be available via flm_job_take_result_json.
  FLM_JOB_FAILED = 3,     ///< Finished with an error.
  FLM_JOB_CANCELLED = 4,  ///< Finished after a cancellation request.
} flm_job_state;

/**
 * Progress for a long-running job.
 *
 * `percent` is always populated (0.0–100.0). Byte counters are populated for downloads
 * and are FLM_UNKNOWN_SIZE elsewhere. `stage` names the current phase, e.g.
 * "resolving", "downloading", "verifying", "extracting", "loading".
 */
#define FLM_UNKNOWN_SIZE ((int64_t)-1)

typedef struct flm_progress {
  uint32_t version;              ///< FLM_API_VERSION.
  float percent;                 ///< 0.0 – 100.0.
  int64_t completed_bytes;       ///< FLM_UNKNOWN_SIZE when not byte-based.
  int64_t total_bytes;           ///< FLM_UNKNOWN_SIZE when the total is not known yet.
  int64_t bytes_per_second;      ///< Smoothed transfer rate; FLM_UNKNOWN_SIZE when unavailable.
  int64_t eta_ms;                ///< Estimated time remaining; FLM_UNKNOWN_SIZE when unavailable.
  const char* stage;             ///< Borrowed, valid only for the duration of the callback.
  const char* detail;            ///< Optional item being processed (e.g. a variant id). May be NULL.
} flm_progress;

/* -------------------------------------------------------------------------
 * Streaming deltas
 * ------------------------------------------------------------------------- */

typedef enum flm_delta_kind {
  FLM_DELTA_TEXT = 0,             ///< Assistant text fragment.
  FLM_DELTA_REASONING = 1,        ///< Chain-of-thought fragment from a reasoning model.
  FLM_DELTA_TOOL_CALL = 2,        ///< A complete tool call the model wants executed.
  FLM_DELTA_SPEECH_PARTIAL = 3,   ///< Transcription hypothesis; replaces the previous partial.
  FLM_DELTA_SPEECH_FINAL = 4,     ///< Transcription segment is stable.
  FLM_DELTA_USAGE = 5,            ///< Token accounting update.
  FLM_DELTA_COMPLETED = 6,        ///< Terminal event; `finish_reason` is meaningful.
} flm_delta_kind;

typedef enum flm_finish_reason {
  FLM_FINISH_NONE = 0,        ///< Still generating.
  FLM_FINISH_STOP = 1,        ///< Natural end or stop sequence.
  FLM_FINISH_LENGTH = 2,      ///< Hit the output token limit.
  FLM_FINISH_TOOL_CALLS = 3,  ///< Model is waiting on tool results.
  FLM_FINISH_CANCELLED = 4,   ///< Cancelled by the caller.
  FLM_FINISH_ERROR = 5,       ///< Aborted by an error.
} flm_finish_reason;

/**
 * A single streaming event.
 *
 * All `const char*` members are **borrowed** and valid only for the duration of the
 * callback. Copy anything you need to retain. Strings are UTF-8 and may contain
 * embedded NULs only if the paired length field says so.
 */
typedef struct flm_delta {
  uint32_t version;                 ///< FLM_API_VERSION.
  flm_delta_kind kind;
  const char* text;                 ///< TEXT / REASONING / SPEECH_*: the fragment. May be NULL.
  size_t text_length;               ///< Byte length of `text`, excluding any terminator.
  const char* tool_call_id;         ///< TOOL_CALL only.
  const char* tool_name;            ///< TOOL_CALL only.
  const char* tool_arguments_json;  ///< TOOL_CALL only; JSON object.
  int64_t start_time_ms;            ///< SPEECH_*: offset from the start of the audio.
  int64_t end_time_ms;              ///< SPEECH_*: offset from the start of the audio.
  int64_t prompt_tokens;            ///< USAGE / COMPLETED.
  int64_t completion_tokens;        ///< USAGE / COMPLETED.
  flm_finish_reason finish_reason;  ///< COMPLETED only.
} flm_delta;

/* -------------------------------------------------------------------------
 * Lifecycle
 *
 * Mobile apps must forward OS lifecycle transitions so the core can release memory
 * before the OS kills the process. Each binding wires these to the platform's
 * notifications; apps do not normally call them directly.
 * ------------------------------------------------------------------------- */

typedef enum flm_lifecycle_event {
  FLM_LIFECYCLE_FOREGROUND = 0,          ///< App became active. Reload eagerly-unloaded models.
  FLM_LIFECYCLE_BACKGROUND = 1,          ///< App backgrounded. Pause non-essential work.
  FLM_LIFECYCLE_MEMORY_WARNING = 2,      ///< OS memory warning. Trim caches.
  FLM_LIFECYCLE_MEMORY_CRITICAL = 3,     ///< Imminent termination. Unload models now.
  FLM_LIFECYCLE_LOW_POWER = 4,           ///< Low-power mode. Prefer efficiency cores / smaller variants.
  FLM_LIFECYCLE_THERMAL_THROTTLING = 5,  ///< Device is hot. Throttle or move off the NPU/GPU.
  FLM_LIFECYCLE_NETWORK_METERED = 6,     ///< Reserved compatibility value; currently ignored.
  FLM_LIFECYCLE_NETWORK_UNMETERED = 7,   ///< Reserved compatibility value; currently ignored.
} flm_lifecycle_event;

/* -------------------------------------------------------------------------
 * Callbacks
 *
 * All callbacks are invoked on a core job-pool thread, never on the caller's thread.
 * They must not block for long and must not re-enter the ABI with the same job handle
 * (other handles are fine). Bindings are responsible for hopping to the appropriate
 * dispatch queue / coroutine context / isolate.
 *
 * LIFETIME, and the most common way to get this wrong: every struct and string handed
 * to a callback is borrowed and valid ONLY for the duration of that call. The core
 * builds them on the stack of the calling thread and destroys them the moment the
 * callback returns. A binding that hands the raw pointer to another thread, queue or
 * isolate and reads it there is reading freed memory. Copy everything you need out
 * before returning — which, on the streaming delta path, means copying per token.
 * ------------------------------------------------------------------------- */

/**
 * Progress notification. Return non-zero to request cancellation of the job.
 *
 * `progress` and its strings are borrowed for the duration of the call only.
 */
typedef int32_t(FLM_CALLBACK* flm_progress_callback)(flm_job job, const flm_progress* progress, void* user_data);

/**
 * Streaming event. Return non-zero to request cancellation of the job.
 *
 * `delta` and its strings are borrowed for the duration of the call only.
 */
typedef int32_t(FLM_CALLBACK* flm_delta_callback)(flm_job job, const flm_delta* delta, void* user_data);

/**
 * Terminal notification for a job. Invoked exactly once per job, even on cancellation.
 *
 * `error_json` is NULL when `status` is FLM_OK; otherwise it is a borrowed UTF-8 JSON
 * object of the shape produced by flm_last_error_detail_json(), valid for the duration
 * of the call only.
 *
 * After this returns, the job's result (if any) can still be read with
 * flm_job_take_result_json until flm_job_release is called.
 */
typedef void(FLM_CALLBACK* flm_completion_callback)(flm_job job, flm_status status, const char* error_json,
                                                    void* user_data);

/** Log sink. `message` is borrowed and valid only for the duration of the call. */
typedef void(FLM_CALLBACK* flm_log_callback)(flm_log_level level, const char* tag, const char* message,
                                             void* user_data);

/* -------------------------------------------------------------------------
 * HTTP transport — REMOVED
 *
 * The SDK no longer performs downloads. Models are loaded from caller-owned
 * directories; there is no transport layer.
 * ------------------------------------------------------------------------- */

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // FOUNDRY_LOCAL_MOBILE_FLM_TYPES_H_
