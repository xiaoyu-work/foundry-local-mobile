// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Foundry Local Mobile — flat C ABI (path-only, no catalog/download).
//
// This header is the single contract shared by every platform binding (Kotlin/JNI,
// Swift, Dart FFI, React Native). It is intentionally flat: plain exported functions,
// integer handles and UTF-8 JSON for structured data.
//
// Threading
//   Unless documented otherwise, every function is safe to call from any thread.
//   Functions ending in `_async` return immediately with a job handle; their work runs
//   on the core job pool and reports through callbacks.
//
// Ownership
//   * Handles are owned by the caller and released with the matching `_release` call.
//     Releasing an invalid handle is a no-op.
//   * `char*` returned through an out-parameter is owned by the caller and must be freed
//     with flm_string_free().
//   * `const char*` returned directly (e.g. flm_version_string) is owned by the library
//     and lives for the process lifetime.
//   * `const char*` inside a callback struct is borrowed and valid only for that call.
//
// Errors
//   Every function returns flm_status. On failure, flm_last_error_message() and
//   flm_last_error_detail_json() describe the most recent failure *on the calling
//   thread*, so they remain accurate under concurrency.

#ifndef FOUNDRY_LOCAL_MOBILE_FLM_API_H_
#define FOUNDRY_LOCAL_MOBILE_FLM_API_H_

#include "flm_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Library-wide
 * ========================================================================= */

/** Semantic version of this library. */
#define FLM_VERSION_MAJOR 0
#define FLM_VERSION_MINOR 2
#define FLM_VERSION_PATCH 0
#define FLM_VERSION_STRING "0.2.0"

/** Semantic version of this library, e.g. "0.2.0". Owned by the library. */
FLM_EXPORT const char* FLM_CALL flm_version_string(void) FLM_NOEXCEPT;

/** ABI version this build implements. Bindings compare against FLM_API_VERSION. */
FLM_EXPORT uint32_t FLM_CALL flm_api_version(void) FLM_NOEXCEPT;

/** Version of the underlying OGA runtime. NULL if unavailable. */
FLM_EXPORT const char* FLM_CALL flm_runtime_version_string(void) FLM_NOEXCEPT;

/** Free a string returned by this library through an out-parameter. NULL is a no-op. */
FLM_EXPORT void FLM_CALL flm_string_free(char* str) FLM_NOEXCEPT;

/**
 * Install a process-wide log sink. Pass NULL to remove it.
 * The callback may be invoked from any thread, including during flm_manager_create.
 */
FLM_EXPORT flm_status FLM_CALL flm_set_log_callback(flm_log_callback callback, void* user_data) FLM_NOEXCEPT;

/** Set the minimum level forwarded to the log sink. Defaults to FLM_LOG_WARNING. */
FLM_EXPORT flm_status FLM_CALL flm_set_log_level(flm_log_level level) FLM_NOEXCEPT;

/** Whether the runtime library is present and loadable. Never throws or logs on failure. */
FLM_EXPORT int32_t FLM_CALL flm_is_runtime_available(void) FLM_NOEXCEPT;

/* =========================================================================
 * Errors
 * ========================================================================= */

/** Human-readable message for the last failure on this thread. Never NULL; "" if none. */
FLM_EXPORT const char* FLM_CALL flm_last_error_message(void) FLM_NOEXCEPT;

/** Machine-readable detail for the last failure on this thread. Never NULL. */
FLM_EXPORT const char* FLM_CALL flm_last_error_detail_json(void) FLM_NOEXCEPT;

/** Clear the last-error state for this thread. */
FLM_EXPORT void FLM_CALL flm_clear_last_error(void) FLM_NOEXCEPT;

/* =========================================================================
 * Manager
 *
 * The manager owns the runtime, the model registry and the job pool. Create one
 * per process; creating several is legal but wasteful.
 * ========================================================================= */

/**
 * Create a manager from a JSON configuration.
 *
 * {
 *   "app_name": "my-app",                     // required, non-empty
 *   "app_data_dir": "/data/.../files/foundry",// optional: metadata directory
 *   "log_level": "warning",                   // optional
 *   "auto_unload_on_background": true,        // optional, default true
 *   "job_pool_threads": 0,                    // optional, 0 = derive from core count
 *   "additional_options": { "key": "value" }  // optional passthrough to the runtime
 * }
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_create(const char* config_json, flm_manager* out_manager) FLM_NOEXCEPT;

/**
 * Begin graceful shutdown: stop accepting work, cancel in-flight jobs, unload models.
 * Idempotent. Pending completion callbacks still fire, with FLM_ERROR_CANCELLED.
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_shutdown(flm_manager manager) FLM_NOEXCEPT;

/**
 * Release the manager. Blocks until outstanding jobs have finished unwinding.
 * All handles derived from this manager become invalid.
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_release(flm_manager manager) FLM_NOEXCEPT;

/**
 * Describe the device: SoC, memory, accelerators and EP preference order.
 * Caller frees `out_json` with flm_string_free().
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_get_device_profile_json(flm_manager manager, char** out_json) FLM_NOEXCEPT;

/**
 * Notify the core of an OS lifecycle transition. Bindings wire this to the platform's
 * notifications automatically; apps rarely call it directly.
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_notify_lifecycle(flm_manager manager,
                                                            flm_lifecycle_event event) FLM_NOEXCEPT;

/**
 * Update mutable runtime settings without recreating the manager. Currently
 * `log_level` and `auto_unload_on_background`.
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_update_settings(flm_manager manager,
                                                           const char* settings_json) FLM_NOEXCEPT;

/* =========================================================================
 * Model loading
 *
 * The SDK is path-only: callers provide a local ONNX Runtime GenAI model directory.
 * There is no catalog, no SDK-managed download, and no transport layer.
 * ========================================================================= */

/**
 * Validate a local model directory, load it through ONNX Runtime GenAI, register a
 * model handle, and return metadata.
 *
 * `model_path` must be a path to a directory containing genai_config.json (a flat OGA
 * model) or an .ortpackage directory that OGA can load.
 *
 * `options_json` may be NULL, or:
 * {
 *   "execution_provider": "QNN",     // optional: override auto-selected EP
 *   "provider_options": {            // optional: EP-specific key/value options
 *     "backend_path": "libQnnHtp.so"
 *   }
 * }
 *
 * The model path is caller-owned and must not be deleted while the model is loaded.
 *
 * The job's result is:
 * {
 *   "model_handle": 42,
 *   "path": "/data/.../models/phi",
 *   "name": "phi-4-mini",
 *   "task": "chat-completion",
 *   "execution_provider": "CPU",
 *   "device": "cpu",
 *   "file_size_bytes": 542113792,
 *   "is_loaded": true
 * }
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_load_model_async(flm_manager manager,
                                                            const char* model_path,
                                                            const char* options_json,
                                                            flm_progress_callback on_progress,
                                                            flm_completion_callback on_complete,
                                                            void* user_data,
                                                            flm_job* out_job) FLM_NOEXCEPT;

/* =========================================================================
 * Model
 *
 * An flm_model handle refers to a loaded model backed by OGA.
 * The model path is always caller-owned; the SDK never deletes it.
 * ========================================================================= */

/** Release a model handle. The underlying model files on disk are not touched. */
FLM_EXPORT flm_status FLM_CALL flm_model_release(flm_model model) FLM_NOEXCEPT;

/**
 * Model metadata as JSON. Caller frees with flm_string_free().
 */
FLM_EXPORT flm_status FLM_CALL flm_model_get_info_json(flm_model model, char** out_json) FLM_NOEXCEPT;

/** Whether the model's files are present at its path. */
FLM_EXPORT flm_status FLM_CALL flm_model_is_cached(flm_model model, int32_t* out_cached) FLM_NOEXCEPT;

/** Whether the model is currently loaded into memory. */
FLM_EXPORT flm_status FLM_CALL flm_model_is_loaded(flm_model model, int32_t* out_loaded) FLM_NOEXCEPT;

/** Absolute on-disk path. Caller frees with flm_string_free(). */
FLM_EXPORT flm_status FLM_CALL flm_model_get_path(flm_model model, char** out_path) FLM_NOEXCEPT;

/**
 * Load the model into memory (if not already loaded).
 *
 * `options_json` may be NULL, or `{ "execution_provider": "QNN" }` to override
 * the automatically selected placement.
 */
FLM_EXPORT flm_status FLM_CALL flm_model_load_async(flm_model model, const char* options_json,
                                                    flm_progress_callback on_progress,
                                                    flm_completion_callback on_complete, void* user_data,
                                                    flm_job* out_job) FLM_NOEXCEPT;

/** Unload the model, releasing its memory. Active sessions are stopped first. */
FLM_EXPORT flm_status FLM_CALL flm_model_unload_async(flm_model model, flm_completion_callback on_complete,
                                                      void* user_data, flm_job* out_job) FLM_NOEXCEPT;

/* =========================================================================
 * Sessions
 * ========================================================================= */

/**
 * Create an inference session over a loaded model.
 *
 * `options_json` may be NULL, or:
 * {
 *   "type": "chat",                  // "chat" | "audio" | "embedding", default "chat"
 *   "system_prompt": "You are ...",  // chat only
 *   "temperature": 0.7,
 *   "top_p": 0.95,
 *   "top_k": 40,
 *   "max_output_tokens": 512,
 *   "seed": 42,
 *   "language": "en",                // audio only
 *   "keep_history": true             // chat only, default true
 * }
 */
FLM_EXPORT flm_status FLM_CALL flm_session_create(flm_model model, const char* options_json,
                                                  flm_session* out_session) FLM_NOEXCEPT;

/** Release a session and free its KV cache. Cancels any in-flight request. */
FLM_EXPORT flm_status FLM_CALL flm_session_release(flm_session session) FLM_NOEXCEPT;

/** Apply option changes to an existing session. Same schema as flm_session_create. */
FLM_EXPORT flm_status FLM_CALL flm_session_set_options(flm_session session, const char* options_json) FLM_NOEXCEPT;

/** Run a chat completion, streaming deltas to `on_delta`. */
FLM_EXPORT flm_status FLM_CALL flm_session_complete_async(flm_session session, const char* request_json,
                                                          flm_delta_callback on_delta,
                                                          flm_completion_callback on_complete, void* user_data,
                                                          flm_job* out_job) FLM_NOEXCEPT;

/** Supply results for tool calls the model requested. */
FLM_EXPORT flm_status FLM_CALL flm_session_submit_tool_results_async(flm_session session, const char* tool_results_json,
                                                                     flm_delta_callback on_delta,
                                                                     flm_completion_callback on_complete,
                                                                     void* user_data, flm_job* out_job) FLM_NOEXCEPT;

/** Transcribe audio with a loaded speech model. */
FLM_EXPORT flm_status FLM_CALL flm_session_transcribe_async(flm_session session, const char* request_json,
                                                            flm_delta_callback on_delta,
                                                            flm_completion_callback on_complete, void* user_data,
                                                            flm_job* out_job) FLM_NOEXCEPT;

/** Push PCM audio into a live transcription session. */
FLM_EXPORT flm_status FLM_CALL flm_session_push_audio(flm_session session, const void* pcm_data, size_t byte_count,
                                                      int32_t sample_rate, int32_t channels,
                                                      int32_t is_final) FLM_NOEXCEPT;

/** Compute embeddings. */
FLM_EXPORT flm_status FLM_CALL flm_session_embed_async(flm_session session, const char* request_json,
                                                       flm_completion_callback on_complete, void* user_data,
                                                       flm_job* out_job) FLM_NOEXCEPT;

/** Number of completed turns in a chat session's history. */
FLM_EXPORT flm_status FLM_CALL flm_session_get_turn_count(flm_session session, size_t* out_count) FLM_NOEXCEPT;

/** Drop the last `count` turns from history and rewind the generator state. */
FLM_EXPORT flm_status FLM_CALL flm_session_undo_turns(flm_session session, size_t count) FLM_NOEXCEPT;

/** Clear all conversation history, keeping the session and its options. */
FLM_EXPORT flm_status FLM_CALL flm_session_clear_history(flm_session session) FLM_NOEXCEPT;

/** Serialize conversation history for persistence. Caller frees. */
FLM_EXPORT flm_status FLM_CALL flm_session_export_history_json(flm_session session, char** out_json) FLM_NOEXCEPT;

/** Restore history previously produced by flm_session_export_history_json(). */
FLM_EXPORT flm_status FLM_CALL flm_session_restore_history_json(flm_session session,
                                                                const char* history_json) FLM_NOEXCEPT;

/* =========================================================================
 * Jobs
 * ========================================================================= */

/** Current state of a job. */
FLM_EXPORT flm_status FLM_CALL flm_job_get_state(flm_job job, flm_job_state* out_state) FLM_NOEXCEPT;

/** Request cancellation. The completion callback fires with FLM_ERROR_CANCELLED. */
FLM_EXPORT flm_status FLM_CALL flm_job_cancel(flm_job job) FLM_NOEXCEPT;

/** Take the job's result JSON, transferring ownership to the caller. */
FLM_EXPORT flm_status FLM_CALL flm_job_take_result_json(flm_job job, char** out_json) FLM_NOEXCEPT;

/** Release a job handle. If still running, it is cancelled first. */
FLM_EXPORT flm_status FLM_CALL flm_job_release(flm_job job) FLM_NOEXCEPT;

/** Block until the job finishes or `timeout_ms` elapses (negative = wait forever). */
FLM_EXPORT flm_status FLM_CALL flm_job_wait(flm_job job, int32_t timeout_ms) FLM_NOEXCEPT;

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // FOUNDRY_LOCAL_MOBILE_FLM_API_H_
