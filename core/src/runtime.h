// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Binding to the upstream Foundry Local runtime.
//
// Upstream exposes its functionality through versioned structs of function pointers
// reached from three exported symbols. Walking those tables is done exactly once, here,
// so the rest of the core (and every language binding) sees ordinary C++ calls.
//
// The runtime is loaded dynamically rather than link-time bound. On mobile that matters:
// the app may ship the runtime as a separate download to keep the initial APK/IPA small,
// and a missing runtime must produce a clear error instead of a startup crash.

#ifndef FOUNDRY_LOCAL_MOBILE_RUNTIME_H_
#define FOUNDRY_LOCAL_MOBILE_RUNTIME_H_

#include <memory>
#include <string>
#include <string_view>

#include "error.h"

// Upstream headers. Provided by the Foundry Local SDK; see docs/building.md.
#include "foundry_local/foundry_local_c.h"

namespace flm {

/// Owns the loaded runtime library and its API tables. Process-wide singleton.
class Runtime {
 public:
  /// Load the runtime, or throw Error(FLM_ERROR_NOT_IMPLEMENTED) with a diagnostic that
  /// names the paths searched. Idempotent and thread-safe.
  static Runtime& Instance();

  /// Explicitly point at the runtime shared library. Must be called before Instance().
  /// Android bindings use this to pass the value of ApplicationInfo.nativeLibraryDir,
  /// which is the only reliable way to find a bundled .so across all OEM devices.
  static void SetLibraryPath(std::string path);

  /// Whether the runtime loaded successfully, without throwing.
  static bool IsAvailable() noexcept;

  const flApi& api() const noexcept { return *api_; }
  const flCatalogApi& catalog_api() const noexcept { return *catalog_api_; }
  const flConfigurationApi& config_api() const noexcept { return *config_api_; }
  const flItemApi& item_api() const noexcept { return *item_api_; }
  const flInferenceApi& inference_api() const noexcept { return *inference_api_; }
  const flModelApi& model_api() const noexcept { return *model_api_; }

  const std::string& version() const noexcept { return version_; }

  /// Convert an upstream flStatus* into an Error and release it. No-op when null.
  /// Every upstream call site funnels through this so error mapping stays in one place.
  /// `operation` is folded into the message, so callers may compose it with the model or
  /// alias involved without needing a separate buffer to keep alive.
  void Check(flStatus* status, std::string_view operation) const;

  /// Same, but returns the status code instead of throwing. For destructors and
  /// best-effort cleanup paths.
  flm_status CheckNoThrow(flStatus* status) const noexcept;

  ~Runtime();

 private:
  Runtime();
  Runtime(const Runtime&) = delete;
  Runtime& operator=(const Runtime&) = delete;

  void LoadLibrary();
  void ResolveApiTables();

  void* library_handle_ = nullptr;
  const flApi* api_ = nullptr;
  const flCatalogApi* catalog_api_ = nullptr;
  const flConfigurationApi* config_api_ = nullptr;
  const flItemApi* item_api_ = nullptr;
  const flInferenceApi* inference_api_ = nullptr;
  const flModelApi* model_api_ = nullptr;
  std::string version_;
};

/// RAII wrapper for an upstream handle released through a table function pointer.
/// Upstream releases take a non-const pointer and never fail, so this stays minimal.
template <typename T, typename Releaser>
class UpstreamHandle {
 public:
  UpstreamHandle() = default;
  UpstreamHandle(T* ptr, Releaser releaser) : ptr_(ptr), releaser_(releaser) {}

  ~UpstreamHandle() { reset(); }

  UpstreamHandle(UpstreamHandle&& other) noexcept : ptr_(other.ptr_), releaser_(other.releaser_) {
    other.ptr_ = nullptr;
  }
  UpstreamHandle& operator=(UpstreamHandle&& other) noexcept {
    if (this != &other) {
      reset();
      ptr_ = other.ptr_;
      releaser_ = other.releaser_;
      other.ptr_ = nullptr;
    }
    return *this;
  }

  UpstreamHandle(const UpstreamHandle&) = delete;
  UpstreamHandle& operator=(const UpstreamHandle&) = delete;

  T* get() const noexcept { return ptr_; }
  T** put() noexcept {
    reset();
    return &ptr_;
  }
  explicit operator bool() const noexcept { return ptr_ != nullptr; }

  void reset() noexcept {
    if (ptr_ != nullptr && releaser_ != nullptr) {
      releaser_(ptr_);
    }
    ptr_ = nullptr;
  }

  T* release() noexcept {
    T* ptr = ptr_;
    ptr_ = nullptr;
    return ptr;
  }

 private:
  T* ptr_ = nullptr;
  Releaser releaser_ = nullptr;
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_RUNTIME_H_
