// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// ONNX Runtime model package support.
//
// A model package bundles several build variants of the same model — one per execution
// provider / device / compatibility string — behind a single manifest, plus
// content-addressed shared assets that variants reference by `sha256:<hex>` instead of
// duplicating.
//
// Two things make this the centrepiece of a *mobile* SDK:
//
//   1. Selective download. A phone must fetch one variant plus the shared assets that
//      variant references, never the whole package. The variants a device cannot run are
//      frequently larger than the one it can.
//   2. Cross-platform selection. One catalog alias yields a QNN/NPU build on a
//      Snapdragon phone, a CoreML build on iOS and a CPU build elsewhere. Apps get the
//      variant metadata so they can apply their own policy on top.
//
// The package spec deliberately does not record which variants consume which shared
// assets, so we maintain that mapping ourselves in Foundry-Local-owned metadata. Without
// it, deleting a variant would either orphan gigabytes or delete assets another variant
// still needs.

#ifndef FOUNDRY_LOCAL_MOBILE_MODEL_PACKAGE_H_
#define FOUNDRY_LOCAL_MOBILE_MODEL_PACKAGE_H_

#include <optional>
#include <string>
#include <vector>

#include "device_profile.h"
#include "third_party/json.h"

namespace flm {

/// One file within a variant or shared asset. Present only in manifests published for
/// remote download: selective download has to know exactly which files a variant needs
/// before fetching anything, and HTTPS offers no way to list a directory.
struct PackageFile {
  std::string relative_path;  ///< Relative to the package root.
  int64_t size = -1;
  std::string digest;  ///< "sha256:<hex>", optional.
};

/// One build variant of a package, plus everything needed to decide whether to download it.
struct ModelVariant {
  std::string id;                    ///< Unique within the package, e.g. "qwen2.5-0.5b.qnn-npu".
  std::string component;             ///< Component name; "model" for single-component packages.
  std::string execution_provider;    ///< "QNN", "CoreML", "XNNPACK", "CPU", ...
  flm_device device = FLM_DEVICE_CPU;
  std::string compatibility_string;  ///< EP-defined and opaque; scored by matching rules below.
  std::string platform;              ///< "android", "ios", or "any".
  std::string relative_path;         ///< Directory within the package.

  int64_t own_bytes = 0;                         ///< Files belonging only to this variant.
  std::vector<std::string> shared_asset_refs;    ///< "sha256:<hex>" references.
  std::vector<PackageFile> files;                ///< Empty unless the manifest lists them.

  bool is_cached = false;

  // Filled in by scoring.
  bool is_compatible = false;
  int compatibility_score = 0;
  std::string incompatibility_reason;

  nlohmann::json additional_metadata = nlohmann::json::object();

  /// The manifest entry this variant was parsed from, so a pruned manifest can be
  /// rewritten for the subset that was actually downloaded.
  nlohmann::json source_entry = nlohmann::json::object();
};

/// A content-addressed asset shared by one or more variants.
struct SharedAsset {
  std::string digest;      ///< "sha256:<hex>".
  std::string relative_path;
  int64_t bytes = 0;
  bool is_cached = false;
  std::string override_path;  ///< Manifest override pointing outside the package, if any.
  std::vector<PackageFile> files;  ///< Assets are directories; empty means a single file.

  nlohmann::json source_entry = nlohmann::json::object();
};

/// Constraints an app can impose on automatic variant selection.
struct VariantConstraints {
  std::optional<int64_t> max_download_bytes;
  std::vector<flm_device> allowed_devices;  ///< Empty = any device.
  bool prefer_smallest = false;             ///< Tie-break on size rather than score.
  bool require_cached = false;              ///< Only consider variants already on disk.

  static VariantConstraints FromJson(const nlohmann::json& json);
};

/// A parsed package manifest with device-aware scoring and download accounting.
class ModelPackage {
 public:
  /// Parse a manifest. Throws Error(FLM_ERROR_INVALID_ARGUMENT) on a malformed document.
  static ModelPackage FromManifest(const nlohmann::json& manifest, const std::string& package_id);

  /// Whether a directory is a package: it has a top-level manifest.json and *no*
  /// top-level genai_config.json. That negative condition is what distinguishes a
  /// package from a flat model whose directory happens to contain a manifest.
  static bool IsPackageDirectory(const std::string& directory);

  /// Load a package from an on-disk directory.
  static ModelPackage FromDirectory(const std::string& directory, const std::string& package_id);

  const std::string& id() const noexcept { return id_; }
  const std::string& schema_version() const noexcept { return schema_version_; }
  const std::vector<ModelVariant>& variants() const noexcept { return variants_; }
  const std::vector<SharedAsset>& shared_assets() const noexcept { return shared_assets_; }

  /// Score every variant against the device. Must be called before selection or
  /// serialization so `is_compatible` and `compatibility_score` are meaningful.
  void ScoreVariants(const DeviceProfile& profile);

  /// Best variant under the given constraints, or nullopt when none qualifies.
  std::optional<std::string> SelectBestVariant(const VariantConstraints& constraints) const;

  /// Pin the package to a variant. Throws Error(FLM_ERROR_NOT_FOUND) if unknown.
  void SelectVariant(const std::string& variant_id);

  const std::string& selected_variant_id() const noexcept { return selected_variant_id_; }
  const ModelVariant* FindVariant(const std::string& variant_id) const;

  /// Public lookup of a shared asset by "sha256:<hex>" reference.
  const SharedAsset* FindSharedAsset(const std::string& digest) const { return FindAsset(digest); }

  /// A manifest describing only `variant_id` and the shared assets it references. Written
  /// to disk after a selective download so the package directory does not advertise
  /// variants whose files were never fetched.
  nlohmann::json BuildPrunedManifest(const std::string& variant_id) const;

  /// Bytes to transfer for a set of variants: their own files plus the *union* of the
  /// shared assets they reference, minus whatever is already cached. Counting shared
  /// assets once is the whole point — a per-variant sum overestimates badly when two
  /// variants share multi-gigabyte weights.
  struct DownloadEstimate {
    int64_t download_bytes = 0;
    int64_t disk_bytes = 0;
    int64_t already_cached_bytes = 0;
    nlohmann::json ToJson(int64_t available_storage_bytes) const;
  };
  DownloadEstimate EstimateDownload(const std::vector<std::string>& variant_ids) const;

  /// Shared assets referenced by no variant in `remaining_variant_ids`. Deleting a
  /// variant removes its directory and then exactly these — no orphaned gigabytes, and
  /// nothing another variant still needs.
  std::vector<std::string> FindOrphanedAssets(const std::vector<std::string>& remaining_variant_ids) const;

  nlohmann::json ToJson() const;

 private:
  /// Score a variant's compatibility_string against an EP's. Returns nullopt when the
  /// variant cannot run at all (e.g. a v75 QNN binary on a v68 DSP).
  static std::optional<int> ScoreCompatibilityString(const std::string& variant_compat,
                                                     const ExecutionProviderInfo& ep);

  const SharedAsset* FindAsset(const std::string& digest) const;

  std::string id_;
  std::string schema_version_;
  std::vector<ModelVariant> variants_;
  std::vector<SharedAsset> shared_assets_;
  std::string selected_variant_id_;
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_MODEL_PACKAGE_H_
