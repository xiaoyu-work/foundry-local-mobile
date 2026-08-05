// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Foundry Local Mobile — flat C ABI.
//
// This header is the single contract shared by every platform binding (Kotlin/JNI,
// Swift, Dart FFI, React Native). It is intentionally flat: plain exported functions,
// integer handles and UTF-8 JSON for structured data, because that is the intersection
// of what JNI, dart:ffi and Swift C interop bind cleanly.
//
// Threading
//   Unless documented otherwise, every function is safe to call from any thread.
//   Functions ending in `_async` return immediately with a job handle; their work runs
//   on the core job pool and reports through callbacks. There are no blocking variants
//   of long operations, by design — no binding should be able to stall a UI thread.
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

/** Semantic version of this library. Also available at runtime via flm_version_string(). */
#define FLM_VERSION_MAJOR 0
#define FLM_VERSION_MINOR 1
#define FLM_VERSION_PATCH 0
#define FLM_VERSION_STRING "0.1.0"

/** Semantic version of this library, e.g. "0.1.0". Owned by the library. */
FLM_EXPORT const char* FLM_CALL flm_version_string(void) FLM_NOEXCEPT;

/** ABI version this build implements. Bindings compare against FLM_API_VERSION. */
FLM_EXPORT uint32_t FLM_CALL flm_api_version(void) FLM_NOEXCEPT;

/** Version of the underlying Foundry Local runtime. NULL if the runtime is unavailable. */
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

/**
 * Point the loader at the Foundry Local runtime shared library. Must be called before
 * the first flm_manager_create(); later calls have no effect.
 *
 * Needed on Android, where the reliable way to locate a bundled `.so` across OEM devices
 * is `ApplicationInfo.nativeLibraryDir` rather than the default loader search path, and
 * for apps that download the runtime after first launch to keep the initial install small.
 */
FLM_EXPORT flm_status FLM_CALL flm_set_runtime_library_path(const char* path) FLM_NOEXCEPT;

/** Whether the runtime library is present and loadable. Never throws or logs on failure. */
FLM_EXPORT int32_t FLM_CALL flm_is_runtime_available(void) FLM_NOEXCEPT;

/* =========================================================================
 * Errors
 * ========================================================================= */

/** Human-readable message for the last failure on this thread. Never NULL; "" if none. */
FLM_EXPORT const char* FLM_CALL flm_last_error_message(void) FLM_NOEXCEPT;

/**
 * Machine-readable detail for the last failure on this thread. Never NULL.
 *
 * {
 *   "code": 8,
 *   "name": "FLM_ERROR_NETWORK",
 *   "message": "catalog request failed",
 *   "retryable": true,
 *   "context": { "url": "...", "http_status": 503 }
 * }
 */
FLM_EXPORT const char* FLM_CALL flm_last_error_detail_json(void) FLM_NOEXCEPT;

/** Clear the last-error state for this thread. */
FLM_EXPORT void FLM_CALL flm_clear_last_error(void) FLM_NOEXCEPT;

/* =========================================================================
 * Manager
 *
 * The manager owns the runtime, the model cache and the job pool. Create one per
 * process; creating several is legal but they will contend for the same cache
 * directory unless configured with distinct paths.
 * ========================================================================= */

/**
 * Create a manager from a JSON configuration.
 *
 * {
 *   "app_name": "my-app",                     // required, non-empty
 *   "app_data_dir": "/data/.../files/foundry",// required on mobile: the app sandbox
 *   "model_cache_dir": "/data/.../cache",     // optional, defaults to <app_data_dir>/models
 *   "logs_dir": "/data/.../logs",             // optional
 *   "log_level": "warning",                   // optional
 *   "catalog_urls": ["https://..."],          // optional, defaults to the Foundry catalog
 *   "catalog_region": "centralus",            // optional
 *   "offline": false,                         // optional: serve only from the local cache
 *   "max_concurrent_downloads": 2,            // optional, default 2
 *   "download_on_metered_network": false,     // optional, default false
 *   "auto_unload_on_background": true,        // optional, default true
 *   "job_pool_threads": 0,                    // optional, 0 = derive from core count
 *   "additional_options": { "key": "value" }  // optional passthrough to the runtime
 * }
 *
 * `app_data_dir` is required because mobile processes cannot rely on a home directory.
 * Each binding fills it in from the platform's sandbox APIs before calling.
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_create(const char* config_json, flm_manager* out_manager) FLM_NOEXCEPT;

/**
 * Begin graceful shutdown: stop accepting work, cancel in-flight jobs, unload models.
 * Idempotent. Pending completion callbacks still fire, with FLM_ERROR_CANCELLED.
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_shutdown(flm_manager manager) FLM_NOEXCEPT;

/**
 * Release the manager. Blocks until outstanding jobs have finished unwinding, so call
 * flm_manager_shutdown() first from a context where blocking is acceptable.
 * All handles derived from this manager become invalid.
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_release(flm_manager manager) FLM_NOEXCEPT;

/** Borrow the catalog. Valid until the manager is released; release is a no-op. */
FLM_EXPORT flm_status FLM_CALL flm_manager_get_catalog(flm_manager manager, flm_catalog* out_catalog) FLM_NOEXCEPT;

/**
 * Describe the device: SoC, memory, accelerators and the resulting EP preference order.
 * Used by variant scoring and exposed to apps that implement their own download policy.
 *
 * {
 *   "platform": "android",
 *   "os_version": "14",
 *   "device_model": "Pixel 8 Pro",
 *   "soc": "Google Tensor G3",
 *   "abi": "arm64-v8a",
 *   "cpu_cores": 9,
 *   "total_memory_bytes": 12884901888,
 *   "available_memory_bytes": 4294967296,
 *   "available_storage_bytes": 53687091200,
 *   "has_npu": true,
 *   "has_gpu": true,
 *   "execution_providers": [
 *     { "name": "QNN",       "device": "npu", "available": true,  "priority": 0 },
 *     { "name": "CPU",       "device": "cpu", "available": true,  "priority": 10 }
 *   ],
 *   "thermal_state": "nominal",
 *   "low_power_mode": false,
 *   "network": "unmetered"
 * }
 *
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
 * Update mutable runtime settings without recreating the manager. Accepts the subset of
 * flm_manager_create's configuration that is not structural — currently
 * `download_on_metered_network`, `max_concurrent_downloads`, `log_level`,
 * `auto_unload_on_background` and `offline`.
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_update_settings(flm_manager manager,
                                                           const char* settings_json) FLM_NOEXCEPT;

/* =========================================================================
 * Model sources
 *
 * How an app supplies its own model, rather than taking one from the catalog. Two
 * shapes, both resolving to a directory the runtime can load.
 * ========================================================================= */

/**
 * Install the HTTP transport used for downloads. Must be called before adding a remote
 * model source; bindings do it during initialization.
 *
 * The core plans downloads but never performs them, because a multi-gigabyte transfer
 * has to survive the app being backgrounded and only the platform's own background
 * download APIs can do that. Delegating also means the app's certificate pinning, proxy
 * configuration and credential refresh apply without the core knowing anything about
 * them.
 *
 * Pass NULL to uninstall. The struct is copied; it need not outlive the call.
 */
FLM_EXPORT flm_status FLM_CALL flm_set_transport(const flm_transport* transport) FLM_NOEXCEPT;

/** Report bytes transferred for an in-flight request. Safe from any thread. */
FLM_EXPORT flm_status FLM_CALL flm_transport_report_progress(uint64_t request_id, int64_t completed_bytes,
                                                             int64_t total_bytes) FLM_NOEXCEPT;

/**
 * Deliver body bytes for an in-memory request — one whose `destination_path` was NULL.
 * Requests that name a destination are written to that file by the transport instead.
 */
FLM_EXPORT flm_status FLM_CALL flm_transport_report_body(uint64_t request_id, const char* data,
                                                         size_t size) FLM_NOEXCEPT;

/**
 * Report that a request finished. Must be called exactly once per request, including
 * after a cancel. `headers_json` may be NULL; `error_message` is NULL on success.
 */
FLM_EXPORT flm_status FLM_CALL flm_transport_report_complete(uint64_t request_id, int32_t status_code,
                                                             const char* headers_json,
                                                             const char* error_message) FLM_NOEXCEPT;

/**
 * Make an app-supplied model available locally, then return a model handle for it.
 *
 * `source_json` is one of:
 *
 * {
 *   "kind": "bundled",               // optional; inferred from "path"
 *   "name": "phi-4-mini",            // required: the name the model is registered under
 *   "path": "/data/.../models/phi",  // required: a directory the app controls
 *   "copy_into_cache": false,        // optional: copy rather than load in place
 *   "constraints": { ... }           // optional; see flm_package_select_best_variant
 * }
 *
 * {
 *   "kind": "remote",                // optional; inferred from "url"
 *   "name": "phi-4-mini",            // required
 *   "url": "https://.../manifest.json",   // required
 *   "headers": {                     // optional: sent with every request
 *     "Authorization": "Bearer ..."
 *   },
 *   "constraints": { ... }           // optional; see flm_package_select_best_variant
 * }
 *
 * Both kinds also accept:
 *   "resume": true,                  // continue a partial download, default true
 *   "verify_checksums": true         // check each file's digest, default true
 *
 * A bundled source is loaded in place by default, since the files are already on the
 * device and copying would double the storage the user pays for. In-place means the
 * cache entry is a directory of links back to "path" rather than a second copy of the
 * weights, so the app keeps owning those files: move or delete them and the cache entry
 * stops resolving. Set "copy_into_cache" when the app cannot promise the path outlives
 * the model — a staging directory, a shared-storage URI the user can clear, an asset
 * unpacked into a cache the OS may reclaim. For a package only the selected variant is
 * copied, not the whole thing.
 *
 * A remote URL may serve either a model package manifest (an object with "components")
 * or a flat file index (an object with "files"). The document is sniffed rather than the
 * URL, so a signed blob link with no meaningful path still works. When it is a package,
 * the device is scored against the variants and only the matching variant is downloaded,
 * together with the shared assets it references — on a metered connection the variants a
 * phone cannot run are routinely larger than the one it can.
 *
 * Credentials are whatever the app puts in "headers", which covers a SAS URL, an API key
 * or a bearer token with no per-provider code. A credential that must be refreshed
 * mid-download belongs in the transport, which is the app's own code.
 *
 * Downloads resume across app restarts and every file is verified against the digest in
 * the manifest before the model is committed.
 *
 * The job's result is
 * `{"name", "path", "variant_id", "bytes_downloaded", "bytes_reused", "was_cached",
 *   "model_handle"}`, plus "model_handle_unavailable" when there is no handle.
 *
 * Either kind registers the model under "name", so flm_catalog_get_model() and
 * flm_catalog_list_cached_models() find it afterwards under exactly that name, in this
 * process and in every later run.
 *
 * `model_handle` is a ready-to-use model, so there is no need to look the model up
 * through the catalog afterwards. Release it with flm_model_release() as usual —
 * releasing FLM_INVALID_HANDLE is a no-op, so an unconditional release is safe.
 *
 * ADD YOUR MODEL SOURCES BEFORE YOU ASK THE CATALOG ANYTHING. Foundry Local scans the
 * device for models once, the first time anything queries its catalog, and keeps that
 * answer for the life of the process; nothing can make it scan again. A source added
 * after that scan lands on disk but stays invisible to this run: `model_handle` is
 * FLM_INVALID_HANDLE, "model_handle_unavailable" says why, and looking the model up by
 * "name" fails too. The download itself still succeeded — the files are committed, and
 * the next launch scans a disk that already holds them and picks them up. Calling this
 * function first avoids the whole problem.
 */
FLM_EXPORT flm_status FLM_CALL flm_manager_add_model_source_async(flm_manager manager, const char* source_json,
                                                                  flm_progress_callback on_progress,
                                                                  flm_completion_callback on_complete,
                                                                  void* user_data,
                                                                  flm_job* out_job) FLM_NOEXCEPT;

/* =========================================================================
 * Catalog
 * ========================================================================= */

/**
 * List catalog models. `filter_json` may be NULL for no filtering, or:
 *
 * {
 *   "task": "chat-completion",       // optional
 *   "cached_only": false,            // optional: only models present on disk
 *   "loaded_only": false,            // optional
 *   "max_size_bytes": 2147483648,    // optional: exclude models too large for the device
 *   "compatible_only": true          // optional: exclude models with no runnable variant
 * }
 *
 * Produces a JSON array of model summaries; see flm_model_get_info_json for the shape.
 * Network access may be required, so this is async.
 */
FLM_EXPORT flm_status FLM_CALL flm_catalog_list_models_async(flm_catalog catalog, const char* filter_json,
                                                             flm_completion_callback on_complete, void* user_data,
                                                             flm_job* out_job) FLM_NOEXCEPT;

/**
 * Resolve a model by alias (e.g. "qwen2.5-0.5b"). On success the job result JSON is
 * `{ "model_handle": 42 }`; the caller owns that handle and must release it.
 */
FLM_EXPORT flm_status FLM_CALL flm_catalog_get_model_async(flm_catalog catalog, const char* alias,
                                                           flm_completion_callback on_complete, void* user_data,
                                                           flm_job* out_job) FLM_NOEXCEPT;

/** Resolve a specific variant by its unique model id, bypassing automatic selection. */
FLM_EXPORT flm_status FLM_CALL flm_catalog_get_model_by_id_async(flm_catalog catalog, const char* model_id,
                                                                 flm_completion_callback on_complete, void* user_data,
                                                                 flm_job* out_job) FLM_NOEXCEPT;

/**
 * List models already present in the local cache. Serves from disk, so it is synchronous
 * and safe to call during startup before any network is available.
 * Caller frees `out_json` with flm_string_free().
 */
FLM_EXPORT flm_status FLM_CALL flm_catalog_list_cached_models_json(flm_catalog catalog, char** out_json) FLM_NOEXCEPT;

/** Bytes currently consumed by the model cache. */
FLM_EXPORT flm_status FLM_CALL flm_catalog_get_cache_size_bytes(flm_catalog catalog, int64_t* out_bytes) FLM_NOEXCEPT;

/* =========================================================================
 * Model
 *
 * An flm_model handle refers to one of:
 *   * a catalog entry that resolves to a single set of files (a "flat" model),
 *   * an ONNX Runtime model *package* containing several variants, or
 *   * one specific variant of a package.
 *
 * flm_model_is_package() distinguishes them. Package handles delegate state queries
 * (is_cached / is_loaded) to their selected variant.
 * ========================================================================= */

/** Release a model handle. The underlying model stays in the catalog and on disk. */
FLM_EXPORT flm_status FLM_CALL flm_model_release(flm_model model) FLM_NOEXCEPT;

/**
 * Model metadata as JSON. Caller frees with flm_string_free().
 *
 * {
 *   "id": "qwen2.5-0.5b-instruct-generic-cpu:3",
 *   "alias": "qwen2.5-0.5b",
 *   "name": "qwen2.5-0.5b-instruct-generic-cpu",
 *   "display_name": "Qwen2.5 0.5B Instruct",
 *   "version": 3,
 *   "publisher": "Alibaba",
 *   "license": "apache-2.0",
 *   "task": "chat-completion",
 *   "device": "cpu",
 *   "execution_provider": "CPUExecutionProvider",
 *   "file_size_bytes": 542113792,
 *   "context_length": 32768,
 *   "max_output_tokens": 4096,
 *   "supports_tool_calling": true,
 *   "supports_reasoning": false,
 *   "input_modalities": ["text"],
 *   "output_modalities": ["text"],
 *   "is_package": true,
 *   "is_cached": false,
 *   "is_loaded": false,
 *   "prompt_templates": { "chat": "..." }
 * }
 */
FLM_EXPORT flm_status FLM_CALL flm_model_get_info_json(flm_model model, char** out_json) FLM_NOEXCEPT;

/** Whether the model's files are fully present in the local cache. */
FLM_EXPORT flm_status FLM_CALL flm_model_is_cached(flm_model model, int32_t* out_cached) FLM_NOEXCEPT;

/** Whether the model is currently loaded into memory. */
FLM_EXPORT flm_status FLM_CALL flm_model_is_loaded(flm_model model, int32_t* out_loaded) FLM_NOEXCEPT;

/** Absolute on-disk path, or an empty string when not cached. Caller frees. */
FLM_EXPORT flm_status FLM_CALL flm_model_get_path(flm_model model, char** out_path) FLM_NOEXCEPT;

/**
 * Download the model.
 *
 * Succeeds when the model's files are already on the device, which is the state
 * flm_manager_add_model_source_async() leaves them in; the result then reports the
 * cached path. There is no catalog fetch: the Foundry Local catalog publishes desktop
 * builds (CUDA, DirectML, OpenVINO, x64), which on a phone are gigabytes with no
 * execution provider that can run them. A model that is not on the device returns
 * FLM_ERROR_NOT_IMPLEMENTED naming flm_manager_add_model_source_async(), which is how a
 * mobile app supplies a model: bundled in the app, or downloaded from a URL the app
 * hosts, picking the variant this device can actually run.
 *
 * `options_json` is accepted and ignored; it exists so the call keeps the shape of the
 * other async operations.
 *
 * Result: `{ "path": "/data/.../models/qwen2.5-0.5b", "bytes": 542113792 }`.
 */
FLM_EXPORT flm_status FLM_CALL flm_model_download_async(flm_model model, const char* options_json,
                                                        flm_progress_callback on_progress,
                                                        flm_completion_callback on_complete, void* user_data,
                                                        flm_job* out_job) FLM_NOEXCEPT;

/**
 * Load the model into memory.
 *
 * The model's files must already be on the device; add it with
 * flm_manager_add_model_source_async() first. Loading a model that is not present
 * returns FLM_ERROR_NOT_IMPLEMENTED.
 *
 * `options_json` may be NULL, or `{ "execution_provider": "QNN", "device": "npu" }` to
 * override the automatically selected placement.
 */
FLM_EXPORT flm_status FLM_CALL flm_model_load_async(flm_model model, const char* options_json,
                                                    flm_progress_callback on_progress,
                                                    flm_completion_callback on_complete, void* user_data,
                                                    flm_job* out_job) FLM_NOEXCEPT;

/** Unload the model, releasing its memory. Active sessions are stopped first. */
FLM_EXPORT flm_status FLM_CALL flm_model_unload_async(flm_model model, flm_completion_callback on_complete,
                                                      void* user_data, flm_job* out_job) FLM_NOEXCEPT;

/** Delete the model's files from the local cache. Unloads first if loaded. */
FLM_EXPORT flm_status FLM_CALL flm_model_delete_async(flm_model model, flm_completion_callback on_complete,
                                                      void* user_data, flm_job* out_job) FLM_NOEXCEPT;

/* =========================================================================
 * Model packages
 *
 * An ONNX Runtime model package bundles several build variants of the same model —
 * per execution provider, device and compatibility string — behind one manifest,
 * plus content-addressed shared assets that variants reference instead of duplicating.
 *
 * This matters most for cross-platform apps: the same catalog entry yields a QNN/NPU
 * variant on a Snapdragon phone, a CoreML variant on iOS and a CPU variant elsewhere.
 * The app can inspect the variants and apply its own policy, or let the SDK choose.
 * ========================================================================= */

/** Whether this handle refers to a model package (as opposed to a flat model). */
FLM_EXPORT flm_status FLM_CALL flm_model_is_package(flm_model model, int32_t* out_is_package) FLM_NOEXCEPT;

/**
 * Enumerate the package's variants, scored against this device.
 * Returns FLM_ERROR_INVALID_STATE for a non-package handle.
 * Caller frees `out_json` with flm_string_free().
 *
 * {
 *   "package_id": "qwen2.5-0.5b",
 *   "schema_version": "1.0",
 *   "selected_variant_id": "qwen2.5-0.5b.qnn-npu",
 *   "shared_assets_bytes": 402653184,
 *   "variants": [
 *     {
 *       "id": "qwen2.5-0.5b.qnn-npu",
 *       "component": "model",
 *       "execution_provider": "QNN",
 *       "device": "npu",
 *       "compatibility_string": "soc_model=43;dsp_arch=v75",
 *       "platform": "android",
 *       "download_size_bytes": 618659840,
 *       "disk_size_bytes": 618659840,
 *       "shared_asset_refs": ["sha256:9f86d0..."],
 *       "is_compatible": true,
 *       "compatibility_score": 95,
 *       "is_cached": false,
 *       "incompatibility_reason": null
 *     },
 *     {
 *       "id": "qwen2.5-0.5b.cpu",
 *       "component": "model",
 *       "execution_provider": "CPU",
 *       "device": "cpu",
 *       "compatibility_string": "",
 *       "platform": "any",
 *       "download_size_bytes": 542113792,
 *       "disk_size_bytes": 542113792,
 *       "shared_asset_refs": ["sha256:9f86d0..."],
 *       "is_compatible": true,
 *       "compatibility_score": 10,
 *       "is_cached": true,
 *       "incompatibility_reason": null
 *     }
 *   ]
 * }
 *
 * `download_size_bytes` already excludes shared assets that are present on disk, so it
 * is what the user would actually transfer. `compatibility_score` is the EP-defined
 * score used for automatic selection; higher wins.
 */
FLM_EXPORT flm_status FLM_CALL flm_package_get_variants_json(flm_model package, char** out_json) FLM_NOEXCEPT;

/**
 * Pin the package to a specific variant. Subsequent download/load/session calls on the
 * package handle act on it. Returns FLM_ERROR_NOT_FOUND for an unknown variant id.
 *
 * This is the hook for an app's own cross-platform policy — for example "never download
 * more than 800 MB on this tier of device", or "prefer NPU on Android and CPU on
 * older iPhones".
 */
FLM_EXPORT flm_status FLM_CALL flm_package_select_variant(flm_model package, const char* variant_id) FLM_NOEXCEPT;

/**
 * Let the SDK pick the best variant for this device using the device profile and the
 * variants' compatibility scores.
 *
 * `constraints_json` may be NULL, or any subset of:
 * {
 *   "max_download_bytes": 838860800,   // skip variants larger than this
 *   "allowed_devices": ["npu", "cpu"], // restrict placement; empty or absent means any
 *   "prefer_smallest": false,          // tie-break on size instead of score
 *   "require_cached": false            // only consider variants already on disk
 * }
 *
 * Those four keys are the whole vocabulary; any other key is ignored silently. The same
 * object is accepted as "constraints" on a model source, where it picks the variant
 * before any weights transfer — which is how a cross-platform app ships one build and
 * still downloads only the variant its device can run.
 *
 * Writes the chosen variant id to `out_variant_id` (caller frees). Returns
 * FLM_ERROR_INCOMPATIBLE when no variant satisfies the constraints.
 */
FLM_EXPORT flm_status FLM_CALL flm_package_select_best_variant(flm_model package, const char* constraints_json,
                                                               char** out_variant_id) FLM_NOEXCEPT;

/**
 * Obtain a standalone handle for one variant, for apps that want to manage several
 * variants independently (e.g. download an NPU variant while a CPU variant serves
 * requests). Caller owns the returned handle.
 */
FLM_EXPORT flm_status FLM_CALL flm_package_get_variant(flm_model package, const char* variant_id,
                                                       flm_model* out_variant) FLM_NOEXCEPT;

/**
 * Estimate the transfer for a set of variants before committing to it — the sum of the
 * variants' own files plus the union of the shared assets they reference, minus what is
 * already on disk. Shared assets are counted once, which a naive per-variant sum gets
 * wrong.
 *
 * `variant_ids_json` is a JSON array of ids, or NULL for the currently selected variant.
 *
 * {
 *   "download_bytes": 618659840,
 *   "disk_bytes": 1021313024,
 *   "already_cached_bytes": 402653184,
 *   "available_storage_bytes": 53687091200,
 *   "fits_on_device": true
 * }
 */
FLM_EXPORT flm_status FLM_CALL flm_package_estimate_download_json(flm_model package, const char* variant_ids_json,
                                                                  char** out_json) FLM_NOEXCEPT;

/* =========================================================================
 * Sessions
 * ========================================================================= */

/**
 * Create an inference session over a loaded model.
 *
 * The runtime chooses a session implementation from the model's task, and it learns tasks
 * from the Foundry Local catalog. A model added through flm_manager_add_model_source_async
 * under a name the catalog recognises therefore works normally. A model under a name the
 * catalog has never seen has no task, and this returns FLM_ERROR_NOT_IMPLEMENTED naming
 * that as the reason — everything before it succeeds, so the model installs, is
 * discoverable and loads, which is what makes the limit easy to mistake for a bug here.
 * Nothing in the ABI can set a model's task, so name a source after the catalog model it
 * actually is.
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

/**
 * Run a chat completion, streaming deltas to `on_delta`.
 *
 * `request_json` is an OpenAI-shaped request:
 * {
 *   "messages": [
 *     { "role": "system", "content": "You are a helpful assistant." },
 *     { "role": "user", "content": [
 *         { "type": "text", "text": "What is in this image?" },
 *         { "type": "image", "path": "/sdcard/photo.jpg" }
 *     ]}
 *   ],
 *   "tools": [ { "name": "get_weather", "description": "...", "parameters": { } } ],
 *   "tool_choice": "auto",
 *   "temperature": 0.7,
 *   "max_output_tokens": 512
 * }
 *
 * Content may be a plain string or an array of parts. Image and audio parts accept
 * either `path` (a file in the app sandbox) or `data_base64`.
 *
 * `on_delta` may be NULL for a non-streaming call; the full text is then available in
 * the job result JSON.
 */
FLM_EXPORT flm_status FLM_CALL flm_session_complete_async(flm_session session, const char* request_json,
                                                          flm_delta_callback on_delta,
                                                          flm_completion_callback on_complete, void* user_data,
                                                          flm_job* out_job) FLM_NOEXCEPT;

/**
 * Supply results for tool calls the model requested, continuing the turn.
 *
 * `tool_results_json`:
 * [ { "call_id": "call_1", "result": "{\"temp_c\": 21}" } ]
 */
FLM_EXPORT flm_status FLM_CALL flm_session_submit_tool_results_async(flm_session session, const char* tool_results_json,
                                                                     flm_delta_callback on_delta,
                                                                     flm_completion_callback on_complete,
                                                                     void* user_data, flm_job* out_job) FLM_NOEXCEPT;

/**
 * Transcribe audio with a loaded speech model.
 *
 * `request_json`:
 * { "path": "/data/.../recording.wav", "language": "en", "translate": false }
 * or
 * { "data_base64": "...", "format": "pcm", "sample_rate": 16000, "channels": 1 }
 */
FLM_EXPORT flm_status FLM_CALL flm_session_transcribe_async(flm_session session, const char* request_json,
                                                            flm_delta_callback on_delta,
                                                            flm_completion_callback on_complete, void* user_data,
                                                            flm_job* out_job) FLM_NOEXCEPT;

/**
 * Push a chunk of PCM audio into a live transcription session, for microphone capture.
 * Call flm_session_transcribe_async with `{ "streaming": true }` first; partial and final
 * segments arrive on that job's delta callback.
 */
FLM_EXPORT flm_status FLM_CALL flm_session_push_audio(flm_session session, const void* pcm_data, size_t byte_count,
                                                      int32_t sample_rate, int32_t channels,
                                                      int32_t is_final) FLM_NOEXCEPT;

/**
 * Compute embeddings. `request_json` is `{ "inputs": ["text one", "text two"] }`.
 * The job result is `{ "embeddings": [[0.1, ...], [0.2, ...]], "dimensions": 384 }`.
 */
FLM_EXPORT flm_status FLM_CALL flm_session_embed_async(flm_session session, const char* request_json,
                                                       flm_completion_callback on_complete, void* user_data,
                                                       flm_job* out_job) FLM_NOEXCEPT;

/** Number of completed turns in a chat session's history. */
FLM_EXPORT flm_status FLM_CALL flm_session_get_turn_count(flm_session session, size_t* out_count) FLM_NOEXCEPT;

/** Drop the last `count` turns from history and rewind the generator state. */
FLM_EXPORT flm_status FLM_CALL flm_session_undo_turns(flm_session session, size_t count) FLM_NOEXCEPT;

/** Clear all conversation history, keeping the session and its options. */
FLM_EXPORT flm_status FLM_CALL flm_session_clear_history(flm_session session) FLM_NOEXCEPT;

/**
 * Serialize conversation history so it can be restored after the process is killed —
 * routine on mobile. Caller frees. Restore with flm_session_restore_history_json().
 */
FLM_EXPORT flm_status FLM_CALL flm_session_export_history_json(flm_session session, char** out_json) FLM_NOEXCEPT;

/** Restore history previously produced by flm_session_export_history_json(). */
FLM_EXPORT flm_status FLM_CALL flm_session_restore_history_json(flm_session session,
                                                                const char* history_json) FLM_NOEXCEPT;

/* =========================================================================
 * Jobs
 * ========================================================================= */

/** Current state of a job. */
FLM_EXPORT flm_status FLM_CALL flm_job_get_state(flm_job job, flm_job_state* out_state) FLM_NOEXCEPT;

/**
 * Request cancellation. Returns immediately; the completion callback fires with
 * FLM_ERROR_CANCELLED once the job unwinds. Cancelling a finished job is a no-op.
 */
FLM_EXPORT flm_status FLM_CALL flm_job_cancel(flm_job job) FLM_NOEXCEPT;

/**
 * Take the job's result JSON, transferring ownership to the caller (subsequent calls
 * return NULL). Valid once the job has succeeded. Shape depends on the operation:
 *
 *   catalog list      { "models": [ ... ] }             // entries as flm_model_get_info_json
 *   catalog get       { "model_handle": 42 }
 *   add model source  { "name": "phi-4-mini",
 *                       "path": "/data/.../models/phi-4-mini",
 *                       "variant_id": "cpu-int4",       // "" when not a package
 *                       "bytes_downloaded": 542113792,
 *                       "bytes_reused": 0,              // already on disk, not refetched
 *                       "was_cached": false,            // true if nothing had to be fetched
 *                       "model_handle": 42 }            // ready to use; no catalog lookup needed
 *   load              { "path": "/data/.../models/qwen2.5-0.5b", "bytes": 542113792 }
 *   download          { "path": "...", "bytes": 542113792 }   // only when already cached
 *   complete          { "text": "...",
 *                       "finish_reason": "stop",        // stop | length | tool_calls | cancelled | error | none
 *                       "tool_calls": [ { "call_id": "c1",
 *                                         "name": "get_weather",
 *                                         "arguments": "{\"city\":\"Paris\"}" } ],
 *                       "usage": { "prompt_tokens": 12,
 *                                  "completion_tokens": 40,
 *                                  "total_tokens": 52 } }
 *   transcribe        { "text": "...", "language": "en",
 *                       "segments": [ { "text": "...",
 *                                       "start_time_ms": 0,
 *                                       "end_time_ms": 1500,
 *                                       "language": "en" } ] }
 *   embed             { "embeddings": [ [0.1, ...], [0.2, ...] ], "dimensions": 384 }
 *
 * `tool_calls` is absent when the model called no tools, and `arguments` is a JSON
 * *string* to be parsed, not an object — the model may emit something that does not
 * match the declared schema, and failing to parse it is the app's decision, not ours.
 * `usage` is absent if the runtime reported no token counts.
 */
FLM_EXPORT flm_status FLM_CALL flm_job_take_result_json(flm_job job, char** out_json) FLM_NOEXCEPT;

/**
 * Release a job handle. Safe to call from the completion callback. If the job is still
 * running it is cancelled first and its resources are reclaimed asynchronously.
 */
FLM_EXPORT flm_status FLM_CALL flm_job_release(flm_job job) FLM_NOEXCEPT;

/**
 * Block until the job finishes or `timeout_ms` elapses (negative = wait forever).
 *
 * Provided for tests, CLI tools and binding internals that already run on a worker
 * thread. Never call it from a UI thread; the bindings' public APIs do not expose it.
 */
FLM_EXPORT flm_status FLM_CALL flm_job_wait(flm_job job, int32_t timeout_ms) FLM_NOEXCEPT;

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // FOUNDRY_LOCAL_MOBILE_FLM_API_H_
