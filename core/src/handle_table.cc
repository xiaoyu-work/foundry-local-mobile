// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "handle_table.h"

#include <vector>

namespace flm {
namespace {

const char* KindName(HandleKind kind) noexcept {
  switch (kind) {
    case HandleKind::kManager: return "manager";
    case HandleKind::kCatalog: return "catalog";
    case HandleKind::kModel: return "model";
    case HandleKind::kSession: return "session";
    case HandleKind::kJob: return "job";
  }
  return "unknown";
}

}  // namespace

HandleTable& HandleTable::Instance() {
  static HandleTable* instance = new HandleTable();  // Intentionally leaked: outlives static destruction
  return *instance;                                  // so late releases from binding finalizers stay safe.
}

flm_handle HandleTable::AddErased(HandleKind kind, std::shared_ptr<void> object) {
  if (!object) {
    throw Error(FLM_ERROR_INTERNAL, "cannot register a null object");
  }
  std::lock_guard<std::mutex> lock(mutex_);

  // Find a free index. next_index_ advances monotonically and wraps; collisions are
  // resolved by probing, which is effectively free because live counts stay small.
  uint32_t index = next_index_;
  while (slots_.find(index) != slots_.end() || index == 0) {
    ++index;
  }
  next_index_ = index + 1;

  Slot slot;
  slot.kind = kind;
  slot.generation = 1;
  slot.object = std::move(object);
  slots_.emplace(index, std::move(slot));
  return Pack(kind, 1, index);
}

std::shared_ptr<void> HandleTable::TryGetErased(flm_handle handle, HandleKind expected_kind) noexcept {
  if (handle == FLM_INVALID_HANDLE) {
    return nullptr;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = slots_.find(IndexOf(handle));
  if (it == slots_.end()) {
    return nullptr;
  }
  const Slot& slot = it->second;
  if (slot.kind != expected_kind || slot.generation != GenerationOf(handle)) {
    return nullptr;
  }
  return slot.object;
}

std::shared_ptr<void> HandleTable::GetErased(flm_handle handle, HandleKind expected_kind) {
  if (handle == FLM_INVALID_HANDLE) {
    throw Error(FLM_ERROR_INVALID_HANDLE, std::string("null ") + KindName(expected_kind) + " handle");
  }
  auto object = TryGetErased(handle, expected_kind);
  if (!object) {
    // Distinguish "wrong type" from "released" — the two have very different fixes in
    // binding code, and the caller only sees this message.
    const HandleKind actual = KindOf(handle);
    const bool kind_mismatch = actual != expected_kind;
    throw Error(FLM_ERROR_INVALID_HANDLE,
                kind_mismatch ? std::string("expected a ") + KindName(expected_kind) + " handle but received a " +
                                    KindName(actual) + " handle"
                              : std::string("stale or released ") + KindName(expected_kind) + " handle",
                {{"handle", handle}, {"expected_kind", KindName(expected_kind)}, {"actual_kind", KindName(actual)}});
  }
  return object;
}

bool HandleTable::Remove(flm_handle handle, HandleKind expected_kind) noexcept {
  if (handle == FLM_INVALID_HANDLE) {
    return false;
  }
  // Hold the removed object until after the lock is dropped: its destructor may release
  // other handles (a manager releasing its models, for example), which would deadlock.
  std::shared_ptr<void> released;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = slots_.find(IndexOf(handle));
    if (it == slots_.end()) {
      return false;
    }
    Slot& slot = it->second;
    if (slot.kind != expected_kind || slot.generation != GenerationOf(handle)) {
      return false;
    }
    released = std::move(slot.object);

    // Bump the generation so the freed slot can never be addressed by the old handle.
    // On overflow, retire the slot permanently rather than risk aliasing.
    if (slot.generation >= kMaxGeneration) {
      slots_.erase(it);
    } else {
      slot.generation++;
      slots_.erase(it);
    }
  }
  return true;
}

void HandleTable::SetOwner(flm_handle handle, flm_handle owner_manager) noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = slots_.find(IndexOf(handle));
  if (it != slots_.end() && it->second.generation == GenerationOf(handle)) {
    it->second.owner_manager = owner_manager;
  }
}

void HandleTable::RemoveAllOwnedBy(flm_handle owner_manager) noexcept {
  std::vector<std::shared_ptr<void>> released;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto it = slots_.begin(); it != slots_.end();) {
      if (it->second.owner_manager == owner_manager) {
        released.push_back(std::move(it->second.object));
        it = slots_.erase(it);
      } else {
        ++it;
      }
    }
  }
  // Destructors run here, outside the lock.
}

size_t HandleTable::LiveCount() const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  return slots_.size();
}

}  // namespace flm
