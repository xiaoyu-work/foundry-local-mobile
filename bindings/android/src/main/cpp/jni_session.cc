// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// JNI bridge for flm_session_*.

#include <vector>

#include "jni_common.h"

using namespace flm_android;

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionCreate(JNIEnv* env, jclass,
                                                                                 jlong model,
                                                                                 jstring options_json) {
  JStringUtf opts(env, options_json);
  flm_session handle = FLM_INVALID_HANDLE;
  flm_status s = flm_session_create(static_cast<flm_model>(model), opts.c_str_or_null(), &handle);
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(handle);
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionRelease(JNIEnv* /*env*/, jclass,
                                                                                  jlong session) {
  flm_session_release(static_cast<flm_session>(session));
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionSetOptions(JNIEnv* env, jclass,
                                                                                     jlong session,
                                                                                     jstring options_json) {
  JStringUtf opts(env, options_json);
  ThrowIfError(env, flm_session_set_options(static_cast<flm_session>(session), opts.c_str_or_null()));
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionCompleteAsync(
    JNIEnv* env, jclass, jlong session, jstring request_json, jboolean streaming, jlong correlation_id) {
  JStringUtf req(env, request_json);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  // Passing a NULL delta callback means non-streaming — the caller reads the
  // full text from the job result. Streaming requests always want deltas.
  flm_delta_callback delta_cb = streaming == JNI_TRUE ? GetDeltaCallback() : nullptr;
  flm_status s = flm_session_complete_async(static_cast<flm_session>(session), req.c_str(), delta_cb,
                                            GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionSubmitToolResultsAsync(
    JNIEnv* env, jclass, jlong session, jstring tool_results_json, jboolean streaming,
    jlong correlation_id) {
  JStringUtf req(env, tool_results_json);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_delta_callback delta_cb = streaming == JNI_TRUE ? GetDeltaCallback() : nullptr;
  flm_status s = flm_session_submit_tool_results_async(static_cast<flm_session>(session), req.c_str(),
                                                       delta_cb, GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionTranscribeAsync(
    JNIEnv* env, jclass, jlong session, jstring request_json, jboolean streaming, jlong correlation_id) {
  JStringUtf req(env, request_json);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_delta_callback delta_cb = streaming == JNI_TRUE ? GetDeltaCallback() : nullptr;
  flm_status s = flm_session_transcribe_async(static_cast<flm_session>(session), req.c_str(), delta_cb,
                                              GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionPushAudio(
    JNIEnv* env, jclass, jlong session, jbyteArray pcm, jint sample_rate, jint channels, jboolean is_final) {
  jsize len = env->GetArrayLength(pcm);
  // Use the Critical variant only for short chunks; on Android these are
  // typically 20-100 ms of 16-bit PCM, well under the tens of kilobytes that
  // still fit comfortably in a critical section.
  void* raw = env->GetPrimitiveArrayCritical(pcm, nullptr);
  flm_status s = FLM_ERROR_INVALID_ARGUMENT;
  if (raw != nullptr) {
    s = flm_session_push_audio(static_cast<flm_session>(session), raw, static_cast<size_t>(len),
                               sample_rate, channels, is_final == JNI_TRUE ? 1 : 0);
    env->ReleasePrimitiveArrayCritical(pcm, raw, JNI_ABORT);
  }
  ThrowIfError(env, s);
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionEmbedAsync(
    JNIEnv* env, jclass, jlong session, jstring request_json, jlong correlation_id) {
  JStringUtf req(env, request_json);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_status s = flm_session_embed_async(static_cast<flm_session>(session), req.c_str(),
                                         GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionGetTurnCount(JNIEnv* env, jclass,
                                                                                       jlong session) {
  size_t count = 0;
  flm_status s = flm_session_get_turn_count(static_cast<flm_session>(session), &count);
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(count);
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionUndoTurns(JNIEnv* env, jclass,
                                                                                    jlong session,
                                                                                    jlong count) {
  ThrowIfError(env, flm_session_undo_turns(static_cast<flm_session>(session), static_cast<size_t>(count)));
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionClearHistory(JNIEnv* env, jclass,
                                                                                       jlong session) {
  ThrowIfError(env, flm_session_clear_history(static_cast<flm_session>(session)));
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionExportHistoryJson(JNIEnv* env, jclass,
                                                                                            jlong session) {
  FlmStringGuard out;
  flm_status s = flm_session_export_history_json(static_cast<flm_session>(session), out.out());
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return nullptr;
  }
  return env->NewStringUTF(out.get());
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_sessionRestoreHistoryJson(
    JNIEnv* env, jclass, jlong session, jstring history_json) {
  JStringUtf h(env, history_json);
  ThrowIfError(env,
               flm_session_restore_history_json(static_cast<flm_session>(session), h.c_str_or_null()));
}

}  // extern "C"
