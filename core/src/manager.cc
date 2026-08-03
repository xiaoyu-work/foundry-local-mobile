// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "manager.h"

#include <filesystem>

#include "catalog.h"

namespace flm {
namespace {

namespace fs = std::filesystem;

flLogLevel ToUpstreamLogLevel(flm_log_level level) noexcept {
  switch (level) {
    case FLM_LOG_VERBOSE: return FOUNDRY_LOCAL_LOG_VERBOSE;
    case FLM_LOG_DEBUG: return FOUNDRY_LOCAL_LOG_DEBUG;
    case FLM_LOG_INFO: return FOUNDRY_LOCAL_LOG_INFO;
    case FLM_LOG_WARNING: return FOUNDRY_LOCAL_LOG_WARNING;
    case FLM_LOG_ERROR: return FOUNDRY_LOCAL_LOG_ERROR;
    case FLM_LOG_FATAL:
    case FLM_LOG_OFF: return FOUNDRY_LOCAL_LOG_FATAL;
  }
  return FOUNDRY_LOCAL_LOG_WARNING;
}

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
  // Cannot use make_shared: the constructor is private.
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
  if (app_data_dir_.empty()) {
    // Mobile processes have no meaningful home directory, and the upstream default of
    // ~/.<app_name> resolves somewhere unwritable inside an app sandbox. Failing here
    // with a clear message beats a confusing permission error on first download.
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "'app_data_dir' is required on mobile. Pass the app's private data directory "
                "(Context.getFilesDir() on Android, the Application Support directory on iOS).");
  }

  model_cache_dir_ = config.value("model_cache_dir", "");
  if (model_cache_dir_.empty()) {
    model_cache_dir_ = (fs::path(app_data_dir_) / "models").string();
  }

  std::error_code ec;
  fs::create_directories(app_data_dir_, ec);
  fs::create_directories(model_cache_dir_, ec);
  if (ec) {
    throw Error(FLM_ERROR_STORAGE, "could not create the app data directory: " + ec.message(),
                {{"app_data_dir", app_data_dir_}});
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    settings_.download_on_metered_network = config.value("download_on_metered_network", false);
    settings_.max_concurrent_downloads = config.value("max_concurrent_downloads", 2);
    settings_.auto_unload_on_background = config.value("auto_unload_on_background", true);
    settings_.offline = config.value("offline", false);
    settings_.log_level = ParseLogLevel(config.value("log_level", "warning"));
  }

  const Runtime& runtime = Runtime::Instance();
  const flConfigurationApi& config_api = runtime.config_api();

  UpstreamHandle<flConfiguration, void (*)(flConfiguration*)> upstream_config(nullptr, config_api.Configuration_Release);
  runtime.Check(config_api.Create(app_name_.c_str(), upstream_config.put()), "create configuration");

  runtime.Check(config_api.SetAppDataDir(upstream_config.get(), app_data_dir_.c_str()), "set app data dir");
  runtime.Check(config_api.SetModelCacheDir(upstream_config.get(), model_cache_dir_.c_str()), "set model cache dir");
  runtime.Check(config_api.SetDefaultLogLevel(upstream_config.get(), ToUpstreamLogLevel(settings_.log_level)),
                "set log level");

  const std::string logs_dir = config.value("logs_dir", (fs::path(app_data_dir_) / "logs").string());
  fs::create_directories(logs_dir, ec);
  runtime.Check(config_api.SetLogsDir(upstream_config.get(), logs_dir.c_str()), "set logs dir");

  if (auto urls = config.find("catalog_urls"); urls != config.end() && urls->is_array()) {
    for (const auto& url : *urls) {
      if (url.is_string()) {
        runtime.Check(config_api.AddCatalogUrl(upstream_config.get(), url.get<std::string>().c_str(), nullptr),
                      "add catalog url");
      }
    }
  }
  if (auto region = config.find("catalog_region"); region != config.end() && region->is_string()) {
    runtime.Check(config_api.SetCatalogRegion(upstream_config.get(), region->get<std::string>().c_str()),
                  "set catalog region");
  }

  if (auto options = config.find("additional_options"); options != config.end() && options->is_object()) {
    flKeyValuePairs* pairs = nullptr;
    runtime.api().CreateKeyValuePairs(&pairs);
    UpstreamHandle<flKeyValuePairs, void (*)(flKeyValuePairs*)> owned_pairs(pairs,
                                                                           runtime.api().KeyValuePairs_Release);
    for (const auto& [key, value] : options->items()) {
      const std::string text = value.is_string() ? value.get<std::string>() : value.dump();
      runtime.api().AddKeyValuePair(owned_pairs.get(), key.c_str(), text.c_str());
    }
    runtime.Check(config_api.SetAdditionalOptions(upstream_config.get(), owned_pairs.get()), "set additional options");
  }

  runtime.Check(runtime.api().Manager_Create(upstream_config.get(), &upstream_manager_), "create manager");

  job_pool_ = std::make_unique<JobPool>(static_cast<size_t>(config.value("job_pool_threads", 0)));

  ImportRuntimeExecutionProviders();
}

Manager::~Manager() {
  Shutdown();
  if (upstream_manager_ != nullptr) {
    Runtime::Instance().api().Manager_Release(upstream_manager_);
    upstream_manager_ = nullptr;
  }
}

void Manager::ImportRuntimeExecutionProviders() {
  // The runtime knows which EPs actually registered; platform detection only knows what
  // the hardware could support. Merging gives variant scoring the truth.
  const Runtime& runtime = Runtime::Instance();
  const flEpInfo* eps = nullptr;
  size_t count = 0;
  flStatus* status = runtime.api().Manager_GetDiscoverableEps(upstream_manager_, &eps, &count);
  if (status != nullptr) {
    // EP discovery is best-effort: a device with no discoverable EPs still runs on CPU.
    runtime.CheckNoThrow(status);
    return;
  }

  std::vector<ExecutionProviderInfo> providers;
  providers.reserve(count);
  for (size_t i = 0; i < count; ++i) {
    ExecutionProviderInfo info;
    info.name = eps[i].name != nullptr ? eps[i].name : "";
    if (info.name.empty()) {
      continue;
    }
    // flEpInfo carries only a name and a registration flag, so derive placement from
    // the name. A provider the platform backend already knows keeps its richer data.
    ClassifyExecutionProvider(info.name, &info.device, &info.priority);
    info.available = eps[i].is_registered;
    providers.push_back(std::move(info));
  }
  MergeRuntimeExecutionProviders(std::move(providers));
}

std::shared_ptr<Catalog> Manager::catalog() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!catalog_) {
    ThrowIfShutdown();
    flCatalog* upstream_catalog = nullptr;
    const Runtime& runtime = Runtime::Instance();
    runtime.Check(runtime.api().Manager_GetCatalog(upstream_manager_, &upstream_catalog), "get catalog");
    catalog_ = std::make_shared<Catalog>(shared_from_this(), upstream_catalog);
  }
  return catalog_;
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
  if (auto it = settings_json.find("download_on_metered_network"); it != settings_json.end() && it->is_boolean()) {
    settings_.download_on_metered_network = it->get<bool>();
  }
  if (auto it = settings_json.find("max_concurrent_downloads"); it != settings_json.end() && it->is_number_integer()) {
    settings_.max_concurrent_downloads = std::max(1, it->get<int>());
  }
  if (auto it = settings_json.find("auto_unload_on_background"); it != settings_json.end() && it->is_boolean()) {
    settings_.auto_unload_on_background = it->get<bool>();
  }
  if (auto it = settings_json.find("offline"); it != settings_json.end() && it->is_boolean()) {
    settings_.offline = it->get<bool>();
  }
  if (auto it = settings_json.find("log_level"); it != settings_json.end() && it->is_string()) {
    settings_.log_level = ParseLogLevel(it->get<std::string>());
  }
}

DeviceProfile Manager::device_profile() { return GetDeviceProfile(); }

void Manager::NotifyLifecycle(flm_lifecycle_event event) {
  switch (event) {
    case FLM_LIFECYCLE_MEMORY_CRITICAL:
      // The OS is about to kill us. Dropping the models is the only way to survive, and
      // reloading from the page cache afterwards is fast.
      UnloadAllModels();
      break;

    case FLM_LIFECYCLE_BACKGROUND:
      if (settings().auto_unload_on_background) {
        UnloadAllModels();
      }
      break;

    case FLM_LIFECYCLE_MEMORY_WARNING:
    case FLM_LIFECYCLE_THERMAL_THROTTLING:
    case FLM_LIFECYCLE_LOW_POWER:
    case FLM_LIFECYCLE_FOREGROUND:
      // Re-detect so the next variant selection sees current memory, thermal and power
      // state rather than a stale snapshot from launch.
      RefreshDeviceProfile();
      break;

    case FLM_LIFECYCLE_NETWORK_METERED: {
      std::lock_guard<std::mutex> lock(mutex_);
      settings_.download_on_metered_network = false;
      break;
    }
    case FLM_LIFECYCLE_NETWORK_UNMETERED:
      RefreshDeviceProfile();
      break;
  }
}

void Manager::UnloadAllModels() {
  if (upstream_manager_ == nullptr || is_shutdown()) {
    return;
  }
  const Runtime& runtime = Runtime::Instance();
  flCatalog* upstream_catalog = nullptr;
  if (runtime.CheckNoThrow(runtime.api().Manager_GetCatalog(upstream_manager_, &upstream_catalog)) != FLM_OK) {
    return;
  }

  flModelList* loaded = nullptr;
  if (runtime.CheckNoThrow(runtime.catalog_api().GetLoadedModels(upstream_catalog, &loaded)) != FLM_OK) {
    return;
  }
  UpstreamHandle<flModelList, void (*)(flModelList*)> owned_list(loaded, runtime.api().ModelList_Release);

  const size_t count = runtime.api().ModelList_Size(owned_list.get());
  std::vector<std::string> unloaded;
  for (size_t i = 0; i < count; ++i) {
    flModel* model = runtime.api().ModelList_GetAt(owned_list.get(), i);
    if (model == nullptr) {
      continue;
    }
    const flModelInfo* info = nullptr;
    if (runtime.CheckNoThrow(runtime.model_api().GetInfo(model, &info)) == FLM_OK && info != nullptr) {
      if (const char* id = runtime.model_api().Info_GetId(info)) {
        unloaded.emplace_back(id);
      }
    }
    runtime.CheckNoThrow(runtime.model_api().Unload(model));
  }

  std::lock_guard<std::mutex> lock(mutex_);
  auto_unloaded_model_ids_ = std::move(unloaded);
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
  // Stop our own jobs first so nothing is mid-call into the runtime when it tears down.
  if (job_pool_) {
    job_pool_->Shutdown();
  }
  if (upstream_manager_ != nullptr) {
    Runtime::Instance().CheckNoThrow(Runtime::Instance().api().Manager_Shutdown(upstream_manager_));
  }
}

}  // namespace flm
