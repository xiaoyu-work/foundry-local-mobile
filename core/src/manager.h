// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Manager: owns the runtime instance, the job pool and the object graph derived from it.

#ifndef FOUNDRY_LOCAL_MOBILE_MANAGER_H_
#define FOUNDRY_LOCAL_MOBILE_MANAGER_H_

#include <memory>
#include <mutex>
#include <string>

#include "device_profile.h"
#include "job.h"
#include "runtime.h"
#include "third_party/json.h"

namespace flm {

class Catalog;

/// Settings that can change without recreating the manager.
struct MutableSettings {
  bool download_on_metered_network = false;
  int max_concurrent_downloads = 2;
  bool auto_unload_on_background = true;
  bool offline = false;
  flm_log_level log_level = FLM_LOG_WARNING;
};

class Manager : public std::enable_shared_from_this<Manager> {
 public:
  /// Build from the JSON configuration documented on flm_manager_create.
  static std::shared_ptr<Manager> Create(const nlohmann::json& config);

  ~Manager();

  Manager(const Manager&) = delete;
  Manager& operator=(const Manager&) = delete;

  flManager* upstream() const noexcept { return upstream_manager_; }
  JobPool& job_pool() noexcept { return *job_pool_; }
  const std::string& app_name() const noexcept { return app_name_; }
  const std::string& model_cache_dir() const noexcept { return model_cache_dir_; }

  std::shared_ptr<Catalog> catalog();

  /// Snapshot of the current settings.
  MutableSettings settings() const;
  void UpdateSettings(const nlohmann::json& settings_json);

  /// Device profile with the runtime's registered execution providers merged in.
  DeviceProfile device_profile();

  void NotifyLifecycle(flm_lifecycle_event event);

  void Shutdown();
  bool is_shutdown() const noexcept { return shutdown_.load(std::memory_order_acquire); }

  /// Throw FLM_ERROR_SHUTDOWN if the manager is shutting down. Called at the top of
  /// every operation that would otherwise touch runtime state during teardown.
  void ThrowIfShutdown() const;

  /// The handle this manager was registered under, used to cascade releases.
  void set_handle(flm_handle handle) noexcept { handle_ = handle; }
  flm_handle handle() const noexcept { return handle_; }

 private:
  Manager() = default;

  void Initialize(const nlohmann::json& config);
  void ImportRuntimeExecutionProviders();
  void UnloadAllModels();

  flManager* upstream_manager_ = nullptr;
  std::unique_ptr<JobPool> job_pool_;
  std::shared_ptr<Catalog> catalog_;

  std::string app_name_;
  std::string app_data_dir_;
  std::string model_cache_dir_;

  mutable std::mutex mutex_;
  MutableSettings settings_;
  std::atomic<bool> shutdown_{false};
  flm_handle handle_ = FLM_INVALID_HANDLE;

  /// Models unloaded because the app was backgrounded, so foregrounding can restore them.
  std::vector<std::string> auto_unloaded_model_ids_;
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_MANAGER_H_
