// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Small ObjC++ export unit that force-preserves the C ABI symbols from the
// core static library so `DynamicLibrary.process()` can find them.
//
// Under Cocoapods a static library only has its symbols pulled in if a source
// file in the .app references them. This file references every exported entry
// point via a table so the linker does not strip the C ABI when the Dart side
// is the only consumer.

#import <Foundation/Foundation.h>
#include "foundry_local_mobile/flm_api.h"

__attribute__((visibility("default")))
void* FoundryLocalMobile_KeepSymbols(int index) {
    // clang-format off
    static void* const symbols[] = {
        (void*)&flm_string_free,
        (void*)&flm_last_error_message,
        (void*)&flm_last_error_detail_json,
        (void*)&flm_get_log_level,
        (void*)&flm_set_log_level,
        (void*)&flm_set_log_callback,
        (void*)&flm_get_version,
        (void*)&flm_get_build_info,

        (void*)&flm_manager_create,
        (void*)&flm_manager_release,
        (void*)&flm_manager_get_catalog,
        (void*)&flm_manager_get_device_profile,
        (void*)&flm_manager_update_settings,
        (void*)&flm_manager_notify_lifecycle,
        (void*)&flm_manager_add_model_source,
        (void*)&flm_manager_shutdown,

        (void*)&flm_catalog_release,
        (void*)&flm_catalog_list_models_async,
        (void*)&flm_catalog_get_model_async,
        (void*)&flm_catalog_get_model_by_id_async,
        (void*)&flm_catalog_list_cached_models_json,
        (void*)&flm_catalog_cache_size_bytes,

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
        (void*)&flm_model_get_manifest_json,
        (void*)&flm_model_list_variants_json,
        (void*)&flm_model_select_variant_async,
        (void*)&flm_model_select_best_variant_async,
        (void*)&flm_model_get_variant_async,
        (void*)&flm_model_estimate_download_async,

        (void*)&flm_session_create,
        (void*)&flm_session_release,
        (void*)&flm_session_complete_async,
        (void*)&flm_session_complete_streaming_async,
        (void*)&flm_session_submit_tool_results_async,
        (void*)&flm_session_transcribe_file_async,
        (void*)&flm_session_start_streaming_async,
        (void*)&flm_session_push_audio,
        (void*)&flm_session_embed_async,
        (void*)&flm_session_turn_count,
        (void*)&flm_session_undo_turns,
        (void*)&flm_session_clear_history,
        (void*)&flm_session_export_history,
        (void*)&flm_session_restore_history,

        (void*)&flm_job_wait,
        (void*)&flm_job_cancel,
        (void*)&flm_job_get_state,
        (void*)&flm_job_take_result_json,
        (void*)&flm_job_release,

        (void*)&flm_set_transport,
        (void*)&flm_transport_report_progress,
        (void*)&flm_transport_report_body,
        (void*)&flm_transport_report_complete,
    };
    // clang-format on
    NSInteger const count = sizeof(symbols) / sizeof(symbols[0]);
    if (index < 0 || index >= count) return NULL;
    return symbols[index];
}
