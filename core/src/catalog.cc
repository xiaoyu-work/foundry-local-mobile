// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "catalog.h"

#include <filesystem>

#include "model.h"

namespace flm {
namespace {

namespace fs = std::filesystem;

/// Read a string property, tolerating the null returns upstream uses for "not set".
std::string StringProperty(const flModelApi& api, const flModelInfo* info, const char* key) {
  const char* value = api.Info_GetStringProperty(info, key);
  return value != nullptr ? std::string(value) : std::string();
}

std::vector<std::string> SplitCsv(const std::string& value) {
  std::vector<std::string> parts;
  size_t start = 0;
  while (start <= value.size() && !value.empty()) {
    size_t end = value.find(',', start);
    if (end == std::string::npos) {
      end = value.size();
    }
    std::string part = value.substr(start, end - start);
    part.erase(0, part.find_first_not_of(" \t"));
    if (const size_t last = part.find_last_not_of(" \t"); last != std::string::npos) {
      part.erase(last + 1);
    }
    if (!part.empty()) {
      parts.push_back(std::move(part));
    }
    if (end == value.size()) {
      break;
    }
    start = end + 1;
  }
  return parts;
}

}  // namespace

/// Serialize an upstream flModel into the JSON documented on flm_model_get_info_json.
/// Shared with Model::GetInfo, which is why it lives here rather than in an anonymous
/// namespace in one translation unit.
nlohmann::json SerializeModelInfo(const Runtime& runtime, flModel* model) {
  const flModelInfo* info = nullptr;
  runtime.Check(runtime.model_api().GetInfo(model, &info), "get model info");
  if (info == nullptr) {
    throw Error(FLM_ERROR_INTERNAL, "the runtime returned no model info");
  }

  const flModelApi& api = runtime.model_api();
  nlohmann::json json;

  const char* id = api.Info_GetId(info);
  json["id"] = id != nullptr ? id : "";
  const char* name = api.Info_GetName(info);
  json["name"] = name != nullptr ? name : "";
  const char* alias = api.Info_GetAlias(info);
  json["alias"] = alias != nullptr ? alias : "";
  json["version"] = api.Info_GetVersion(info);

  const char* uri = api.Info_GetUri(info);
  json["uri"] = uri != nullptr ? uri : "";

  const char* task = api.Info_GetTask(info);
  json["task"] = task != nullptr ? task : "";
  json["device"] = ToString(static_cast<flm_device>(api.Info_GetDeviceType(info)));
  const char* ep = api.Info_GetExecutionProvider(info);
  json["execution_provider"] = ep != nullptr ? ep : "";

  const std::string display_name = StringProperty(api, info, FOUNDRY_LOCAL_MODEL_PROP_DISPLAY_NAME_STR);
  json["display_name"] = display_name.empty() ? json["name"].get<std::string>() : display_name;
  json["publisher"] = StringProperty(api, info, FOUNDRY_LOCAL_MODEL_PROP_PUBLISHER_STR);
  json["license"] = StringProperty(api, info, FOUNDRY_LOCAL_MODEL_PROP_LICENSE_STR);
  json["model_type"] = StringProperty(api, info, FOUNDRY_LOCAL_MODEL_PROP_MODEL_TYPE_STR);

  // Upstream reports size in megabytes; bindings and UIs want bytes, and converting once
  // here keeps every caller from re-deriving it.
  const int64_t filesize_mb = api.Info_GetIntProperty(info, FOUNDRY_LOCAL_MODEL_PROP_FILESIZE_MB_INT, 0);
  json["file_size_bytes"] = filesize_mb * 1024 * 1024;

  json["context_length"] = api.Info_GetIntProperty(info, FOUNDRY_LOCAL_MODEL_PROP_CONTEXT_LENGTH_INT, 0);
  json["max_output_tokens"] = api.Info_GetIntProperty(info, FOUNDRY_LOCAL_MODEL_PROP_MAX_OUTPUT_TOKENS_INT, 0);

  // Tri-state upstream: -1 means "unknown", which is not the same as false.
  const int64_t tool_calling = api.Info_GetIntProperty(info, FOUNDRY_LOCAL_MODEL_PROP_SUPPORTS_TOOL_CALLING_INT, -1);
  json["supports_tool_calling"] = tool_calling < 0 ? nlohmann::json(nullptr) : nlohmann::json(tool_calling != 0);
  const int64_t reasoning = api.Info_GetIntProperty(info, FOUNDRY_LOCAL_MODEL_PROP_SUPPORTS_REASONING_INT, -1);
  json["supports_reasoning"] = reasoning < 0 ? nlohmann::json(nullptr) : nlohmann::json(reasoning != 0);

  json["input_modalities"] = SplitCsv(StringProperty(api, info, FOUNDRY_LOCAL_MODEL_PROP_INPUT_MODALITIES_STR));
  json["output_modalities"] = SplitCsv(StringProperty(api, info, FOUNDRY_LOCAL_MODEL_PROP_OUTPUT_MODALITIES_STR));
  json["capabilities"] = SplitCsv(StringProperty(api, info, FOUNDRY_LOCAL_MODEL_PROP_CAPABILITIES_STR));

  if (const flKeyValuePairs* templates = api.Info_GetPromptTemplates(info)) {
    nlohmann::json prompt_templates = nlohmann::json::object();
    const char* const* keys = nullptr;
    const char* const* values = nullptr;
    size_t count = 0;
    runtime.api().GetKeyValuePairs(templates, &keys, &values, &count);
    for (size_t i = 0; i < count; ++i) {
      if (keys[i] != nullptr) {
        prompt_templates[keys[i]] = values[i] != nullptr ? values[i] : "";
      }
    }
    json["prompt_templates"] = std::move(prompt_templates);
  }

  int cached = 0;
  if (runtime.CheckNoThrow(api.IsCached(model, &cached)) == FLM_OK) {
    json["is_cached"] = cached != 0;
  }
  int loaded = 0;
  if (runtime.CheckNoThrow(api.IsLoaded(model, &loaded)) == FLM_OK) {
    json["is_loaded"] = loaded != 0;
  }

  return json;
}

Catalog::Catalog(std::shared_ptr<Manager> manager, flCatalog* upstream)
    : manager_(std::move(manager)), upstream_(upstream) {
  if (upstream_ == nullptr) {
    throw Error(FLM_ERROR_INTERNAL, "the runtime returned a null catalog");
  }
}

nlohmann::json Catalog::ListModels(const nlohmann::json& filter, JobContext& context) {
  manager_->ThrowIfShutdown();
  const Runtime& runtime = Runtime::Instance();

  context.ReportProgress(0.0f, "querying");

  flModelList* list = nullptr;
  runtime.Check(runtime.catalog_api().GetModels(upstream_, &list), "list catalog models");
  UpstreamHandle<flModelList, decltype(flApi::ModelList_Release)> owned_list(list, runtime.api().ModelList_Release);

  const std::string task_filter = filter.value("task", "");
  const bool cached_only = filter.value("cached_only", false);
  const bool loaded_only = filter.value("loaded_only", false);
  const bool compatible_only = filter.value("compatible_only", false);
  const int64_t max_size_bytes = filter.value("max_size_bytes", static_cast<int64_t>(0));

  const DeviceProfile profile = GetDeviceProfile();
  const int64_t device_limit = compatible_only ? profile.MaxModelBytes() * 3 : 0;

  nlohmann::json models = nlohmann::json::array();
  const size_t count = runtime.api().ModelList_Size(owned_list.get());
  for (size_t i = 0; i < count; ++i) {
    context.ThrowIfCancelled();
    if (count > 0) {
      context.ReportProgress(static_cast<float>(i) / static_cast<float>(count) * 100.0f, "querying");
    }

    flModel* model = runtime.api().ModelList_GetAt(owned_list.get(), i);
    if (model == nullptr) {
      continue;
    }

    nlohmann::json info;
    try {
      info = SerializeModelInfo(runtime, model);
    } catch (const Error&) {
      continue;  // A single unreadable entry must not fail the whole listing.
    }

    if (!task_filter.empty() && info.value("task", "") != task_filter) {
      continue;
    }
    if (cached_only && !info.value("is_cached", false)) {
      continue;
    }
    if (loaded_only && !info.value("is_loaded", false)) {
      continue;
    }
    const int64_t size_bytes = info.value("file_size_bytes", static_cast<int64_t>(0));
    if (max_size_bytes > 0 && size_bytes > max_size_bytes) {
      continue;
    }
    if (device_limit > 0 && size_bytes > device_limit) {
      // Filtering here saves the app from listing models that would be OOM-killed the
      // moment a user taps them.
      continue;
    }

    models.push_back(std::move(info));
  }

  context.ReportProgress(100.0f, "querying");
  return nlohmann::json{{"models", std::move(models)}};
}

nlohmann::json Catalog::ListCachedModels() {
  manager_->ThrowIfShutdown();
  const Runtime& runtime = Runtime::Instance();

  flModelList* list = nullptr;
  runtime.Check(runtime.catalog_api().GetCachedModels(upstream_, &list), "list cached models");
  UpstreamHandle<flModelList, decltype(flApi::ModelList_Release)> owned_list(list, runtime.api().ModelList_Release);

  nlohmann::json models = nlohmann::json::array();
  const size_t count = runtime.api().ModelList_Size(owned_list.get());
  for (size_t i = 0; i < count; ++i) {
    if (flModel* model = runtime.api().ModelList_GetAt(owned_list.get(), i)) {
      try {
        models.push_back(SerializeModelInfo(runtime, model));
      } catch (const Error&) {
        continue;
      }
    }
  }
  return nlohmann::json{{"models", std::move(models)}};
}

std::shared_ptr<Model> Catalog::GetModel(const std::string& alias) {
  manager_->ThrowIfShutdown();
  if (alias.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "model alias must not be empty");
  }

  const Runtime& runtime = Runtime::Instance();
  flModel* upstream_model = nullptr;
  runtime.Check(runtime.catalog_api().GetModel(upstream_, alias.c_str(), &upstream_model), "get model '" + alias + "'");
  if (upstream_model == nullptr) {
    throw Error(FLM_ERROR_NOT_FOUND, "no model with alias '" + alias + "'", {{"alias", alias}});
  }
  // The catalog owns models it hands out, so we borrow rather than release.
  return std::make_shared<Model>(manager_, upstream_model, /*owns_upstream=*/false);
}

std::shared_ptr<Model> Catalog::GetModelById(const std::string& model_id) {
  manager_->ThrowIfShutdown();
  if (model_id.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "model id must not be empty");
  }

  const Runtime& runtime = Runtime::Instance();
  flModel* upstream_model = nullptr;
  runtime.Check(runtime.catalog_api().GetModelVariant(upstream_, model_id.c_str(), &upstream_model),
                "get model variant '" + model_id + "'");
  if (upstream_model == nullptr) {
    throw Error(FLM_ERROR_NOT_FOUND, "no model with id '" + model_id + "'", {{"model_id", model_id}});
  }
  return std::make_shared<Model>(manager_, upstream_model, /*owns_upstream=*/false);
}

int64_t Catalog::GetCacheSizeBytes() const {
  std::error_code ec;
  const fs::path cache_dir(manager_->model_cache_dir());
  if (!fs::exists(cache_dir, ec)) {
    return 0;
  }
  int64_t total = 0;
  for (fs::recursive_directory_iterator it(cache_dir, fs::directory_options::skip_permission_denied, ec), end;
       it != end && !ec; it.increment(ec)) {
    if (it->is_regular_file(ec)) {
      total += static_cast<int64_t>(it->file_size(ec));
    }
  }
  return total;
}

}  // namespace flm
