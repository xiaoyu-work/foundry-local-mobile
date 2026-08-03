// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// JNI bridge for jobs, plus the C-side trampolines that fire progress,
// delta and completion callbacks into Kotlin.
//
// Every *_async ABI call takes a `void* user_data`. We pass a small heap-owned
// CallbackContext there. Its lifetime is:
//   * created just before the ABI call, holding the callback correlation id.
//   * lives until the completion trampoline fires, which happens exactly once
//     per job (even on cancel), after which it deletes itself.
// A separate correlation `long` handle is exposed to Kotlin, which uses a
// concurrent map to keep the actual Kotlin callbacks alive until then.

#include <atomic>
#include <cstdint>

#include "jni_common.h"

namespace flm_android {
namespace {

// Progress callback: invoked on core job-pool threads. Attach the thread to
// the JVM, marshal the flm_progress into a Kotlin data class, and forward.
// Return non-zero to request cancellation of the job.
int32_t FLM_CALLBACK OnProgressTrampoline(flm_job job, const flm_progress* progress, void* user_data) {
  auto* ctx = static_cast<CallbackContext*>(user_data);
  if (ctx == nullptr || progress == nullptr) return 0;

  VmScope scope;
  if (!scope.ok()) return 0;
  JNIEnv* env = scope.env();
  const CachedClasses& c = Cached();
  if (c.native_progress == nullptr || c.native_progress_ctor == nullptr ||
      c.native_callbacks == nullptr || c.on_progress == nullptr) {
    return 0;
  }

  jstring j_stage = progress->stage != nullptr ? env->NewStringUTF(progress->stage) : nullptr;
  jstring j_detail = progress->detail != nullptr ? env->NewStringUTF(progress->detail) : nullptr;
  jobject native_progress =
      env->NewObject(c.native_progress, c.native_progress_ctor, static_cast<jfloat>(progress->percent),
                     static_cast<jlong>(progress->completed_bytes), static_cast<jlong>(progress->total_bytes),
                     static_cast<jlong>(progress->bytes_per_second), static_cast<jlong>(progress->eta_ms),
                     j_stage, j_detail);

  jint result = 0;
  if (native_progress != nullptr) {
    result = env->CallStaticIntMethod(c.native_callbacks, c.on_progress,
                                      static_cast<jlong>(ctx->correlation_id), native_progress);
    env->DeleteLocalRef(native_progress);
  }
  if (j_stage != nullptr) env->DeleteLocalRef(j_stage);
  if (j_detail != nullptr) env->DeleteLocalRef(j_detail);
  if (env->ExceptionCheck()) env->ExceptionClear();
  (void)job;
  return static_cast<int32_t>(result);
}

int32_t FLM_CALLBACK OnDeltaTrampoline(flm_job job, const flm_delta* delta, void* user_data) {
  auto* ctx = static_cast<CallbackContext*>(user_data);
  if (ctx == nullptr || delta == nullptr) return 0;

  VmScope scope;
  if (!scope.ok()) return 0;
  JNIEnv* env = scope.env();
  const CachedClasses& c = Cached();
  if (c.native_delta == nullptr || c.native_delta_ctor == nullptr || c.native_callbacks == nullptr ||
      c.on_delta == nullptr) {
    return 0;
  }

  // `text` is a UTF-8 blob with an explicit length; use NewStringUTF only if
  // the ABI reported no length, otherwise round-trip through std::string.
  jstring j_text = nullptr;
  if (delta->text != nullptr) {
    if (delta->text_length > 0) {
      std::string tmp(delta->text, delta->text_length);
      j_text = env->NewStringUTF(tmp.c_str());
    } else {
      j_text = env->NewStringUTF(delta->text);
    }
  }
  jstring j_tool_id = delta->tool_call_id != nullptr ? env->NewStringUTF(delta->tool_call_id) : nullptr;
  jstring j_tool_name = delta->tool_name != nullptr ? env->NewStringUTF(delta->tool_name) : nullptr;
  jstring j_tool_args =
      delta->tool_arguments_json != nullptr ? env->NewStringUTF(delta->tool_arguments_json) : nullptr;

  jobject native_delta = env->NewObject(
      c.native_delta, c.native_delta_ctor, static_cast<jint>(delta->kind), j_text, j_tool_id, j_tool_name,
      j_tool_args, static_cast<jlong>(delta->start_time_ms), static_cast<jlong>(delta->end_time_ms),
      static_cast<jlong>(delta->prompt_tokens), static_cast<jlong>(delta->completion_tokens),
      static_cast<jint>(delta->finish_reason));

  jint result = 0;
  if (native_delta != nullptr) {
    result = env->CallStaticIntMethod(c.native_callbacks, c.on_delta,
                                      static_cast<jlong>(ctx->correlation_id), native_delta);
    env->DeleteLocalRef(native_delta);
  }
  if (j_text != nullptr) env->DeleteLocalRef(j_text);
  if (j_tool_id != nullptr) env->DeleteLocalRef(j_tool_id);
  if (j_tool_name != nullptr) env->DeleteLocalRef(j_tool_name);
  if (j_tool_args != nullptr) env->DeleteLocalRef(j_tool_args);
  if (env->ExceptionCheck()) env->ExceptionClear();
  (void)job;
  return static_cast<int32_t>(result);
}

// Terminal callback: fire once, then release the CallbackContext.
void FLM_CALLBACK OnCompletionTrampoline(flm_job /*job*/, flm_status status, const char* error_json,
                                         void* user_data) {
  auto* ctx = static_cast<CallbackContext*>(user_data);
  if (ctx == nullptr) return;

  {
    VmScope scope;
    if (scope.ok()) {
      JNIEnv* env = scope.env();
      const CachedClasses& c = Cached();
      if (c.native_callbacks != nullptr && c.on_completion != nullptr) {
        jstring j_error = error_json != nullptr ? env->NewStringUTF(error_json) : nullptr;
        env->CallStaticVoidMethod(c.native_callbacks, c.on_completion,
                                  static_cast<jlong>(ctx->correlation_id), static_cast<jint>(status),
                                  j_error);
        if (j_error != nullptr) env->DeleteLocalRef(j_error);
        if (env->ExceptionCheck()) env->ExceptionClear();
      }
    }
  }

  delete ctx;
}

}  // namespace

CallbackContext* MakeCallbackContext(int64_t correlation_id) noexcept {
  auto* ctx = new (std::nothrow) CallbackContext{};
  if (ctx != nullptr) {
    ctx->correlation_id = correlation_id;
  }
  return ctx;
}

flm_progress_callback GetProgressCallback() noexcept { return &OnProgressTrampoline; }
flm_delta_callback GetDeltaCallback() noexcept { return &OnDeltaTrampoline; }
flm_completion_callback GetCompletionCallback() noexcept { return &OnCompletionTrampoline; }

}  // namespace flm_android

using namespace flm_android;

extern "C" {

JNIEXPORT jint JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_jobGetState(JNIEnv* env, jclass, jlong job) {
  flm_job_state state = FLM_JOB_PENDING;
  flm_status s = flm_job_get_state(static_cast<flm_job>(job), &state);
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jint>(state);
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_jobCancel(JNIEnv* env, jclass, jlong job) {
  ThrowIfError(env, flm_job_cancel(static_cast<flm_job>(job)));
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_jobTakeResultJson(JNIEnv* env, jclass,
                                                                                     jlong job) {
  FlmStringGuard out;
  flm_status s = flm_job_take_result_json(static_cast<flm_job>(job), out.out());
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return nullptr;
  }
  return out.get()[0] != '\0' ? env->NewStringUTF(out.get()) : nullptr;
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_jobRelease(JNIEnv* env, jclass, jlong job) {
  // Ignore the return; releasing an unknown handle is a no-op per the ABI.
  (void)env;
  flm_job_release(static_cast<flm_job>(job));
}

}  // extern "C"
