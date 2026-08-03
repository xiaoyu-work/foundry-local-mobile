// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "flm_dart_bridge.h"

#include <stddef.h>

int32_t flm_dart_bridge_progress(flm_job job, const flm_progress* progress, void* user_data) {
  const flm_dart_bridge_ctx* ctx = (const flm_dart_bridge_ctx*)user_data;
  if (ctx != NULL && ctx->on_progress != NULL) {
    ctx->on_progress(job, progress, ctx->user_data);
  }
  return 0;
}

int32_t flm_dart_bridge_delta(flm_job job, const flm_delta* delta, void* user_data) {
  const flm_dart_bridge_ctx* ctx = (const flm_dart_bridge_ctx*)user_data;
  if (ctx != NULL && ctx->on_delta != NULL) {
    ctx->on_delta(job, delta, ctx->user_data);
  }
  return 0;
}

int32_t flm_dart_bridge_send(const flm_http_request* request, void* user_data) {
  const flm_dart_bridge_ctx* ctx = (const flm_dart_bridge_ctx*)user_data;
  if (ctx != NULL && ctx->on_send != NULL) {
    ctx->on_send(request, ctx->user_data);
  }
  return 0;
}
