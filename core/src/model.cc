// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "model.h"

#include <filesystem>

#include "catalog.h"

namespace flm {
namespace {

namespace fs = std::filesystem;

}  // namespace

Model::Model(std::shared_ptr<Manager> manager, flModel* upstream, bool owns_upstream)
    : manager_(std::move(manager)), upstream_(upstream), owns_upstream_(owns_upstream) {
  if (upstream_ == nullptr) {
    throw Error(FLM_ERROR_INTERNAL, "null model handle from the runtime");
  }
}

Model::~Model() {
  // Models obtained from the catalog are owned by it; only variant lists transfer
  // ownership, and releasing a borrowed model would corrupt the catalog's cache.
  if (owns_upstream_ && upstream_ != nullptr) {
    // No per-model release exists upstream; models live with their catalog. Kept
    // explicit so the ownership distinction is not silently lost.
    upstream_ = nullptr;
  }
}

nlohmann::json Model::GetInfo() const {
  const Runtime& runtime = Runtime::Instance();
  nlohmann::json info = SerializeModelInfo(runtime, upstream_);
  info["is_package"] = IsPackage();
  return info;
}

std::string Model::GetId() const {
  const Runtime& runtime = Runtime::Instance();
  const flModelInfo* info = nullptr;
  runtime.Check(runtime.model_api().GetInfo(upstream_, &info), "get model info");
  const char* id = runtime.model_api().Info_GetId(info);
  return id != nullptr ? std::string(id) : std::string();
}

std::string Model::GetPath() const {
  const Runtime& runtime = Runtime::Instance();
  const char* path = nullptr;
  runtime.Check(runtime.model_api().GetPath(upstream_, &path), "get model path");
  return path != nullptr ? std::string(path) : std::string();
}

bool Model::IsCached() const {
  const Runtime& runtime = Runtime::Instance();
  int cached = 0;
  runtime.Check(runtime.model_api().IsCached(upstream_, &cached), "query cache state");
  return cached != 0;
}

bool Model::IsLoaded() const {
  const Runtime& runtime = Runtime::Instance();
  int loaded = 0;
  runtime.Check(runtime.model_api().IsLoaded(upstream_, &loaded), "query load state");
  return loaded != 0;
}

nlohmann::json Model::Download(const nlohmann::json& options, JobContext& context) {
  manager_->ThrowIfShutdown();

  const nlohmann::json info = GetInfo();
  int64_t expected_bytes = info.value("file_size_bytes", static_cast<int64_t>(0));

  // For a package, only the selected variant and its shared assets are fetched, so the
  // estimate must come from the package rather than the catalog's whole-entry size.
  if (IsPackage()) {
    const nlohmann::json estimate = EstimateDownload(std::nullopt);
    expected_bytes = estimate.value("download_bytes", expected_bytes);

    if (!estimate.value("fits_on_device", true)) {
      throw Error(FLM_ERROR_STORAGE, "not enough free storage for this model",
                  {{"required_bytes", expected_bytes},
                   {"available_bytes", estimate.value("available_storage_bytes", 0)}});
    }
  }

  // Respect the metered-network policy unless the caller explicitly overrides it. This
  // is the check that stops an app from silently burning a user's data plan.
  const bool allow_metered = options.value("allow_metered", manager_->settings().download_on_metered_network);
  const DeviceProfile profile = GetDeviceProfile();
  if (!allow_metered && !profile.CanDownloadSilently(expected_bytes)) {
    if (profile.network == NetworkState::kNone) {
      throw Error(FLM_ERROR_NETWORK, "no network connection is available for this download");
    }
    throw Error(FLM_ERROR_NETWORK,
                "this download requires a large transfer on a metered connection. Pass "
                "{\"allow_metered\": true} to proceed.",
                {{"download_bytes", expected_bytes}, {"network", ToString(profile.network)}});
  }

  context.ReportProgress(0.0f, "downloading", 0, expected_bytes);

  // Deliberately not Foundry Local's downloader. That one resolves the model through the
  // Azure catalog and fetches the desktop build published there — CUDA, DirectML,
  // OpenVINO, x64. On a phone those are gigabytes that cannot execute. Mobile models come
  // from the app instead, through flm_manager_add_model_source_async, which downloads
  // through this SDK's own downloader and picks the variant this device can actually run.
  throw Error(FLM_ERROR_NOT_IMPLEMENTED,
              "this model is not present on the device and cannot be fetched from the Foundry Local "
              "catalog, which publishes desktop builds. Supply the model with "
              "flm_manager_add_model_source_async(), either bundled in the app or from a URL you host.",
              {{"model", GetInfo().value("id", std::string())}, {"expected_bytes", expected_bytes}});
}

nlohmann::json Model::Load(const nlohmann::json& options, JobContext& context) {
  manager_->ThrowIfShutdown();
  const Runtime& runtime = Runtime::Instance();

  if (!IsCached()) {
    // Loading implies downloading; splitting them would make every caller write the
    // same two-step dance.
    context.ReportProgress(0.0f, "downloading");
    Download(options, context);
  }

  context.ThrowIfCancelled();
  context.ReportProgress(0.0f, "loading");

  // Reject a load that the OS would kill. Failing here with a clear error is much better
  // than an opaque process death a few seconds later.
  const DeviceProfile profile = GetDeviceProfile();
  const int64_t model_bytes = GetInfo().value("file_size_bytes", static_cast<int64_t>(0));
  const int64_t budget = profile.MaxModelBytes();
  if (model_bytes > 0 && budget > 0 && model_bytes > budget) {
    throw Error(FLM_ERROR_MEMORY_PRESSURE,
                "not enough available memory to load this model",
                {{"model_bytes", model_bytes},
                 {"available_budget_bytes", budget},
                 {"available_memory_bytes", profile.available_memory_bytes}});
  }

  runtime.Check(runtime.model_api().Load(upstream_), "load model");
  context.ReportProgress(100.0f, "loading");

  return nlohmann::json{{"path", GetPath()}, {"bytes", model_bytes}};
}

void Model::Unload() {
  const Runtime& runtime = Runtime::Instance();
  runtime.Check(runtime.model_api().Unload(upstream_), "unload model");
}

void Model::Delete() {
  const Runtime& runtime = Runtime::Instance();
  if (IsLoaded()) {
    Unload();
  }

  // Clean up orphaned shared assets before removing the model, while the package
  // manifest is still readable. The package spec does not track which variants use which
  // assets, so this mapping is ours to maintain.
  if (IsPackage()) {
    try {
      const ModelPackage& package = GetPackage();
      const std::string path = GetPath();
      const auto orphans = package.FindOrphanedAssets({});
      for (const auto& digest : orphans) {
        std::error_code ec;
        fs::remove_all(fs::path(path) / "shared_assets" / digest, ec);
      }
    } catch (const Error&) {
      // Best effort: a manifest we cannot parse must not block deleting the model.
    }
  }

  runtime.Check(runtime.model_api().RemoveFromCache(upstream_), "remove model from cache");

  std::lock_guard<std::mutex> lock(mutex_);
  package_checked_ = false;
  package_.reset();
}

/* ------------------------------------------------------------------------- */
/* Model packages                                                             */
/* ------------------------------------------------------------------------- */

void Model::EnsurePackageLoaded() const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (package_checked_) {
    return;
  }
  package_checked_ = true;

  const Runtime& runtime = Runtime::Instance();

  // A downloaded package is authoritative: parse the real manifest.
  const char* path = nullptr;
  if (runtime.CheckNoThrow(runtime.model_api().GetPath(upstream_, &path)) == FLM_OK && path != nullptr &&
      path[0] != '\0' && ModelPackage::IsPackageDirectory(path)) {
    try {
      const flModelInfo* info = nullptr;
      std::string package_id;
      if (runtime.CheckNoThrow(runtime.model_api().GetInfo(upstream_, &info)) == FLM_OK && info != nullptr) {
        if (const char* alias = runtime.model_api().Info_GetAlias(info)) {
          package_id = alias;
        }
      }
      ModelPackage package = ModelPackage::FromDirectory(path, package_id);
      package.ScoreVariants(GetDeviceProfile());
      package_ = std::move(package);
      return;
    } catch (const Error&) {
      // Fall through to the catalog view rather than failing outright — a malformed
      // on-disk manifest should not make the model unusable.
    }
  }

  // Not downloaded yet, or not a true ORT package. Present the catalog's device-optimized
  // variants through the same interface so app code has one selection API.
  package_ = BuildPackageFromUpstreamVariants();
}

std::optional<ModelPackage> Model::BuildPackageFromUpstreamVariants() const {
  const Runtime& runtime = Runtime::Instance();

  flModelList* variants = nullptr;
  if (runtime.CheckNoThrow(runtime.model_api().GetVariants(upstream_, &variants)) != FLM_OK || variants == nullptr) {
    return std::nullopt;
  }
  UpstreamHandle<flModelList, decltype(flApi::ModelList_Release)> owned_variants(variants,
                                                                                runtime.api().ModelList_Release);

  const size_t count = runtime.api().ModelList_Size(owned_variants.get());
  if (count <= 1) {
    return std::nullopt;  // A leaf model reports itself as its only variant.
  }

  const flModelInfo* self_info = nullptr;
  std::string package_id;
  if (runtime.CheckNoThrow(runtime.model_api().GetInfo(upstream_, &self_info)) == FLM_OK && self_info != nullptr) {
    if (const char* alias = runtime.model_api().Info_GetAlias(self_info)) {
      package_id = alias;
    }
  }

  nlohmann::json manifest;
  manifest["schema_version"] = "1.0";
  nlohmann::json variant_entries = nlohmann::json::array();

  for (size_t i = 0; i < count; ++i) {
    flModel* variant = runtime.api().ModelList_GetAt(owned_variants.get(), i);
    if (variant == nullptr) {
      continue;
    }
    const flModelInfo* info = nullptr;
    if (runtime.CheckNoThrow(runtime.model_api().GetInfo(variant, &info)) != FLM_OK || info == nullptr) {
      continue;
    }

    const char* id = runtime.model_api().Info_GetId(info);
    const char* ep = runtime.model_api().Info_GetExecutionProvider(info);
    const int64_t filesize_mb =
        runtime.model_api().Info_GetIntProperty(info, FOUNDRY_LOCAL_MODEL_PROP_FILESIZE_MB_INT, 0);

    nlohmann::json entry;
    entry["id"] = id != nullptr ? id : (package_id + "." + std::to_string(i));
    entry["ep"] = ep != nullptr ? ep : "CPU";
    entry["device"] = ToString(static_cast<flm_device>(runtime.model_api().Info_GetDeviceType(info)));
    entry["size"] = filesize_mb * 1024 * 1024;
    entry["platform"] = "any";
    variant_entries.push_back(std::move(entry));
  }

  if (variant_entries.empty()) {
    return std::nullopt;
  }

  manifest["components"] = nlohmann::json::array({nlohmann::json{{"name", "model"}, {"variants", variant_entries}}});

  try {
    ModelPackage package = ModelPackage::FromManifest(manifest, package_id);
    package.ScoreVariants(GetDeviceProfile());
    return package;
  } catch (const Error&) {
    return std::nullopt;
  }
}

bool Model::IsPackage() const {
  EnsurePackageLoaded();
  std::lock_guard<std::mutex> lock(mutex_);
  return package_.has_value();
}

const ModelPackage& Model::GetPackage() const {
  EnsurePackageLoaded();
  std::lock_guard<std::mutex> lock(mutex_);
  if (!package_) {
    throw Error(FLM_ERROR_INVALID_STATE, "this model is not a model package and has no variants");
  }
  return *package_;
}

void Model::SelectVariant(const std::string& variant_id) {
  EnsurePackageLoaded();

  std::string resolved_id;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!package_) {
      throw Error(FLM_ERROR_INVALID_STATE, "this model is not a model package and has no variants");
    }
    package_->SelectVariant(variant_id);
    resolved_id = variant_id;
  }

  // Mirror the choice into the runtime so load and inference use the variant we just
  // reported to the app; otherwise the SDK's view and the runtime's would drift.
  //
  // This only applies to catalog-level variants. For on-disk package variants the
  // runtime selects from the manifest at load time, so a lookup miss is expected and
  // must not be treated as an error.
  const Runtime& runtime = Runtime::Instance();
  flModel* upstream_variant = nullptr;
  auto catalog = manager_->catalog();
  if (runtime.CheckNoThrow(runtime.catalog_api().GetModelVariant(catalog->upstream(), resolved_id.c_str(),
                                                                 &upstream_variant)) != FLM_OK ||
      upstream_variant == nullptr) {
    return;
  }
  runtime.CheckNoThrow(runtime.model_api().SelectVariant(upstream_, upstream_variant));
}

std::string Model::SelectBestVariant(const nlohmann::json& constraints) {
  EnsurePackageLoaded();

  std::lock_guard<std::mutex> lock(mutex_);
  if (!package_) {
    throw Error(FLM_ERROR_INVALID_STATE, "this model is not a model package and has no variants");
  }

  const auto selected = package_->SelectBestVariant(VariantConstraints::FromJson(constraints));
  if (!selected) {
    nlohmann::json reasons = nlohmann::json::object();
    for (const auto& variant : package_->variants()) {
      if (!variant.is_compatible) {
        reasons[variant.id] = variant.incompatibility_reason;
      }
    }
    throw Error(FLM_ERROR_INCOMPATIBLE, "no model package variant satisfies the constraints on this device",
                {{"variant_reasons", reasons}});
  }
  package_->SelectVariant(*selected);
  return *selected;
}

std::shared_ptr<Model> Model::GetVariantModel(const std::string& variant_id) {
  EnsurePackageLoaded();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!package_ || package_->FindVariant(variant_id) == nullptr) {
      throw Error(FLM_ERROR_NOT_FOUND, "no variant '" + variant_id + "' in this model");
    }
  }

  const Runtime& runtime = Runtime::Instance();
  auto catalog = manager_->catalog();
  flModel* upstream_variant = nullptr;
  runtime.Check(runtime.catalog_api().GetModelVariant(catalog->upstream(), variant_id.c_str(), &upstream_variant),
                "get variant '" + variant_id + "'");
  if (upstream_variant == nullptr) {
    throw Error(FLM_ERROR_NOT_FOUND, "no variant '" + variant_id + "' in the catalog");
  }
  return std::make_shared<Model>(manager_, upstream_variant, /*owns_upstream=*/false);
}

nlohmann::json Model::EstimateDownload(const std::optional<std::vector<std::string>>& variant_ids) const {
  EnsurePackageLoaded();

  std::lock_guard<std::mutex> lock(mutex_);
  if (!package_) {
    // A flat model: the estimate is simply its size, or zero when already cached.
    const Runtime& runtime = Runtime::Instance();
    const flModelInfo* info = nullptr;
    int64_t bytes = 0;
    if (runtime.CheckNoThrow(runtime.model_api().GetInfo(upstream_, &info)) == FLM_OK && info != nullptr) {
      bytes = runtime.model_api().Info_GetIntProperty(info, FOUNDRY_LOCAL_MODEL_PROP_FILESIZE_MB_INT, 0) * 1024 * 1024;
    }
    int cached = 0;
    runtime.CheckNoThrow(runtime.model_api().IsCached(upstream_, &cached));
    const DeviceProfile profile = GetDeviceProfile();
    ModelPackage::DownloadEstimate estimate;
    estimate.disk_bytes = bytes;
    estimate.download_bytes = cached != 0 ? 0 : bytes;
    estimate.already_cached_bytes = cached != 0 ? bytes : 0;
    return estimate.ToJson(profile.available_storage_bytes);
  }

  std::vector<std::string> ids;
  if (variant_ids && !variant_ids->empty()) {
    ids = *variant_ids;
  } else if (!package_->selected_variant_id().empty()) {
    ids.push_back(package_->selected_variant_id());
  } else {
    // Nothing pinned yet: estimate for what automatic selection would choose, which is
    // what the user is about to be asked to approve.
    if (auto best = package_->SelectBestVariant(VariantConstraints{})) {
      ids.push_back(*best);
    }
  }

  const ModelPackage::DownloadEstimate estimate = package_->EstimateDownload(ids);
  return estimate.ToJson(GetDeviceProfile().available_storage_bytes);
}

}  // namespace flm
