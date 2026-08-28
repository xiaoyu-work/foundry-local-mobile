// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// JNI bridge for flm_manager_* — the entries the Kotlin API touches first and
// most often.

#include "jni_common.h"

using namespace flm_android;

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_managerCreate(JNIEnv* env, jclass,
                                                                                jstring config_json) {
  JStringUtf cfg(env, config_json);
  flm_manager handle = FLM_INVALID_HANDLE;
  flm_status s = flm_manager_create(cfg.c_str(), &handle);
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(handle);
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_managerShutdown(JNIEnv* env, jclass,
                                                                                  jlong manager) {
  ThrowIfError(env, flm_manager_shutdown(static_cast<flm_manager>(manager)));
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_managerRelease(JNIEnv* env, jclass,
                                                                                 jlong manager) {
  ThrowIfError(env, flm_manager_release(static_cast<flm_manager>(manager)));
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_managerGetDeviceProfileJson(
    JNIEnv* env, jclass, jlong manager) {
  FlmStringGuard out;
  flm_status s = flm_manager_get_device_profile_json(static_cast<flm_manager>(manager), out.out());
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return nullptr;
  }
  return env->NewStringUTF(out.get());
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_managerNotifyLifecycle(JNIEnv* env, jclass,
                                                                                          jlong manager,
                                                                                          jint event) {
  ThrowIfError(env,
               flm_manager_notify_lifecycle(static_cast<flm_manager>(manager),
                                            static_cast<flm_lifecycle_event>(event)));
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_managerUpdateSettings(JNIEnv* env, jclass,
                                                                                         jlong manager,
                                                                                         jstring settings_json) {
  JStringUtf s(env, settings_json);
  ThrowIfError(env, flm_manager_update_settings(static_cast<flm_manager>(manager), s.c_str()));
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_managerLoadModelAsync(
    JNIEnv* env, jclass, jlong manager, jstring model_path, jstring options_json,
    jlong correlation_id) {
  JStringUtf path(env, model_path);
  JStringUtf opts(env, options_json);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_status s =
      flm_manager_load_model_async(static_cast<flm_manager>(manager), path.c_str(),
                                   opts.c_str_or_null(), GetProgressCallback(),
                                   GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

}  // extern "C"
