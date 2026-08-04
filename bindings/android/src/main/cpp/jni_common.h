// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Shared JNI utilities for the Foundry Local Mobile Android bridge.
//
// Threading model
//   * The C ABI invokes callbacks on core job-pool threads, which are C++
//     threads the JVM has never seen. Every callback trampoline must attach
//     itself as a daemon via VmScope, so a lingering attach cannot block
//     JVM exit.
//   * `NewGlobalRef` is required for any Java reference retained across a
//     callback boundary. Local refs captured at registration time become
//     dangling as soon as the registering JNI call returns.
//
// Ownership
//   * JStringUtf owns the pointer returned by GetStringUTFChars and releases
//     it on destruction.
//   * FlmStringGuard owns a char* returned by the ABI through an out-param
//     and frees it with flm_string_free on destruction.

#ifndef FOUNDRY_LOCAL_MOBILE_ANDROID_JNI_COMMON_H_
#define FOUNDRY_LOCAL_MOBILE_ANDROID_JNI_COMMON_H_

#include <jni.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>

#include "foundry_local_mobile/flm_api.h"
#include "foundry_local_mobile/flm_types.h"

namespace flm_android {

// -------------------------------------------------------------------------
// VM access
// -------------------------------------------------------------------------

// Cache the JavaVM* at JNI_OnLoad; callbacks that run on core threads need it
// to attach.
JavaVM* GetJavaVM() noexcept;

void SetJavaVM(JavaVM* vm) noexcept;

// RAII helper for attaching a native thread to the JVM as a daemon and
// detaching it when we are done. If the current thread was already attached
// (a JNI call reached the callback synchronously), no detach is performed.
class VmScope {
 public:
  VmScope() noexcept;
  ~VmScope() noexcept;

  VmScope(const VmScope&) = delete;
  VmScope& operator=(const VmScope&) = delete;

  JNIEnv* env() const noexcept { return env_; }
  bool ok() const noexcept { return env_ != nullptr; }

 private:
  JNIEnv* env_ = nullptr;
  bool detach_on_destroy_ = false;
};

// -------------------------------------------------------------------------
// String helpers
// -------------------------------------------------------------------------

// Owns a `const char*` returned by GetStringUTFChars.
class JStringUtf {
 public:
  JStringUtf(JNIEnv* env, jstring str) noexcept;
  ~JStringUtf() noexcept;

  JStringUtf(const JStringUtf&) = delete;
  JStringUtf& operator=(const JStringUtf&) = delete;

  const char* c_str() const noexcept { return chars_ != nullptr ? chars_ : ""; }
  const char* c_str_or_null() const noexcept { return chars_; }
  bool is_null() const noexcept { return str_ == nullptr; }

 private:
  JNIEnv* env_ = nullptr;
  jstring str_ = nullptr;
  const char* chars_ = nullptr;
};

// Owns a `char*` returned from the ABI through an out-parameter. Frees with
// flm_string_free on destruction. A no-op if the pointer is NULL.
class FlmStringGuard {
 public:
  FlmStringGuard() noexcept = default;
  explicit FlmStringGuard(char* ptr) noexcept : ptr_(ptr) {}
  ~FlmStringGuard() noexcept {
    if (ptr_ != nullptr) {
      flm_string_free(ptr_);
    }
  }

  FlmStringGuard(const FlmStringGuard&) = delete;
  FlmStringGuard& operator=(const FlmStringGuard&) = delete;

  FlmStringGuard(FlmStringGuard&& other) noexcept : ptr_(other.ptr_) { other.ptr_ = nullptr; }
  FlmStringGuard& operator=(FlmStringGuard&& other) noexcept {
    if (this != &other) {
      if (ptr_ != nullptr) flm_string_free(ptr_);
      ptr_ = other.ptr_;
      other.ptr_ = nullptr;
    }
    return *this;
  }

  char** out() noexcept { return &ptr_; }
  const char* get() const noexcept { return ptr_ != nullptr ? ptr_ : ""; }
  bool empty() const noexcept { return ptr_ == nullptr || ptr_[0] == '\0'; }

 private:
  char* ptr_ = nullptr;
};

// Convert a possibly-null Java string to std::string; returns empty string for null.
std::string ToStdString(JNIEnv* env, jstring str) noexcept;

// Build a jstring from a UTF-8 C string; returns null for a null input, or an
// empty jstring for an empty input.
jstring ToJString(JNIEnv* env, const char* utf8) noexcept;
jstring ToJString(JNIEnv* env, std::string_view utf8) noexcept;

// -------------------------------------------------------------------------
// Errors
// -------------------------------------------------------------------------

// If `status` is not FLM_OK, throw com.microsoft.ai.foundry.local.mobile.FoundryLocalException
// (or a subclass) with the last error message and detail JSON captured on this
// thread. Reads flm_last_error_* eagerly because a subsequent JNI call — say,
// JNIEnv->NewStringUTF — may reset the thread-local error state.
void ThrowIfError(JNIEnv* env, flm_status status) noexcept;

// Throw a FoundryLocalException from an explicit status/message/detail_json
// tuple. Useful for callback trampolines that receive the error JSON directly.
void ThrowFoundryLocalException(JNIEnv* env, flm_status status, const char* message,
                                const char* detail_json) noexcept;

// -------------------------------------------------------------------------
// Kotlin-side class + method IDs
//
// Resolved once in JNI_OnLoad and cached as jclass NewGlobalRefs plus jmethodID
// values, because looking them up on every callback allocates and can lock the
// class loader on some runtimes.
// -------------------------------------------------------------------------

struct CachedClasses {
  jclass runtime_exception = nullptr;    // java.lang.RuntimeException — fallback path.
  jclass illegal_argument = nullptr;     // java.lang.IllegalArgumentException.

  jclass exception_base = nullptr;       // FoundryLocalException.
  jmethodID exception_ctor = nullptr;    // (int status, String message, String detailJson).

  jclass native_progress = nullptr;      // internal.NativeProgress.
  jmethodID native_progress_ctor = nullptr;

  jclass native_delta = nullptr;         // internal.NativeDelta.
  jmethodID native_delta_ctor = nullptr;

  jclass native_http_request = nullptr;  // internal.NativeHttpRequest.
  jmethodID native_http_request_ctor = nullptr;

  jclass native_callbacks = nullptr;     // internal.NativeCallbacks.
  jmethodID on_progress = nullptr;       // static.
  jmethodID on_delta = nullptr;          // static.
  jmethodID on_completion = nullptr;     // static.

  jclass transport_dispatcher = nullptr; // transport.TransportDispatcher.
  jmethodID transport_send = nullptr;    // static.
  jmethodID transport_cancel = nullptr;  // static.
};

const CachedClasses& Cached() noexcept;

// Load and cache the classes above. Called from JNI_OnLoad.
bool InitCache(JNIEnv* env) noexcept;

// Release cached global refs. Called from JNI_OnUnload; safe if InitCache never
// ran.
void ReleaseCache(JNIEnv* env) noexcept;

// -------------------------------------------------------------------------
// Callback correlation
//
// Every *_async ABI call takes a `void* user_data`. We pass a small heap-owned
// CallbackContext there. Its lifetime ends inside the completion trampoline,
// which runs exactly once per job (even on cancel).
// -------------------------------------------------------------------------

struct CallbackContext {
  int64_t correlation_id = 0;
};

CallbackContext* MakeCallbackContext(int64_t correlation_id) noexcept;

flm_progress_callback GetProgressCallback() noexcept;
flm_delta_callback GetDeltaCallback() noexcept;
flm_completion_callback GetCompletionCallback() noexcept;

}  // namespace flm_android

#endif  // FOUNDRY_LOCAL_MOBILE_ANDROID_JNI_COMMON_H_
