// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "jni_common.h"

#ifdef __ANDROID__
#include <android/log.h>
#define FLM_LOG_WARN(tag, ...) __android_log_print(ANDROID_LOG_WARN, tag, __VA_ARGS__)
#define FLM_LOG_ERROR(tag, ...) __android_log_print(ANDROID_LOG_ERROR, tag, __VA_ARGS__)
#else
#include <cstdio>
#define FLM_LOG_WARN(tag, ...) fprintf(stderr, "[warn][%s] ", tag), fprintf(stderr, __VA_ARGS__), fputc('\n', stderr)
#define FLM_LOG_ERROR(tag, ...) fprintf(stderr, "[err][%s] ", tag), fprintf(stderr, __VA_ARGS__), fputc('\n', stderr)
#endif

#include <atomic>

namespace flm_android {
namespace {

constexpr const char* kLogTag = "FoundryLocalMobile";

std::atomic<JavaVM*> g_vm{nullptr};
CachedClasses g_cache{};

// FindClass at runtime, then upgrade the local ref to a global one so the ID
// survives across JNI calls.
jclass FindAndGlobalize(JNIEnv* env, const char* name) noexcept {
  jclass local = env->FindClass(name);
  if (local == nullptr) {
    FLM_LOG_ERROR(kLogTag, "FindClass failed: %s", name);
    env->ExceptionClear();
    return nullptr;
  }
  auto* global = reinterpret_cast<jclass>(env->NewGlobalRef(local));
  env->DeleteLocalRef(local);
  return global;
}

}  // namespace

// -------------------------------------------------------------------------
// VM access
// -------------------------------------------------------------------------

JavaVM* GetJavaVM() noexcept { return g_vm.load(std::memory_order_acquire); }

void SetJavaVM(JavaVM* vm) noexcept { g_vm.store(vm, std::memory_order_release); }

VmScope::VmScope() noexcept {
  JavaVM* vm = GetJavaVM();
  if (vm == nullptr) {
    return;
  }
  // Fast path: already attached, no cleanup needed.
  void* env_ptr = nullptr;
  jint rc = vm->GetEnv(&env_ptr, JNI_VERSION_1_6);
  if (rc == JNI_OK && env_ptr != nullptr) {
    env_ = static_cast<JNIEnv*>(env_ptr);
    return;
  }
  if (rc == JNI_EDETACHED) {
    // AttachCurrentThreadAsDaemon so a stuck attach never blocks JVM exit.
    // The Android NDK's C++ JavaVM binding takes JNIEnv** here; do not cast
    // to void** — the previous reinterpret_cast tripped clang's strict
    // parameter-type checks in the r27 toolchain.
    JavaVMAttachArgs args{JNI_VERSION_1_6, const_cast<char*>("flm-callback"), nullptr};
    JNIEnv* attached = nullptr;
    if (vm->AttachCurrentThreadAsDaemon(&attached,
                                        static_cast<void*>(&args)) == JNI_OK) {
      env_ = attached;
      detach_on_destroy_ = true;
    }
  }
}

VmScope::~VmScope() noexcept {
  if (!detach_on_destroy_) {
    return;
  }
  JavaVM* vm = GetJavaVM();
  if (vm != nullptr) {
    vm->DetachCurrentThread();
  }
}

// -------------------------------------------------------------------------
// String helpers
// -------------------------------------------------------------------------

JStringUtf::JStringUtf(JNIEnv* env, jstring str) noexcept : env_(env), str_(str) {
  if (env != nullptr && str != nullptr) {
    chars_ = env->GetStringUTFChars(str, nullptr);
  }
}

JStringUtf::~JStringUtf() noexcept {
  if (chars_ != nullptr && env_ != nullptr && str_ != nullptr) {
    env_->ReleaseStringUTFChars(str_, chars_);
  }
}

std::string ToStdString(JNIEnv* env, jstring str) noexcept {
  if (env == nullptr || str == nullptr) {
    return {};
  }
  JStringUtf tmp(env, str);
  const char* c = tmp.c_str_or_null();
  if (c == nullptr) {
    return {};
  }
  return std::string(c);
}

jstring ToJString(JNIEnv* env, const char* utf8) noexcept {
  if (env == nullptr || utf8 == nullptr) {
    return nullptr;
  }
  return env->NewStringUTF(utf8);
}

jstring ToJString(JNIEnv* env, std::string_view utf8) noexcept {
  if (env == nullptr) {
    return nullptr;
  }
  // NewStringUTF wants a null-terminated string.
  std::string tmp(utf8);
  return env->NewStringUTF(tmp.c_str());
}

// -------------------------------------------------------------------------
// Errors
// -------------------------------------------------------------------------

void ThrowFoundryLocalException(JNIEnv* env, flm_status status, const char* message,
                                const char* detail_json) noexcept {
  if (env == nullptr) return;
  if (env->ExceptionCheck()) {
    // Preserve the pending Java exception.
    return;
  }

  const CachedClasses& c = Cached();
  jclass cls = c.exception_base;
  if (cls == nullptr || c.exception_ctor == nullptr) {
    if (c.runtime_exception != nullptr) {
      env->ThrowNew(c.runtime_exception, message != nullptr ? message : "foundry_local error");
    }
    return;
  }
  jstring j_message = ToJString(env, message != nullptr ? message : "");
  jstring j_detail = detail_json != nullptr ? ToJString(env, detail_json) : nullptr;
  jobject exc = env->NewObject(cls, c.exception_ctor, static_cast<jint>(status), j_message, j_detail);
  if (exc != nullptr) {
    env->Throw(static_cast<jthrowable>(exc));
  }
  if (j_message != nullptr) env->DeleteLocalRef(j_message);
  if (j_detail != nullptr) env->DeleteLocalRef(j_detail);
}

void ThrowIfError(JNIEnv* env, flm_status status) noexcept {
  if (status == FLM_OK) return;
  // Capture eagerly, because the next JNI call may reset the thread-local state.
  const char* msg = flm_last_error_message();
  const char* detail = flm_last_error_detail_json();
  std::string msg_copy = msg != nullptr ? std::string(msg) : std::string();
  std::string detail_copy = detail != nullptr ? std::string(detail) : std::string();
  ThrowFoundryLocalException(env, status,
                             msg_copy.empty() ? nullptr : msg_copy.c_str(),
                             detail_copy.empty() ? nullptr : detail_copy.c_str());
}

// -------------------------------------------------------------------------
// Cache
// -------------------------------------------------------------------------

const CachedClasses& Cached() noexcept { return g_cache; }

bool InitCache(JNIEnv* env) noexcept {
  if (env == nullptr) return false;

  g_cache.runtime_exception = FindAndGlobalize(env, "java/lang/RuntimeException");
  g_cache.illegal_argument = FindAndGlobalize(env, "java/lang/IllegalArgumentException");

  g_cache.exception_base = FindAndGlobalize(env, "com/microsoft/ai/foundry/local/mobile/FoundryLocalException");
  if (g_cache.exception_base != nullptr) {
    g_cache.exception_ctor = env->GetMethodID(g_cache.exception_base, "<init>",
                                              "(ILjava/lang/String;Ljava/lang/String;)V");
  }

  g_cache.native_progress = FindAndGlobalize(env,
                                             "com/microsoft/ai/foundry/local/mobile/internal/NativeProgress");
  if (g_cache.native_progress != nullptr) {
    g_cache.native_progress_ctor = env->GetMethodID(
        g_cache.native_progress, "<init>", "(FJJJJLjava/lang/String;Ljava/lang/String;)V");
  }

  g_cache.native_delta = FindAndGlobalize(env, "com/microsoft/ai/foundry/local/mobile/internal/NativeDelta");
  if (g_cache.native_delta != nullptr) {
    g_cache.native_delta_ctor = env->GetMethodID(
        g_cache.native_delta, "<init>",
        "(ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;JJJJI)V");
  }

  g_cache.native_http_request = FindAndGlobalize(
      env, "com/microsoft/ai/foundry/local/mobile/internal/NativeHttpRequest");
  if (g_cache.native_http_request != nullptr) {
    g_cache.native_http_request_ctor = env->GetMethodID(
        g_cache.native_http_request, "<init>",
        "(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;JJ)V");
  }

  g_cache.native_callbacks = FindAndGlobalize(env,
                                              "com/microsoft/ai/foundry/local/mobile/internal/NativeCallbacks");
  if (g_cache.native_callbacks != nullptr) {
    g_cache.on_progress = env->GetStaticMethodID(
        g_cache.native_callbacks, "dispatchProgress",
        "(JLcom/microsoft/ai/foundry/local/mobile/internal/NativeProgress;)I");
    g_cache.on_delta = env->GetStaticMethodID(
        g_cache.native_callbacks, "dispatchDelta",
        "(JLcom/microsoft/ai/foundry/local/mobile/internal/NativeDelta;)I");
    g_cache.on_completion = env->GetStaticMethodID(
        g_cache.native_callbacks, "dispatchCompletion", "(JILjava/lang/String;)V");
  }

  g_cache.transport_dispatcher = FindAndGlobalize(
      env, "com/microsoft/ai/foundry/local/mobile/transport/TransportDispatcher");
  if (g_cache.transport_dispatcher != nullptr) {
    g_cache.transport_send = env->GetStaticMethodID(
        g_cache.transport_dispatcher, "dispatchSend",
        "(Lcom/microsoft/ai/foundry/local/mobile/internal/NativeHttpRequest;)I");
    g_cache.transport_cancel = env->GetStaticMethodID(
        g_cache.transport_dispatcher, "dispatchCancel", "(J)V");
  }

  return g_cache.exception_base != nullptr && g_cache.native_callbacks != nullptr;
}

void ReleaseCache(JNIEnv* env) noexcept {
  if (env == nullptr) return;
  auto drop = [&](jclass& c) {
    if (c != nullptr) {
      env->DeleteGlobalRef(c);
      c = nullptr;
    }
  };
  drop(g_cache.runtime_exception);
  drop(g_cache.illegal_argument);
  drop(g_cache.exception_base);
  drop(g_cache.native_progress);
  drop(g_cache.native_delta);
  drop(g_cache.native_http_request);
  drop(g_cache.native_callbacks);
  drop(g_cache.transport_dispatcher);
  g_cache = CachedClasses{};
}

}  // namespace flm_android

// -------------------------------------------------------------------------
// JNI_OnLoad / JNI_OnUnload
// -------------------------------------------------------------------------
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
  flm_android::SetJavaVM(vm);

  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }
  if (!flm_android::InitCache(env)) {
    // The Kotlin side will surface a clearer error the first time it tries to
    // call a JNI method; don't abort loading here.
    FLM_LOG_WARN("FoundryLocalMobile", "JNI_OnLoad: some classes/methods could not be cached");
  }
  return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* vm, void* /*reserved*/) {
  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK) {
    flm_android::ReleaseCache(env);
  }
  flm_android::SetJavaVM(nullptr);
}
