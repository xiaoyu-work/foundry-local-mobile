// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// JNI bridge for library-wide entry points: version, log level, runtime path,
// error retrieval and string free.

#include "jni_common.h"

using namespace flm_android;

extern "C" {

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_versionString(JNIEnv* env, jclass) {
  return ToJString(env, flm_version_string());
}

JNIEXPORT jint JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_apiVersion(JNIEnv* /*env*/, jclass) {
  return static_cast<jint>(flm_api_version());
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_runtimeVersionString(JNIEnv* env, jclass) {
  const char* v = flm_runtime_version_string();
  return v != nullptr ? ToJString(env, v) : nullptr;
}

JNIEXPORT jboolean JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_isRuntimeAvailable(JNIEnv* /*env*/, jclass) {
  return flm_is_runtime_available() != 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_setRuntimeLibraryPath(JNIEnv* env, jclass,
                                                                                       jstring path) {
  JStringUtf str(env, path);
  return static_cast<jint>(flm_set_runtime_library_path(str.c_str_or_null()));
}

JNIEXPORT jint JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_setLogLevel(JNIEnv* /*env*/, jclass,
                                                                              jint level) {
  return static_cast<jint>(flm_set_log_level(static_cast<flm_log_level>(level)));
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_lastErrorMessage(JNIEnv* env, jclass) {
  return ToJString(env, flm_last_error_message());
}

JNIEXPORT jstring JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_lastErrorDetailJson(JNIEnv* env, jclass) {
  return ToJString(env, flm_last_error_detail_json());
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_clearLastError(JNIEnv* /*env*/, jclass) {
  flm_clear_last_error();
}

}  // extern "C"
