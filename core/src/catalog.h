// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#ifndef FOUNDRY_LOCAL_MOBILE_CATALOG_H_
#define FOUNDRY_LOCAL_MOBILE_CATALOG_H_

#include <memory>
#include <string>

#include "manager.h"
#include "runtime.h"
#include "third_party/json.h"

namespace flm {

class Model;

/// Serialize an upstream model into the JSON shape documented on
/// `flm_catalog_list_models`. Shared with the model layer so the schema is defined once.
nlohmann::json SerializeModelInfo(const Runtime& runtime, flModel* model);

/// The model catalog. Borrowed from the manager, which owns the upstream handle.
class Catalog {
 public:
  Catalog(std::shared_ptr<Manager> manager, flCatalog* upstream);

  /// All catalog models matching `filter`, as a JSON array of model summaries.
  nlohmann::json ListModels(const nlohmann::json& filter, JobContext& context);

  /// Models present on disk. Reads the cache directly, so it works offline.
  nlohmann::json ListCachedModels();

  std::shared_ptr<Model> GetModel(const std::string& alias);
  std::shared_ptr<Model> GetModelById(const std::string& model_id);

  int64_t GetCacheSizeBytes() const;

  const std::shared_ptr<Manager>& manager() const noexcept { return manager_; }
  flCatalog* upstream() const noexcept { return upstream_; }

 private:
  std::shared_ptr<Manager> manager_;
  flCatalog* upstream_ = nullptr;
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_CATALOG_H_
