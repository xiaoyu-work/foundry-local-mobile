// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// ONNX Runtime GenAI wrapper.
//
// Replaces the former Foundry Local dynamic loader. The core now links directly against
// the ONNX Runtime GenAI C API (ort_genai_c.h) at build time, so there is no runtime
// discovery or version-table walk. The Runtime singleton owns OGA process-wide lifecycle
// (OgaShutdown) and converts OgaResult errors into flm::Error.

#ifndef FOUNDRY_LOCAL_MOBILE_RUNTIME_H_
#define FOUNDRY_LOCAL_MOBILE_RUNTIME_H_

#include <atomic>
#include <memory>
#include <string>
#include <string_view>

#include "error.h"
#include "ort_genai_c.h"

namespace flm {

/// Thin process-wide singleton around the OGA C API lifecycle.
///
/// Construction is a no-op (OGA initialises lazily on first model creation).
/// Destruction calls OgaShutdown after all models/sessions have been destroyed.
class Runtime {
 public:
  static Runtime& Instance();

  /// Always true when linked against OGA.
  static bool IsAvailable() noexcept { return true; }

  /// OGA version string. Populated lazily from a compiled-in constant.
  const std::string& version() const noexcept { return version_; }

  /// Check an OgaResult* and throw Error if non-null. Destroys the result.
  void Check(OgaResult* result, std::string_view operation) const;

  /// Same, but returns a status code instead of throwing. For destructors.
  flm_status CheckNoThrow(OgaResult* result) const noexcept;

  /// Increment/decrement the live-object count. OgaShutdown is deferred until all
  /// objects are destroyed and the Runtime itself is destroyed.
  void AddRef() const noexcept { live_objects_.fetch_add(1, std::memory_order_relaxed); }
  void Release() const noexcept { live_objects_.fetch_sub(1, std::memory_order_relaxed); }

  ~Runtime();

 private:
  Runtime();
  Runtime(const Runtime&) = delete;
  Runtime& operator=(const Runtime&) = delete;

  std::string version_;
  mutable std::atomic<int64_t> live_objects_{0};
};

/// RAII guard for any Oga* handle that has a matching OgaDestroy* function.
template <typename T, void (*Destroy)(T*)>
class OgaHandle {
 public:
  OgaHandle() = default;
  explicit OgaHandle(T* ptr) : ptr_(ptr) {}

  ~OgaHandle() { reset(); }

  OgaHandle(OgaHandle&& other) noexcept : ptr_(other.ptr_) { other.ptr_ = nullptr; }
  OgaHandle& operator=(OgaHandle&& other) noexcept {
    if (this != &other) {
      reset();
      ptr_ = other.ptr_;
      other.ptr_ = nullptr;
    }
    return *this;
  }

  OgaHandle(const OgaHandle&) = delete;
  OgaHandle& operator=(const OgaHandle&) = delete;

  T* get() const noexcept { return ptr_; }
  T** put() noexcept {
    reset();
    return &ptr_;
  }
  explicit operator bool() const noexcept { return ptr_ != nullptr; }

  void reset() noexcept {
    if (ptr_ != nullptr) {
      Destroy(ptr_);
    }
    ptr_ = nullptr;
  }

  T* release() noexcept {
    T* p = ptr_;
    ptr_ = nullptr;
    return p;
  }

 private:
  T* ptr_ = nullptr;
};

// Convenience typedefs for every OGA handle type used in the core.
using OgaConfigHandle = OgaHandle<OgaConfig, OgaDestroyConfig>;
using OgaModelHandle = OgaHandle<OgaModel, OgaDestroyModel>;
using OgaTokenizerHandle = OgaHandle<OgaTokenizer, OgaDestroyTokenizer>;
using OgaTokenizerStreamHandle = OgaHandle<OgaTokenizerStream, OgaDestroyTokenizerStream>;
using OgaSequencesHandle = OgaHandle<OgaSequences, OgaDestroySequences>;
using OgaGeneratorParamsHandle = OgaHandle<OgaGeneratorParams, OgaDestroyGeneratorParams>;
using OgaGeneratorHandle = OgaHandle<OgaGenerator, OgaDestroyGenerator>;
using OgaMultiModalProcessorHandle = OgaHandle<OgaMultiModalProcessor, OgaDestroyMultiModalProcessor>;

/// Destroy adapter for const char* returned by OGA (OgaDestroyString takes const char*).
inline void DestroyOgaString(const char* s) { OgaDestroyString(s); }

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_RUNTIME_H_
