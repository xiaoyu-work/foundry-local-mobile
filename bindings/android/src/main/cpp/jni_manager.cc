// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// JNI bridge for flm_manager_* and flm_catalog_* — the entries the Kotlin API
// touches first and most often.

#include "jni_common.h"

using namespace flm_android;

extern "C" {

// --------------------------------------------------------------------------
// Manager
// --------------------------------------------------------------------------

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

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_managerGetCatalog(JNIEnv* env, jclass,
                                                                                     jlong manager) {
  flm_catalog cat = FLM_INVALID_HANDLE;
  flm_status s = flm_manager_get_catalog(static_cast<flm_manager>(manager), &cat);
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(cat);
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
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_managerAddModelSourceAsync(
    JNIEnv* env, jclass, jlong manager, jstring source_json, jlong correlation_id) {
  JStringUtf src(env, source_json);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_status s = flm_manager_add_model_source_async(static_cast<flm_manager>(manager), src.c_str(),
                                                    GetProgressCallback(), GetCompletionCallback(),
                                                    ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

// --------------------------------------------------------------------------
// Catalog
// --------------------------------------------------------------------------

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_catalogListModelsAsync(
    JNIEnv* env, jclass, jlong catalog, jstring filter_json, jlong correlation_id) {
  JStringUtf filter(env, filter_json);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_status s = flm_catalog_list_models_async(static_cast<flm_catalog>(catalog), filter.c_str_or_null(),
                                               GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_catalogGetModelAsync(JNIEnv* env, jclass,
                                                                                        jlong catalog,
                                                                                        jstring alias,
                                                                                        jlong correlation_id) {
  JStringUtf a(env, alias);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_status s = flm_catalog_get_model_async(static_cast<flm_catalog>(catalog), a.c_str(),
                                             GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_catalogGetModelByIdAsync(
    JNIEnv* env, jclass, jlong catalog, jstring model_id, jlong correlation_id) {
  JStringUtf id(env, model_id);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_status s = flm_catalog_get_model_by_id_async(static_cast<flm_catalog>(catalog), id.c_str(),
                                                   GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_catalogListCachedModelsJson(
    JNIEnv* env, jclass, jlong catalog) {
  FlmStringGuard out;
  flm_status s = flm_catalog_list_cached_models_json(static_cast<flm_catalog>(catalog), out.out());
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return nullptr;
  }
  return env->NewStringUTF(out.get());
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_catalogGetCacheSizeBytes(JNIEnv* env, jclass,
                                                                                             jlong catalog) {
  int64_t bytes = 0;
  flm_status s = flm_catalog_get_cache_size_bytes(static_cast<flm_catalog>(catalog), &bytes);
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(bytes);
}

}  // extern "C"
