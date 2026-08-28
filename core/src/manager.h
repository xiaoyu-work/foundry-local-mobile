// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Manager: owns the job pool, the in-memory model registry and device profile.
// No catalog, no download, no transport.

#ifndef FOUNDRY_LOCAL_MOBILE_MANAGER_H_
#define FOUNDRY_LOCAL_MOBILE_MANAGER_H_

#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "device_profile.h"
#include "job.h"
#include "third_party/json.h"

namespace flm {

class Model;

/// Settings that can change without recreating the manager.
struct MutableSettings {
  bool auto_unload_on_background = true;
  flm_log_level log_level = FLM_LOG_WARNING;
};

class Manager : public std::enable_shared_from_this<Manager> {
 public:
  /// Build from the JSON configuration documented on flm_manager_create.
  static std::shared_ptr<Manager> Create(const nlohmann::json& config);

  ~Manager();

  Manager(const Manager&) = delete;
  Manager& operator=(const Manager&) = delete;

  JobPool& job_pool() noexcept { return *job_pool_; }
  const std::string& app_name() const noexcept { return app_name_; }
  const std::string& app_data_dir() const noexcept { return app_data_dir_; }

  /// Track a live model without extending its lifetime beyond its public handles.
  void RegisterModel(const std::shared_ptr<Model>& model);

  /// Snapshot of the current settings.
  MutableSettings settings() const;
  void UpdateSettings(const nlohmann::json& settings_json);

  /// Device profile.
  DeviceProfile device_profile();

  void NotifyLifecycle(flm_lifecycle_event event);

  void Shutdown();
  bool is_shutdown() const noexcept { return shutdown_.load(std::memory_order_acquire); }

  void ThrowIfShutdown() const;

  void set_handle(flm_handle handle) noexcept { handle_ = handle; }
  flm_handle handle() const noexcept { return handle_; }

 private:
  Manager() = default;

  void Initialize(const nlohmann::json& config);
  void UnloadAllModels();

  std::unique_ptr<JobPool> job_pool_;

  std::string app_name_;
  std::string app_data_dir_;

  mutable std::mutex mutex_;
  MutableSettings settings_;
  std::atomic<bool> shutdown_{false};
  flm_handle handle_ = FLM_INVALID_HANDLE;

  /// Weak registry used only for lifecycle unload/reload notifications.
  std::vector<std::weak_ptr<Model>> models_;

  /// Models unloaded because the app was backgrounded.
  std::vector<std::weak_ptr<Model>> auto_unloaded_models_;
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_MANAGER_H_
