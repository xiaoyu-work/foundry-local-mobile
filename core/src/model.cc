// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "model.h"

#include <filesystem>
#include <fstream>

#include "manager.h"

namespace flm {
namespace {

namespace fs = std::filesystem;

/// Read genai_config.json from a model directory and extract metadata.
nlohmann::json ReadGenaiConfig(const std::string& path) {
  const fs::path config_path = fs::path(path) / "genai_config.json";
  std::error_code ec;
  if (!fs::exists(config_path, ec)) {
    return nlohmann::json::object();
  }
  std::ifstream stream(config_path);
  if (!stream) {
    return nlohmann::json::object();
  }
  try {
    return nlohmann::json::parse(stream, nullptr, false);
  } catch (...) {
    return nlohmann::json::object();
  }
}

/// Compute the total size of all files in a directory.
int64_t DirectorySizeBytes(const std::string& path) {
  std::error_code ec;
  int64_t total = 0;
  for (fs::recursive_directory_iterator it(path, fs::directory_options::skip_permission_denied, ec), end;
       it != end && !ec; it.increment(ec)) {
    if (it->is_regular_file(ec)) {
      total += static_cast<int64_t>(it->file_size(ec));
    }
  }
  return total;
}

/// Map OGA model type string to a task name compatible with the FLM ABI.
std::string ModelTypeToTask(const std::string& model_type) {
  if (model_type.find("gpt") != std::string::npos || model_type.find("llama") != std::string::npos ||
      model_type.find("phi") != std::string::npos || model_type.find("qwen") != std::string::npos ||
      model_type.find("gemma") != std::string::npos || model_type.find("mistral") != std::string::npos) {
    return "chat-completion";
  }
  if (model_type.find("whisper") != std::string::npos) {
    return "audio-transcription";
  }
  if (model_type.find("embed") != std::string::npos) {
    return "embedding";
  }
  return "chat-completion";
}

/// Map OGA device type string to flm_device.
flm_device ParseDeviceType(const std::string& device_type) {
  if (device_type == "CPU" || device_type == "cpu") return FLM_DEVICE_CPU;
  if (device_type == "GPU" || device_type == "gpu" || device_type == "CUDA" || device_type == "cuda" ||
      device_type == "DML" || device_type == "dml") return FLM_DEVICE_GPU;
  if (device_type == "NPU" || device_type == "npu" || device_type == "QNN" || device_type == "qnn")
    return FLM_DEVICE_NPU;
  return FLM_DEVICE_CPU;
}

const char* DeviceToString(flm_device device) noexcept {
  switch (device) {
    case FLM_DEVICE_CPU: return "cpu";
    case FLM_DEVICE_GPU: return "gpu";
    case FLM_DEVICE_NPU: return "npu";
    default: return "unknown";
  }
}

}  // namespace

Model::InferenceLease::InferenceLease(std::shared_ptr<Model> model,
                                      std::unique_lock<std::mutex> lock,
                                      OgaModel* oga_model, OgaTokenizer* oga_tokenizer)
    : model_(std::move(model)),
      lock_(std::move(lock)),
      oga_model_(oga_model),
      oga_tokenizer_(oga_tokenizer) {}

Model::Model(std::shared_ptr<Manager> manager, const std::string& path, const std::string& name)
    : manager_(std::move(manager)), path_(path), name_(name) {
  if (path_.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "model path must not be empty");
  }
  LoadMetadataFromConfig();
}

Model::~Model() {
  try {
    Unload();
  } catch (...) {
  }
}

void Model::LoadMetadataFromConfig() {
  const nlohmann::json config = ReadGenaiConfig(path_);
  metadata_ = nlohmann::json::object();
  metadata_["id"] = name_;
  metadata_["alias"] = name_;
  metadata_["name"] = name_;
  metadata_["display_name"] = name_;
  metadata_["version"] = 1;
  metadata_["publisher"] = "";
  metadata_["license"] = "";
  metadata_["model_type"] = "";

  if (config.contains("model") && config["model"].contains("type")) {
    const std::string model_type = config["model"]["type"].get<std::string>();
    metadata_["model_type"] = model_type;
    metadata_["task"] = ModelTypeToTask(model_type);
  } else {
    metadata_["task"] = "chat-completion";
  }

  metadata_["device"] = "cpu";
  metadata_["execution_provider"] = "";
  metadata_["file_size_bytes"] = DirectorySizeBytes(path_);
  metadata_["context_length"] = 0;
  metadata_["max_output_tokens"] = 0;
  metadata_["supports_tool_calling"] = nullptr;
  metadata_["supports_reasoning"] = nullptr;
  metadata_["input_modalities"] = nlohmann::json::array({"text"});
  metadata_["output_modalities"] = nlohmann::json::array({"text"});
  metadata_["capabilities"] = nlohmann::json::array();
  metadata_["prompt_templates"] = nlohmann::json::object();

  if (config.contains("search")) {
    if (config["search"].contains("max_length")) {
      metadata_["context_length"] = config["search"]["max_length"].get<int64_t>();
    }
    if (config["search"].contains("max_output_tokens")) {
      metadata_["max_output_tokens"] = config["search"]["max_output_tokens"].get<int64_t>();
    }
  }

  metadata_["is_cached"] = true;
  metadata_["is_loaded"] = false;
}

nlohmann::json Model::GetInfo() const {
  std::lock_guard<std::mutex> lock(mutex_);
  nlohmann::json info = metadata_;
  info["is_loaded"] = loaded_;
  info["is_cached"] = IsCached();
  return info;
}

std::string Model::GetId() const { return name_; }

std::string Model::GetTask() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return metadata_.value("task", std::string("chat-completion"));
}

std::string Model::GetPath() const { return path_; }

bool Model::IsCached() const {
  std::error_code ec;
  return fs::is_directory(path_, ec);
}

bool Model::IsLoaded() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return loaded_;
}

Model::InferenceLease Model::AcquireInferenceLease() {
  std::unique_lock<std::mutex> oga_lock(oga_mutex_);
  if (oga_model_ == nullptr || oga_tokenizer_ == nullptr) {
    throw Error(FLM_ERROR_INVALID_STATE, "the model must be loaded before creating an inference lease");
  }
  return InferenceLease(shared_from_this(), std::move(oga_lock), oga_model_, oga_tokenizer_);
}

nlohmann::json Model::Load(const nlohmann::json& options, JobContext& context) {
  manager_->ThrowIfShutdown();

  if (!IsCached()) {
    throw Error(FLM_ERROR_NOT_FOUND,
                "model directory does not exist at the specified path",
                {{"path", path_}});
  }

  std::unique_lock<std::mutex> oga_lock(oga_mutex_);
  auto runtime_lease = Runtime::Instance().AcquireOperationLease();

  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (loaded_) {
      const int64_t bytes = metadata_.value("file_size_bytes", static_cast<int64_t>(0));
      context.ReportProgress(100.0f, "loading");
      return nlohmann::json{{"path", path_}, {"bytes", bytes}};
    }
  }

  context.ThrowIfCancelled();
  context.ReportProgress(0.0f, "loading");

  const DeviceProfile profile = GetDeviceProfile();
  const int64_t model_bytes = metadata_.value("file_size_bytes", static_cast<int64_t>(0));
  const int64_t budget = profile.MaxModelBytes();
  if (model_bytes > 0 && budget > 0 && model_bytes > budget) {
    throw Error(FLM_ERROR_MEMORY_PRESSURE,
                "not enough available memory to load this model",
                {{"model_bytes", model_bytes},
                 {"available_budget_bytes", budget},
                 {"available_memory_bytes", profile.available_memory_bytes}});
  }

  const Runtime& runtime = Runtime::Instance();

  std::string ep;
  nlohmann::json provider_options;
  if (options.is_object()) {
    ep = options.value("execution_provider", std::string());
    if (options.contains("provider_options") && options["provider_options"].is_object()) {
      provider_options = options["provider_options"];
    }
  }

  OgaConfigHandle local_config;
  OgaModelHandle local_model;
  OgaTokenizerHandle local_tokenizer;

  if (!ep.empty()) {
    OgaConfig* config_raw = nullptr;
    const bool is_package =
        fs::exists(fs::path(path_) / "manifest.json") &&
        !fs::exists(fs::path(path_) / "genai_config.json");
    if (is_package) {
      runtime.Check(OgaCreateConfigFromPackageEp(path_.c_str(), ep.c_str(), &config_raw),
                    "create OGA package config");
    } else {
      runtime.Check(OgaCreateConfig(path_.c_str(), &config_raw), "create OGA config");
    }
    local_config = OgaConfigHandle(config_raw);

    if (!is_package) {
      runtime.Check(OgaConfigClearProviders(local_config.get()), "clear providers");
      runtime.Check(OgaConfigAppendProvider(local_config.get(), ep.c_str()), "set provider");
    }

    for (const auto& [key, value] : provider_options.items()) {
      const std::string val_str = value.is_string() ? value.get<std::string>() : value.dump();
      runtime.Check(OgaConfigSetProviderOption(local_config.get(), ep.c_str(), key.c_str(), val_str.c_str()),
                    "set provider option");
    }

    OgaModel* model_raw = nullptr;
    runtime.Check(OgaCreateModelFromConfig(local_config.get(), &model_raw), "create OGA model from config");
    local_model = OgaModelHandle(model_raw);
  } else {
    OgaModel* model_raw = nullptr;
    runtime.Check(OgaCreateModel(path_.c_str(), &model_raw), "create OGA model");
    local_model = OgaModelHandle(model_raw);
  }

  OgaTokenizer* tokenizer_raw = nullptr;
  runtime.Check(OgaCreateTokenizer(local_model.get(), &tokenizer_raw), "create OGA tokenizer");
  local_tokenizer = OgaTokenizerHandle(tokenizer_raw);

  {
    std::lock_guard<std::mutex> lock(mutex_);

    oga_config_ = local_config.release();
    oga_model_ = local_model.release();
    oga_tokenizer_ = local_tokenizer.release();

    runtime.AddRef();

    loaded_ = true;
    execution_provider_ = ep;
    load_options_ = options;

    const char* model_type = nullptr;
    OgaResult* type_result = OgaModelGetType(oga_model_, &model_type);
    if (type_result == nullptr && model_type != nullptr) {
      metadata_["model_type"] = model_type;
      metadata_["task"] = ModelTypeToTask(model_type);
      OgaDestroyString(model_type);
    } else if (type_result != nullptr) {
      OgaDestroyResult(type_result);
    }

    const char* device_type = nullptr;
    OgaResult* device_result = OgaModelGetDeviceType(oga_model_, &device_type);
    if (device_result == nullptr && device_type != nullptr) {
      metadata_["device"] = DeviceToString(ParseDeviceType(device_type));
      OgaDestroyString(device_type);
    } else if (device_result != nullptr) {
      OgaDestroyResult(device_result);
    }

    if (!ep.empty()) {
      metadata_["execution_provider"] = ep;
    }

    metadata_["is_loaded"] = true;
  }

  context.ReportProgress(100.0f, "loading");
  return nlohmann::json{{"path", path_}, {"bytes", model_bytes}};
}

nlohmann::json Model::Reload(JobContext& context) {
  nlohmann::json options;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    options = load_options_;
  }
  return Load(options, context);
}

void Model::Unload() {
  std::unique_lock<std::mutex> oga_lock(oga_mutex_);
  auto runtime_lease = Runtime::Instance().AcquireOperationLease();
  std::lock_guard<std::mutex> lock(mutex_);
  if (!loaded_) {
    return;
  }

  if (oga_tokenizer_ != nullptr) {
    OgaDestroyTokenizer(oga_tokenizer_);
    oga_tokenizer_ = nullptr;
  }
  if (oga_model_ != nullptr) {
    OgaDestroyModel(oga_model_);
    oga_model_ = nullptr;
  }
  if (oga_config_ != nullptr) {
    OgaDestroyConfig(oga_config_);
    oga_config_ = nullptr;
  }
  Runtime::Instance().Release();

  loaded_ = false;
  metadata_["is_loaded"] = false;
}

}  // namespace flm
