// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// JNI bridge for the HTTP transport.
//
// The core requests bytes through an flm_transport with two function pointers:
// `send` starts a request, `cancel` aborts one. Both must return immediately;
// the transport reports back through flm_transport_report_progress/_body/
// _complete. `report_complete` **must** fire exactly once for every request the
// core hands off, including cancelled and failed ones, because the core blocks
// a job thread waiting for it.
//
// Kotlin owns the OkHttp queue. The C++ side is a thin trampoline: it
// marshals the request into a NativeHttpRequest Kotlin object and dispatches
// it to the Kotlin dispatcher, then routes the report_* calls back the other
// way.

#include "jni_common.h"

namespace flm_android {
namespace {

int32_t FLM_CALLBACK OnTransportSend(const flm_http_request* request, void* /*user_data*/) noexcept {
  if (request == nullptr) return -1;

  VmScope scope;
  if (!scope.ok()) return -1;
  JNIEnv* env = scope.env();
  const CachedClasses& c = Cached();
  if (c.transport_dispatcher == nullptr || c.transport_send == nullptr ||
      c.native_http_request == nullptr || c.native_http_request_ctor == nullptr) {
    return -1;
  }

  jstring j_url = request->url != nullptr ? env->NewStringUTF(request->url) : nullptr;
  jstring j_method = request->method != nullptr ? env->NewStringUTF(request->method) : nullptr;
  jstring j_headers = request->headers_json != nullptr ? env->NewStringUTF(request->headers_json) : nullptr;
  jstring j_dest = request->destination_path != nullptr ? env->NewStringUTF(request->destination_path)
                                                        : nullptr;

  jobject req_obj = env->NewObject(c.native_http_request, c.native_http_request_ctor,
                                   static_cast<jlong>(request->request_id), j_url, j_method, j_headers,
                                   j_dest, static_cast<jlong>(request->offset),
                                   static_cast<jlong>(request->expected_bytes));

  jint result = -1;
  if (req_obj != nullptr) {
    result = env->CallStaticIntMethod(c.transport_dispatcher, c.transport_send, req_obj);
    env->DeleteLocalRef(req_obj);
  }
  if (j_url != nullptr) env->DeleteLocalRef(j_url);
  if (j_method != nullptr) env->DeleteLocalRef(j_method);
  if (j_headers != nullptr) env->DeleteLocalRef(j_headers);
  if (j_dest != nullptr) env->DeleteLocalRef(j_dest);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return -1;
  }
  return static_cast<int32_t>(result);
}

void FLM_CALLBACK OnTransportCancel(uint64_t request_id, void* /*user_data*/) noexcept {
  VmScope scope;
  if (!scope.ok()) return;
  JNIEnv* env = scope.env();
  const CachedClasses& c = Cached();
  if (c.transport_dispatcher == nullptr || c.transport_cancel == nullptr) {
    return;
  }
  env->CallStaticVoidMethod(c.transport_dispatcher, c.transport_cancel, static_cast<jlong>(request_id));
  if (env->ExceptionCheck()) env->ExceptionClear();
}

}  // namespace
}  // namespace flm_android

using namespace flm_android;

extern "C" {

// --------------------------------------------------------------------------
// Transport installation
// --------------------------------------------------------------------------

// Install the Kotlin-backed transport as the process-wide default. Idempotent.
JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_installDefaultTransport(JNIEnv* env,
                                                                                           jclass) {
  flm_transport t{};
  t.version = FLM_API_VERSION;
  t.send = &OnTransportSend;
  t.cancel = &OnTransportCancel;
  t.user_data = nullptr;
  ThrowIfError(env, flm_set_transport(&t));
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_uninstallTransport(JNIEnv* env, jclass) {
  ThrowIfError(env, flm_set_transport(nullptr));
}

// --------------------------------------------------------------------------
// Report path — Kotlin -> core.
// --------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_transportReportProgress(
    JNIEnv* env, jclass, jlong request_id, jlong completed_bytes, jlong total_bytes) {
  ThrowIfError(env, flm_transport_report_progress(static_cast<uint64_t>(request_id),
                                                  static_cast<int64_t>(completed_bytes),
                                                  static_cast<int64_t>(total_bytes)));
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_transportReportBody(
    JNIEnv* env, jclass, jlong request_id, jbyteArray data) {
  jsize len = env->GetArrayLength(data);
  void* raw = env->GetPrimitiveArrayCritical(data, nullptr);
  flm_status s = FLM_ERROR_INVALID_ARGUMENT;
  if (raw != nullptr) {
    s = flm_transport_report_body(static_cast<uint64_t>(request_id), static_cast<const char*>(raw),
                                  static_cast<size_t>(len));
    env->ReleasePrimitiveArrayCritical(data, raw, JNI_ABORT);
  }
  ThrowIfError(env, s);
}

JNIEXPORT void JNICALL
Java_com_microsoft_ai_foundry_local_mobile_internal_NativeBridge_transportReportComplete(
    JNIEnv* env, jclass, jlong request_id, jint status_code, jstring headers_json, jstring error_message) {
  JStringUtf headers(env, headers_json);
  JStringUtf error(env, error_message);
  ThrowIfError(env,
               flm_transport_report_complete(static_cast<uint64_t>(request_id), static_cast<int32_t>(status_code),
                                             headers.c_str_or_null(), error.c_str_or_null()));
}

}  // extern "C"
