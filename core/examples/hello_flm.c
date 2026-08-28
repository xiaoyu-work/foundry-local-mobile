/* Copyright (c) Microsoft Corporation. All rights reserved.
 * Licensed under the MIT License.
 *
 * hello_flm — a native example that walks the C ABI in the order a real host
 * uses it. The primary reason this file exists is to be *compiled* as C: the
 * public headers under core/include/foundry_local_mobile/ are consumed by four
 * FFI bindings (Kotlin/JNI, Swift, Dart, TypeScript) that each translate C.
 * A C++-only construct sneaking in would break every binding at once.
 *
 * What it actually does at runtime:
 *   1. Print flm_version_string() and flm_api_version().
 *   2. Install a log sink, exercising the log-callback typedef.
 *   3. Try to create a manager. On a machine without the OGA runtime
 *      installed this fails with FLM_ERROR_NOT_IMPLEMENTED, which we print
 *      and treat as success.
 *   4. If a model path is provided via argv[1], load it with
 *      flm_manager_load_model_async.
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "foundry_local_mobile/flm_api.h"

/* ---------- Log sink ---------- */

static void on_log(flm_log_level level, const char* tag, const char* message, void* user_data) {
    (void)user_data;
    const char* level_str = "???";
    switch (level) {
        case FLM_LOG_VERBOSE: level_str = "V"; break;
        case FLM_LOG_DEBUG:   level_str = "D"; break;
        case FLM_LOG_INFO:    level_str = "I"; break;
        case FLM_LOG_WARNING: level_str = "W"; break;
        case FLM_LOG_ERROR:   level_str = "E"; break;
        case FLM_LOG_FATAL:   level_str = "F"; break;
        case FLM_LOG_OFF:     return;
    }
    fprintf(stderr, "[%s/%s] %s\n", level_str, tag, message);
}

/* ---------- Load-model completion ---------- */

static void on_load_complete(flm_job job, flm_status status, const char* error_json, void* user_data) {
    (void)user_data;
    if (status == FLM_OK) {
        char* result = NULL;
        if (flm_job_take_result_json(job, &result) == FLM_OK && result != NULL) {
            printf("Model loaded: %s\n", result);
            flm_string_free(result);
        }
    } else {
        printf("Load failed (%d): %s\n", (int)status,
               error_json ? error_json : "(no details)");
    }
}

int main(int argc, char* argv[]) {
    flm_status status;

    printf("flm_version_string() = %s\n", flm_version_string());
    printf("flm_api_version()    = %" PRIu32 "\n", flm_api_version());
    printf("runtime available    = %s\n", flm_is_runtime_available() ? "yes" : "no");

    /* Install the log sink so any internal messages appear on stderr. */
    flm_set_log_callback(on_log, NULL);
    flm_set_log_level(FLM_LOG_INFO);

    /* Create a manager. */
    const char* config = "{\"app_name\":\"hello_flm\"}";
    flm_manager manager = FLM_INVALID_HANDLE;
    status = flm_manager_create(config, &manager);
    if (status != FLM_OK) {
        printf("flm_manager_create failed (%d): %s\n", (int)status, flm_last_error_message());
        printf("(This is expected when the OGA runtime is not installed.)\n");
        return 0;
    }

    printf("Manager created.\n");

    /* If a model path was provided, load it. */
    if (argc > 1) {
        const char* model_path = argv[1];
        printf("Loading model from: %s\n", model_path);

        flm_job job = FLM_INVALID_HANDLE;
        status = flm_manager_load_model_async(
            manager, model_path, NULL, NULL, on_load_complete, NULL, &job);
        if (status != FLM_OK) {
            printf("flm_manager_load_model_async failed (%d): %s\n",
                   (int)status, flm_last_error_message());
        } else {
            /* Wait for the job to complete. */
            flm_job_wait(job, -1);
            flm_job_release(job);
        }
    }

    /* Clean up. */
    flm_manager_shutdown(manager);
    flm_manager_release(manager);
    printf("Done.\n");
    return 0;
}
