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

JavaVM* GetJavaVM() noexcept;
void SetJavaVM(JavaVM* vm) noexcept;

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

std::string ToStdString(JNIEnv* env, jstring str) noexcept;
jstring ToJString(JNIEnv* env, const char* utf8) noexcept;
jstring ToJString(JNIEnv* env, std::string_view utf8) noexcept;

void ThrowIfError(JNIEnv* env, flm_status status) noexcept;
void ThrowFoundryLocalException(JNIEnv* env, flm_status status, const char* message,
                                const char* detail_json) noexcept;

struct CachedClasses {
  jclass runtime_exception = nullptr;
  jclass illegal_argument = nullptr;

  jclass exception_base = nullptr;
  jmethodID exception_ctor = nullptr;

  jclass native_progress = nullptr;
  jmethodID native_progress_ctor = nullptr;

  jclass native_delta = nullptr;
  jmethodID native_delta_ctor = nullptr;

  jclass native_callbacks = nullptr;
  jmethodID on_progress = nullptr;
  jmethodID on_delta = nullptr;
  jmethodID on_completion = nullptr;
};

const CachedClasses& Cached() noexcept;
bool InitCache(JNIEnv* env) noexcept;
void ReleaseCache(JNIEnv* env) noexcept;

struct CallbackContext {
  int64_t correlation_id = 0;
};

CallbackContext* MakeCallbackContext(int64_t correlation_id) noexcept;
flm_progress_callback GetProgressCallback() noexcept;
flm_delta_callback GetDeltaCallback() noexcept;
flm_completion_callback GetCompletionCallback() noexcept;

}  // namespace flm_android

#endif  // FOUNDRY_LOCAL_MOBILE_ANDROID_JNI_COMMON_H_
