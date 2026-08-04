// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "flm_dart_bridge.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// -----------------------------------------------------------------------------
// String copy helpers.
//
// Both return heap-owned NUL-terminated strings, or NULL if the input is NULL
// or the allocation fails. We roll our own instead of using strdup so the
// same code compiles on MSVC (where strdup is deprecated in favour of the
// non-standard _strdup) and so the length-aware variant handles a fragment
// with embedded NULs the same way — the delta text field carries an explicit
// text_length precisely because it may be neither NUL-free nor NUL-terminated.
// -----------------------------------------------------------------------------

static char* copy_c_string(const char* s) {
  if (s == NULL) return NULL;
  size_t n = strlen(s);
  char* out = (char*)malloc(n + 1);
  if (out == NULL) return NULL;
  memcpy(out, s, n + 1);
  return out;
}

static char* copy_length_prefixed(const char* s, size_t n) {
  if (s == NULL) return NULL;
  char* out = (char*)malloc(n + 1);
  if (out == NULL) return NULL;
  if (n > 0) memcpy(out, s, n);
  out[n] = '\0';
  return out;
}

// -----------------------------------------------------------------------------
// Trampolines. These run synchronously on a core job-pool thread, while the
// borrowed struct and its strings are still valid, and deep-copy everything
// they hand to the Dart listener.
// -----------------------------------------------------------------------------

int32_t flm_dart_bridge_progress(flm_job job, const flm_progress* progress, void* user_data) {
  const flm_dart_bridge_ctx* ctx = (const flm_dart_bridge_ctx*)user_data;
  if (ctx == NULL || ctx->on_progress == NULL || progress == NULL) return 0;

  flm_progress* owned = (flm_progress*)malloc(sizeof(flm_progress));
  if (owned == NULL) {
    // No way to signal this back to the core meaningfully; drop the event
    // rather than hand Dart a bad pointer. Progress is advisory.
    return 0;
  }
  *owned = *progress;
  owned->stage = copy_c_string(progress->stage);
  owned->detail = copy_c_string(progress->detail);
  ctx->on_progress(job, owned, ctx->user_data);
  return 0;
}

int32_t flm_dart_bridge_delta(flm_job job, const flm_delta* delta, void* user_data) {
  const flm_dart_bridge_ctx* ctx = (const flm_dart_bridge_ctx*)user_data;
  if (ctx == NULL || ctx->on_delta == NULL || delta == NULL) return 0;

  flm_delta* owned = (flm_delta*)malloc(sizeof(flm_delta));
  if (owned == NULL) return 0;
  *owned = *delta;
  owned->text = copy_length_prefixed(delta->text, delta->text_length);
  owned->tool_call_id = copy_c_string(delta->tool_call_id);
  owned->tool_name = copy_c_string(delta->tool_name);
  owned->tool_arguments_json = copy_c_string(delta->tool_arguments_json);
  ctx->on_delta(job, owned, ctx->user_data);
  return 0;
}

void flm_dart_bridge_complete(flm_job job, flm_status status, const char* error_json, void* user_data) {
  const flm_dart_bridge_ctx* ctx = (const flm_dart_bridge_ctx*)user_data;
  if (ctx == NULL || ctx->on_complete == NULL) return;
  // error_json is NULL when status == FLM_OK; copy_c_string handles that.
  char* owned_error = copy_c_string(error_json);
  ctx->on_complete(job, (int32_t)status, owned_error, ctx->user_data);
}

int32_t flm_dart_bridge_send(const flm_http_request* request, void* user_data) {
  // No copy: the core blocks in Transport::Send() until we call
  // flm_transport_report_complete, so `request` and its strings stay valid
  // across the async hand-off to the Dart listener. See the callback
  // lifetime note in flm_types.h — flm_http_request is documented as the
  // one exception to the borrowed-for-the-call rule.
  const flm_dart_bridge_ctx* ctx = (const flm_dart_bridge_ctx*)user_data;
  if (ctx != NULL && ctx->on_send != NULL) {
    ctx->on_send(request, ctx->user_data);
  }
  return 0;
}

// -----------------------------------------------------------------------------
// Free helpers. Dart calls these from the corresponding listener's finally
// block, so a throw in payload parsing cannot leak the heap allocation.
// -----------------------------------------------------------------------------

void flm_dart_bridge_free_progress(flm_progress* owned) {
  if (owned == NULL) return;
  // Cast away const on the strdup'd strings — the pointers came from malloc.
  free((void*)owned->stage);
  free((void*)owned->detail);
  free(owned);
}

void flm_dart_bridge_free_delta(flm_delta* owned) {
  if (owned == NULL) return;
  free((void*)owned->text);
  free((void*)owned->tool_call_id);
  free((void*)owned->tool_name);
  free((void*)owned->tool_arguments_json);
  free(owned);
}

void flm_dart_bridge_free_string(char* owned) {
  free(owned);
}
