/* Copyright (c) Microsoft Corporation. All rights reserved.
 * Licensed under the MIT License.
 *
 * hello_flm — a native example that walks the C ABI in the order a real host
 * uses it. The primary reason this file exists is to be *compiled* as C: the
 * public headers under core/include/foundry_local_mobile/ are consumed by four
 * FFI bindings (Kotlin/JNI, Swift, Dart, TypeScript) that each translate C.
 * A C++-only construct sneaking in (a default argument, `nullptr`, a `bool`
 * without <stdbool.h>, a struct field named `class`, an enum trailing comma
 * issue) breaks every binding at once and would not otherwise be caught until
 * an app build. Compiling this file with a C compiler under -Werror turns any
 * of those into a CI failure on the offending PR.
 *
 * What it actually does at runtime:
 *   1. Print flm_version_string() and flm_api_version() so version drift shows
 *      up in build logs.
 *   2. Install a log sink, exercising the log-callback typedef.
 *   3. Install a minimal HTTP transport that serves file:// URLs, exercising
 *      the transport callback surface. Nothing here downloads anything, but
 *      the callback types have to compile as C and the transport struct has
 *      to be initialisable from C code.
 *   4. Try to create a manager. On a machine without the upstream Foundry
 *      Local runtime installed this fails with FLM_ERROR_NOT_IMPLEMENTED,
 *      which we print and treat as success — the example must not fail the
 *      build on a plain CI runner. If the runtime *is* present, we release
 *      the manager cleanly.
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "foundry_local_mobile/flm_api.h"

/* -------------------------------------------------------------------------
 * Log sink. Everything at INFO and above ends up on stderr; the level filter
 * is set by flm_set_log_level below.
 * ------------------------------------------------------------------------- */

static void FLM_CALLBACK example_log_sink(flm_log_level level, const char* tag, const char* message,
                                          void* user_data) {
    const char* label = "?";
    (void)user_data;
    switch (level) {
        case FLM_LOG_VERBOSE: label = "verbose"; break;
        case FLM_LOG_DEBUG:   label = "debug";   break;
        case FLM_LOG_INFO:    label = "info";    break;
        case FLM_LOG_WARNING: label = "warn";    break;
        case FLM_LOG_ERROR:   label = "error";   break;
        case FLM_LOG_FATAL:   label = "fatal";   break;
        case FLM_LOG_OFF:     return;
    }
    fprintf(stderr, "[flm][%s][%s] %s\n", label, tag != NULL ? tag : "-", message != NULL ? message : "");
}

/* -------------------------------------------------------------------------
 * Transport. Contract, from flm_types.h and flm_api.h:
 *
 *   * When destination_path != NULL the transport writes the file itself and
 *     must NOT call flm_transport_report_body. When offset > 0 it opens the
 *     file for append and seeks the source, rather than truncating (which
 *     would silently corrupt an in-progress model download).
 *   * When destination_path == NULL the body is delivered through
 *     flm_transport_report_body.
 *   * flm_transport_report_complete is called exactly once per request on
 *     every path, including every error branch.
 *
 * We only handle file:// URLs — anything else short-circuits with an error
 * report. That is enough to exercise the callback types; nothing in this
 * example actually downloads.
 * ------------------------------------------------------------------------- */

static const char kFileScheme[] = "file://";

static int fail_request(uint64_t request_id, int32_t status_code, const char* message) {
    flm_transport_report_complete(request_id, status_code, NULL, message);
    return 0;
}

static int32_t FLM_CALLBACK example_transport_send(const flm_http_request* request, void* user_data) {
    FILE* in = NULL;
    FILE* out = NULL;
    char buffer[8192];
    int64_t total = 0;
    size_t n;
    const char* path;

    (void)user_data;

    if (request == NULL || request->url == NULL) {
        /* Nothing to report against; the core validated the pointer, so this
         * is just defensive. Return non-zero so the core does not wait for
         * a completion we cannot deliver. */
        return 1;
    }

    if (strncmp(request->url, kFileScheme, sizeof kFileScheme - 1) != 0) {
        return fail_request(request->request_id, 501, "example transport only supports file:// URLs");
    }
    path = request->url + sizeof kFileScheme - 1;

    in = fopen(path, "rb");
    if (in == NULL) {
        return fail_request(request->request_id, 404, "no such file");
    }
    if (request->offset > 0 && fseek(in, (long)request->offset, SEEK_SET) != 0) {
        fclose(in);
        return fail_request(request->request_id, 416, "cannot seek to offset");
    }

    if (request->destination_path != NULL) {
        out = fopen(request->destination_path, request->offset > 0 ? "ab" : "wb");
        if (out == NULL) {
            fclose(in);
            return fail_request(request->request_id, 500, "cannot open destination");
        }
        while ((n = fread(buffer, 1, sizeof buffer, in)) > 0) {
            if (fwrite(buffer, 1, n, out) != n) {
                fclose(out);
                fclose(in);
                return fail_request(request->request_id, 500, "short write");
            }
            total += (int64_t)n;
            flm_transport_report_progress(request->request_id, total, request->expected_bytes);
        }
        fclose(out);
    } else {
        while ((n = fread(buffer, 1, sizeof buffer, in)) > 0) {
            flm_transport_report_body(request->request_id, buffer, n);
            total += (int64_t)n;
            flm_transport_report_progress(request->request_id, total, request->expected_bytes);
        }
    }
    fclose(in);

    flm_transport_report_complete(request->request_id, 200, NULL, NULL);
    return 0;
}

static void FLM_CALLBACK example_transport_cancel(uint64_t request_id, void* user_data) {
    /* Synchronous transport: send() runs to completion before returning, so
     * there is never anything in flight to cancel. */
    (void)request_id;
    (void)user_data;
}

/* -------------------------------------------------------------------------
 * Main.
 * ------------------------------------------------------------------------- */

int main(void) {
    flm_status status;
    flm_transport transport;
    flm_manager manager = FLM_INVALID_HANDLE;
    const char* runtime_version;
    const char* config_json =
        "{"
        "\"app_name\":\"hello_flm\","
        "\"app_data_dir\":\"./hello_flm_data\""
        "}";

    printf("foundry_local_mobile %s (ABI %u)\n", flm_version_string(), (unsigned)flm_api_version());
    runtime_version = flm_runtime_version_string();
    printf("underlying runtime: %s\n", runtime_version != NULL ? runtime_version : "(unavailable)");
    printf("runtime available: %s\n", flm_is_runtime_available() != 0 ? "yes" : "no");

    status = flm_set_log_callback(example_log_sink, NULL);
    if (status != FLM_OK) {
        fprintf(stderr, "flm_set_log_callback failed (%d): %s\n", (int)status, flm_last_error_message());
        return 1;
    }
    flm_set_log_level(FLM_LOG_INFO);

    memset(&transport, 0, sizeof transport);
    transport.version = FLM_API_VERSION;
    transport.send = example_transport_send;
    transport.cancel = example_transport_cancel;
    transport.user_data = NULL;
    status = flm_set_transport(&transport);
    if (status != FLM_OK) {
        fprintf(stderr, "flm_set_transport failed (%d): %s\n", (int)status, flm_last_error_message());
        flm_set_log_callback(NULL, NULL);
        return 1;
    }

    status = flm_manager_create(config_json, &manager);
    if (status == FLM_OK) {
        char* profile_json = NULL;
        printf("manager created: handle=%" PRIu64 "\n", (uint64_t)manager);

        if (flm_manager_get_device_profile_json(manager, &profile_json) == FLM_OK && profile_json != NULL) {
            printf("device profile: %s\n", profile_json);
        }
        flm_string_free(profile_json);

        flm_manager_shutdown(manager);
        flm_manager_release(manager);
    } else {
        /* The typical case on a CI runner and on any developer machine without
         * the upstream Foundry Local runtime installed: the loader cannot find
         * the runtime .so/.dylib and the core reports FLM_ERROR_NOT_IMPLEMENTED
         * with a descriptive message. Print it and exit 0 — this example is a
         * build-time compatibility check, and it must not fail the build on
         * machines where the runtime is legitimately absent. */
        printf("flm_manager_create returned %d: %s\n", (int)status, flm_last_error_message());
        printf("expected on a machine without the Foundry Local runtime; treating as success.\n");
        flm_clear_last_error();
    }

    /* Uninstall the transport before the process exits so the runtime does not
     * hold a dangling function pointer into a soon-to-be-unmapped image if
     * anything above scheduled a callback we did not observe. */
    flm_set_transport(NULL);
    flm_set_log_callback(NULL, NULL);
    return 0;
}
