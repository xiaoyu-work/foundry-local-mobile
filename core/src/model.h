// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#ifndef FOUNDRY_LOCAL_MOBILE_MODEL_H_
#define FOUNDRY_LOCAL_MOBILE_MODEL_H_

#include <memory>
#include <mutex>
#include <optional>
#include <string>

#include "job.h"
#include "manager.h"
#include "model_package.h"
#include "runtime.h"
#include "third_party/json.h"

namespace flm {

/// A catalog model, a model package, or one variant of a package.
///
/// The three cases share an interface deliberately: app code that does not care about
/// packages treats every model the same way, while code that does care calls the
/// package-specific accessors. `is_package()` distinguishes them.
class Model {
 public:
  Model(std::shared_ptr<Manager> manager, flModel* upstream, bool owns_upstream);
  ~Model();

  Model(const Model&) = delete;
  Model& operator=(const Model&) = delete;

  nlohmann::json GetInfo() const;
  std::string GetId() const;
  std::string GetPath() const;
  bool IsCached() const;
  bool IsLoaded() const;

  nlohmann::json Download(const nlohmann::json& options, JobContext& context);
  nlohmann::json Load(const nlohmann::json& options, JobContext& context);
  void Unload();
  void Delete();

  /* --- Model package support --- */

  /// Whether this model is a package. Determined from catalog metadata when available,
  /// and from the on-disk layout once downloaded.
  bool IsPackage() const;

  /// The parsed package, scored against the current device. Throws
  /// Error(FLM_ERROR_INVALID_STATE) when this model is not a package.
  const ModelPackage& GetPackage() const;

  void SelectVariant(const std::string& variant_id);
  std::string SelectBestVariant(const nlohmann::json& constraints);
  std::shared_ptr<Model> GetVariantModel(const std::string& variant_id);
  nlohmann::json EstimateDownload(const std::optional<std::vector<std::string>>& variant_ids) const;

  flModel* upstream() const noexcept { return upstream_; }
  const std::shared_ptr<Manager>& manager() const noexcept { return manager_; }

 private:
  /// Parse the package manifest on first use. Package metadata may come from the catalog
  /// before download and from disk afterwards, so this is re-evaluated when the cache
  /// state changes.
  void EnsurePackageLoaded() const;

  /// Upstream variants (device-optimized builds exposed by the catalog) are surfaced as
  /// package variants when the model is not a true ORT model package, so callers get one
  /// consistent selection API either way.
  std::optional<ModelPackage> BuildPackageFromUpstreamVariants() const;

  std::shared_ptr<Manager> manager_;
  flModel* upstream_ = nullptr;
  bool owns_upstream_ = false;

  mutable std::mutex mutex_;
  mutable std::optional<ModelPackage> package_;
  mutable bool package_checked_ = false;
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_MODEL_H_
