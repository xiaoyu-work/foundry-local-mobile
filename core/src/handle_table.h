// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Handle table mapping opaque uint64 handles to reference-counted objects.
//
// Bindings hold handles across FFI boundaries where a use-after-free would otherwise be
// an unrecoverable crash inside someone else's runtime (the JVM, the Dart VM, a Swift
// task). Two properties make that safe:
//
//   1. Handles carry a generation counter, so a slot reused after release does not
//      resurrect an old handle. A stale handle resolves to FLM_ERROR_INVALID_HANDLE.
//   2. Lookup returns a shared_ptr, so an object cannot be destroyed while a job is
//      still using it — release only drops the table's reference.

#ifndef FOUNDRY_LOCAL_MOBILE_HANDLE_TABLE_H_
#define FOUNDRY_LOCAL_MOBILE_HANDLE_TABLE_H_

#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>

#include "error.h"
#include "foundry_local_mobile/flm_types.h"

namespace flm {

/// Object categories encoded in a handle so that passing, say, a session handle where a
/// model handle is expected fails cleanly instead of reinterpreting memory.
enum class HandleKind : uint8_t {
  kManager = 1,
  kCatalog = 2,
  kModel = 3,
  kSession = 4,
  kJob = 5,
};

/// Handle layout: [ kind: 8 bits | generation: 24 bits | index: 32 bits ].
/// 4 billion live objects and 16 million reuses per slot are both far beyond any real
/// mobile workload, and the packing keeps handles printable in logs.
class HandleTable {
 public:
  static HandleTable& Instance();

  template <typename T>
  flm_handle Add(HandleKind kind, std::shared_ptr<T> object) {
    return AddErased(kind, std::static_pointer_cast<void>(std::move(object)));
  }

  /// Resolve a handle, or throw Error(FLM_ERROR_INVALID_HANDLE).
  template <typename T>
  std::shared_ptr<T> Get(flm_handle handle, HandleKind expected_kind) {
    return std::static_pointer_cast<T>(GetErased(handle, expected_kind));
  }

  /// Resolve without throwing. Returns nullptr when the handle is unknown or stale.
  template <typename T>
  std::shared_ptr<T> TryGet(flm_handle handle, HandleKind expected_kind) noexcept {
    return std::static_pointer_cast<T>(TryGetErased(handle, expected_kind));
  }

  /// Drop the table's reference. Returns false if the handle was already invalid.
  bool Remove(flm_handle handle, HandleKind expected_kind) noexcept;

  /// Drop every handle of a kind whose owner matches `owner_manager`. Used when a manager
  /// is released so derived handles fail cleanly rather than touching freed runtime state.
  void RemoveAllOwnedBy(flm_handle owner_manager) noexcept;

  /// Associate a handle with the manager that owns it, for RemoveAllOwnedBy.
  void SetOwner(flm_handle handle, flm_handle owner_manager) noexcept;

  size_t LiveCount() const noexcept;

 private:
  HandleTable() = default;

  flm_handle AddErased(HandleKind kind, std::shared_ptr<void> object);
  std::shared_ptr<void> GetErased(flm_handle handle, HandleKind expected_kind);
  std::shared_ptr<void> TryGetErased(flm_handle handle, HandleKind expected_kind) noexcept;

  struct Slot {
    HandleKind kind;
    uint32_t generation;
    flm_handle owner_manager = FLM_INVALID_HANDLE;
    std::shared_ptr<void> object;
  };

  static constexpr uint64_t kIndexMask = 0x00000000FFFFFFFFULL;
  static constexpr uint64_t kGenerationMask = 0x00FFFFFF00000000ULL;
  static constexpr int kGenerationShift = 32;
  static constexpr int kKindShift = 56;
  static constexpr uint32_t kMaxGeneration = 0x00FFFFFF;

  static flm_handle Pack(HandleKind kind, uint32_t generation, uint32_t index) noexcept {
    return (static_cast<uint64_t>(kind) << kKindShift) |
           ((static_cast<uint64_t>(generation) & 0xFFFFFF) << kGenerationShift) | index;
  }
  static uint32_t IndexOf(flm_handle handle) noexcept { return static_cast<uint32_t>(handle & kIndexMask); }
  static uint32_t GenerationOf(flm_handle handle) noexcept {
    return static_cast<uint32_t>((handle & kGenerationMask) >> kGenerationShift);
  }
  static HandleKind KindOf(flm_handle handle) noexcept {
    return static_cast<HandleKind>((handle >> kKindShift) & 0xFF);
  }

  mutable std::mutex mutex_;
  std::unordered_map<uint32_t, Slot> slots_;
  uint32_t next_index_ = 1;  // Index 0 is reserved so FLM_INVALID_HANDLE is never valid.
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_HANDLE_TABLE_H_
