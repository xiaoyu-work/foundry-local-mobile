// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "foundry_local_mobile/flm_dart_bridge.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

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

int32_t flm_dart_bridge_progress(flm_job job, const flm_progress* progress, void* user_data) {
  const flm_dart_bridge_ctx* ctx = (const flm_dart_bridge_ctx*)user_data;
  if (ctx == NULL || ctx->on_progress == NULL || progress == NULL) return 0;

  flm_progress* owned = (flm_progress*)malloc(sizeof(flm_progress));
  if (owned == NULL) return 0;
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
  char* owned_error = copy_c_string(error_json);
  ctx->on_complete(job, (int32_t)status, owned_error, ctx->user_data);
}

void flm_dart_bridge_free_progress(flm_progress* owned) {
  if (owned == NULL) return;
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
