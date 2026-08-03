// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// JNI bridge for flm_model_* and flm_package_*.

#include "jni_common.h"

namespace flm_android {}  // namespace flm_android

using namespace flm_android;

extern "C" {

// --------------------------------------------------------------------------
// Model
// --------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_modelRelease(JNIEnv* env, jclass,
                                                                                jlong model) {
  (void)env;
  flm_model_release(static_cast<flm_model>(model));
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_modelGetInfoJson(JNIEnv* env, jclass,
                                                                                    jlong model) {
  FlmStringGuard out;
  flm_status s = flm_model_get_info_json(static_cast<flm_model>(model), out.out());
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return nullptr;
  }
  return env->NewStringUTF(out.get());
}

JNIEXPORT jboolean JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_modelIsCached(JNIEnv* env, jclass,
                                                                                jlong model) {
  int32_t cached = 0;
  flm_status s = flm_model_is_cached(static_cast<flm_model>(model), &cached);
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return JNI_FALSE;
  }
  return cached != 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_modelIsLoaded(JNIEnv* env, jclass,
                                                                                jlong model) {
  int32_t loaded = 0;
  flm_status s = flm_model_is_loaded(static_cast<flm_model>(model), &loaded);
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return JNI_FALSE;
  }
  return loaded != 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_modelGetPath(JNIEnv* env, jclass,
                                                                                jlong model) {
  FlmStringGuard out;
  flm_status s = flm_model_get_path(static_cast<flm_model>(model), out.out());
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return nullptr;
  }
  return env->NewStringUTF(out.get());
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_modelDownloadAsync(
    JNIEnv* env, jclass, jlong model, jstring options_json, jlong correlation_id) {
  JStringUtf opts(env, options_json);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_status s = flm_model_download_async(static_cast<flm_model>(model), opts.c_str_or_null(),
                                          GetProgressCallback(), GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_modelLoadAsync(JNIEnv* env, jclass,
                                                                                  jlong model,
                                                                                  jstring options_json,
                                                                                  jlong correlation_id) {
  JStringUtf opts(env, options_json);
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_status s = flm_model_load_async(static_cast<flm_model>(model), opts.c_str_or_null(),
                                      GetProgressCallback(), GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_modelUnloadAsync(JNIEnv* env, jclass,
                                                                                    jlong model,
                                                                                    jlong correlation_id) {
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_status s =
      flm_model_unload_async(static_cast<flm_model>(model), GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_modelDeleteAsync(JNIEnv* env, jclass,
                                                                                    jlong model,
                                                                                    jlong correlation_id) {
  auto* ctx = MakeCallbackContext(correlation_id);
  flm_job job = FLM_INVALID_HANDLE;
  flm_status s =
      flm_model_delete_async(static_cast<flm_model>(model), GetCompletionCallback(), ctx, &job);
  if (s != FLM_OK) {
    delete ctx;
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(job);
}

// --------------------------------------------------------------------------
// Model packages
// --------------------------------------------------------------------------

JNIEXPORT jboolean JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_modelIsPackage(JNIEnv* env, jclass,
                                                                                  jlong model) {
  int32_t is_pkg = 0;
  flm_status s = flm_model_is_package(static_cast<flm_model>(model), &is_pkg);
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return JNI_FALSE;
  }
  return is_pkg != 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_packageGetVariantsJson(JNIEnv* env, jclass,
                                                                                          jlong model) {
  FlmStringGuard out;
  flm_status s = flm_package_get_variants_json(static_cast<flm_model>(model), out.out());
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return nullptr;
  }
  return env->NewStringUTF(out.get());
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_packageSelectVariant(JNIEnv* env, jclass,
                                                                                        jlong model,
                                                                                        jstring variant_id) {
  JStringUtf id(env, variant_id);
  ThrowIfError(env, flm_package_select_variant(static_cast<flm_model>(model), id.c_str()));
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_packageSelectBestVariant(
    JNIEnv* env, jclass, jlong model, jstring constraints_json) {
  JStringUtf c(env, constraints_json);
  FlmStringGuard out;
  flm_status s = flm_package_select_best_variant(static_cast<flm_model>(model), c.c_str_or_null(),
                                                 out.out());
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return nullptr;
  }
  return env->NewStringUTF(out.get());
}

JNIEXPORT jlong JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_packageGetVariant(JNIEnv* env, jclass,
                                                                                     jlong model,
                                                                                     jstring variant_id) {
  JStringUtf id(env, variant_id);
  flm_model handle = FLM_INVALID_HANDLE;
  flm_status s = flm_package_get_variant(static_cast<flm_model>(model), id.c_str(), &handle);
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return 0;
  }
  return static_cast<jlong>(handle);
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_packageEstimateDownloadJson(
    JNIEnv* env, jclass, jlong model, jstring variant_ids_json) {
  JStringUtf ids(env, variant_ids_json);
  FlmStringGuard out;
  flm_status s =
      flm_package_estimate_download_json(static_cast<flm_model>(model), ids.c_str_or_null(), out.out());
  if (s != FLM_OK) {
    ThrowIfError(env, s);
    return nullptr;
  }
  return env->NewStringUTF(out.get());
}

}  // extern "C"
