// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "manager.h"

#include <algorithm>
#include <filesystem>

#include "model.h"

namespace flm {
namespace {

namespace fs = std::filesystem;

flm_log_level ParseLogLevel(const std::string& value) noexcept {
  if (value == "verbose" || value == "trace") return FLM_LOG_VERBOSE;
  if (value == "debug") return FLM_LOG_DEBUG;
  if (value == "info") return FLM_LOG_INFO;
  if (value == "warning" || value == "warn") return FLM_LOG_WARNING;
  if (value == "error") return FLM_LOG_ERROR;
  if (value == "fatal") return FLM_LOG_FATAL;
  if (value == "off" || value == "none") return FLM_LOG_OFF;
  return FLM_LOG_WARNING;
}

}  // namespace

std::shared_ptr<Manager> Manager::Create(const nlohmann::json& config) {
  std::shared_ptr<Manager> manager(new Manager());
  manager->Initialize(config);
  return manager;
}

void Manager::Initialize(const nlohmann::json& config) {
  if (!config.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "configuration must be a JSON object");
  }

  app_name_ = config.value("app_name", "");
  if (app_name_.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "'app_name' is required and must not be empty");
  }

  app_data_dir_ = config.value("app_data_dir", "");
  if (!app_data_dir_.empty()) {
    std::error_code ec;
    fs::create_directories(app_data_dir_, ec);
    if (ec) {
      throw Error(FLM_ERROR_STORAGE, "could not create the app data directory: " + ec.message(),
                  {{"app_data_dir", app_data_dir_}});
    }
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    settings_.auto_unload_on_background = config.value("auto_unload_on_background", true);
    settings_.log_level = ParseLogLevel(config.value("log_level", "warning"));
  }

  job_pool_ = std::make_unique<JobPool>(static_cast<size_t>(config.value("job_pool_threads", 0)));
}

Manager::~Manager() {
  Shutdown();
}

void Manager::RegisterModel(const std::shared_ptr<Model>& model) {
  std::lock_guard<std::mutex> lock(mutex_);
  models_.erase(std::remove_if(models_.begin(), models_.end(),
                               [](const std::weak_ptr<Model>& entry) { return entry.expired(); }),
                models_.end());
  models_.push_back(model);
}

MutableSettings Manager::settings() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return settings_;
}

void Manager::UpdateSettings(const nlohmann::json& settings_json) {
  if (!settings_json.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "settings must be a JSON object");
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (auto it = settings_json.find("auto_unload_on_background"); it != settings_json.end() && it->is_boolean()) {
    settings_.auto_unload_on_background = it->get<bool>();
  }
  if (auto it = settings_json.find("log_level"); it != settings_json.end() && it->is_string()) {
    settings_.log_level = ParseLogLevel(it->get<std::string>());
  }
}

DeviceProfile Manager::device_profile() { return GetDeviceProfile(); }

void Manager::NotifyLifecycle(flm_lifecycle_event event) {
  switch (event) {
    case FLM_LIFECYCLE_MEMORY_CRITICAL:
      UnloadAllModels();
      break;

    case FLM_LIFECYCLE_BACKGROUND:
      if (settings().auto_unload_on_background) {
        UnloadAllModels();
      }
      break;

    case FLM_LIFECYCLE_FOREGROUND:
      RefreshDeviceProfile();
      {
        std::vector<std::shared_ptr<Model>> models_to_reload;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          for (const auto& entry : auto_unloaded_models_) {
            if (auto model = entry.lock()) {
              models_to_reload.push_back(std::move(model));
            }
          }
          auto_unloaded_models_.clear();
        }
        for (auto& model : models_to_reload) {
          if (model->IsCached() && !model->IsLoaded()) {
            job_pool_->Submit(std::make_shared<Job>("model.reload", [model](JobContext& ctx) {
              model->Reload(ctx);
              return nlohmann::json::object();
            }));
          }
        }
      }
      break;

    case FLM_LIFECYCLE_MEMORY_WARNING:
    case FLM_LIFECYCLE_THERMAL_THROTTLING:
    case FLM_LIFECYCLE_LOW_POWER:
      RefreshDeviceProfile();
      break;

    case FLM_LIFECYCLE_NETWORK_METERED:
    case FLM_LIFECYCLE_NETWORK_UNMETERED:
      break;
  }
}

void Manager::UnloadAllModels() {
  std::vector<std::shared_ptr<Model>> models_to_unload;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<std::weak_ptr<Model>> live_models;
    std::vector<std::weak_ptr<Model>> unloaded;
    for (const auto& entry : models_) {
      if (auto model = entry.lock()) {
        live_models.push_back(model);
        if (!model->IsLoaded()) {
          continue;
        }
        models_to_unload.push_back(model);
        unloaded.push_back(model);
      }
    }
    models_ = std::move(live_models);
    auto_unloaded_models_ = std::move(unloaded);
  }

  for (auto& model : models_to_unload) {
    try {
      model->Unload();
    } catch (...) {
    }
  }
}

void Manager::ThrowIfShutdown() const {
  if (shutdown_.load(std::memory_order_acquire)) {
    throw Error(FLM_ERROR_SHUTDOWN, "the manager is shutting down");
  }
}

void Manager::Shutdown() {
  if (shutdown_.exchange(true, std::memory_order_acq_rel)) {
    return;
  }
  if (job_pool_) {
    job_pool_->Shutdown();
  }
  UnloadAllModels();

  std::lock_guard<std::mutex> lock(mutex_);
  models_.clear();
  auto_unloaded_models_.clear();
}

}  // namespace flm
