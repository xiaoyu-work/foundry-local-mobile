// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Small ObjC++ export unit that force-preserves the C ABI symbols from the
// core static library so `DynamicLibrary.process()` can find them at runtime.
//
// Under CocoaPods a static library only contributes symbols the linker sees
// used from an object file that is not itself an archive. Since the only
// caller of `flm_*` is `dart:ffi`, and `dart:ffi` resolves symbols at runtime,
// the linker would happily drop the whole ABI. This file makes every export
// reachable through one symbol so `-force_load` isn't required in the app's
// Podfile.

#import <Foundation/Foundation.h>
#include "foundry_local_mobile/flm_api.h"
#include "flm_dart_bridge.h"

__attribute__((visibility("default")))
void* FoundryLocalMobile_KeepSymbols(int index) {
    // clang-format off
    static void* const symbols[] = {
        // Global helpers -----------------------------------------------------
        (void*)&flm_version_string,
        (void*)&flm_api_version,
        (void*)&flm_runtime_version_string,
        (void*)&flm_string_free,
        (void*)&flm_set_log_callback,
        (void*)&flm_set_log_level,
        (void*)&flm_set_runtime_library_path,
        (void*)&flm_is_runtime_available,
        (void*)&flm_last_error_message,
        (void*)&flm_last_error_detail_json,
        (void*)&flm_clear_last_error,

        // Manager ------------------------------------------------------------
        (void*)&flm_manager_create,
        (void*)&flm_manager_shutdown,
        (void*)&flm_manager_release,
        (void*)&flm_manager_get_catalog,
        (void*)&flm_manager_get_device_profile_json,
        (void*)&flm_manager_notify_lifecycle,
        (void*)&flm_manager_update_settings,
        (void*)&flm_manager_add_model_source_async,

        // Transport ----------------------------------------------------------
        (void*)&flm_set_transport,
        (void*)&flm_transport_report_progress,
        (void*)&flm_transport_report_body,
        (void*)&flm_transport_report_complete,

        // Catalog ------------------------------------------------------------
        (void*)&flm_catalog_list_models_async,
        (void*)&flm_catalog_get_model_async,
        (void*)&flm_catalog_get_model_by_id_async,
        (void*)&flm_catalog_list_cached_models_json,
        (void*)&flm_catalog_get_cache_size_bytes,

        // Model --------------------------------------------------------------
        (void*)&flm_model_release,
        (void*)&flm_model_get_info_json,
        (void*)&flm_model_is_cached,
        (void*)&flm_model_is_loaded,
        (void*)&flm_model_get_path,
        (void*)&flm_model_download_async,
        (void*)&flm_model_load_async,
        (void*)&flm_model_unload_async,
        (void*)&flm_model_delete_async,
        (void*)&flm_model_is_package,

        // Model packages -----------------------------------------------------
        (void*)&flm_package_get_variants_json,
        (void*)&flm_package_select_variant,
        (void*)&flm_package_select_best_variant,
        (void*)&flm_package_get_variant,
        (void*)&flm_package_estimate_download_json,

        // Sessions -----------------------------------------------------------
        (void*)&flm_session_create,
        (void*)&flm_session_release,
        (void*)&flm_session_set_options,
        (void*)&flm_session_complete_async,
        (void*)&flm_session_submit_tool_results_async,
        (void*)&flm_session_transcribe_async,
        (void*)&flm_session_push_audio,
        (void*)&flm_session_embed_async,
        (void*)&flm_session_get_turn_count,
        (void*)&flm_session_undo_turns,
        (void*)&flm_session_clear_history,
        (void*)&flm_session_export_history_json,
        (void*)&flm_session_restore_history_json,

        // Job control --------------------------------------------------------
        (void*)&flm_job_get_state,
        (void*)&flm_job_cancel,
        (void*)&flm_job_take_result_json,
        (void*)&flm_job_release,
        (void*)&flm_job_wait,

        // Dart bridge trampolines (in the same static library, otherwise ffi
        // could not resolve them either). -----------------------------------
        (void*)&flm_dart_bridge_progress,
        (void*)&flm_dart_bridge_delta,
        (void*)&flm_dart_bridge_complete,
        (void*)&flm_dart_bridge_send,
        (void*)&flm_dart_bridge_free_progress,
        (void*)&flm_dart_bridge_free_delta,
        (void*)&flm_dart_bridge_free_string,
    };
    // clang-format on
    NSInteger const count = sizeof(symbols) / sizeof(symbols[0]);
    if (index < 0 || index >= count) return NULL;
    return symbols[index];
}
