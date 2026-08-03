// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "model_package.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>

#include "error.h"

namespace flm {
namespace {

namespace fs = std::filesystem;

/// Parse a compatibility string of the form "key=value;key=value" into a map.
/// The format is EP-defined and opaque to the spec, but every EP in practice uses this
/// shape, and treating it as key/value lets us give a much better answer than an
/// all-or-nothing string comparison.
std::map<std::string, std::string> ParseCompatibilityString(const std::string& value) {
  std::map<std::string, std::string> result;
  size_t start = 0;
  while (start < value.size()) {
    size_t end = value.find(';', start);
    if (end == std::string::npos) {
      end = value.size();
    }
    const std::string pair = value.substr(start, end - start);
    const size_t equals = pair.find('=');
    if (equals != std::string::npos) {
      std::string key = pair.substr(0, equals);
      std::string val = pair.substr(equals + 1);
      // Tolerate incidental whitespace; manifests are authored by many tools.
      key.erase(0, key.find_first_not_of(" \t"));
      key.erase(key.find_last_not_of(" \t") + 1);
      val.erase(0, val.find_first_not_of(" \t"));
      val.erase(val.find_last_not_of(" \t") + 1);
      if (!key.empty()) {
        result.emplace(std::move(key), std::move(val));
      }
    }
    start = end + 1;
  }
  return result;
}

/// Compare architecture-version strings like "v75" numerically rather than
/// lexicographically, so "v8" does not sort above "v75".
std::optional<int> ParseArchVersion(const std::string& value) {
  if (value.size() < 2 || (value[0] != 'v' && value[0] != 'V')) {
    return std::nullopt;
  }
  try {
    return std::stoi(value.substr(1));
  } catch (...) {
    return std::nullopt;
  }
}

int64_t DirectorySizeBytes(const fs::path& path) {
  std::error_code ec;
  if (!fs::exists(path, ec)) {
    return 0;
  }
  int64_t total = 0;
  for (fs::recursive_directory_iterator it(path, fs::directory_options::skip_permission_denied, ec), end;
       it != end && !ec; it.increment(ec)) {
    if (it->is_regular_file(ec)) {
      total += static_cast<int64_t>(it->file_size(ec));
    }
  }
  return total;
}

/// The digest part of a "sha256:<hex>[/sub/path]" reference. Variants embed sub-paths
/// into asset references; the directory is addressed by the digest alone.
std::string NormalizeAssetRef(const std::string& reference) {
  const size_t slash = reference.find('/');
  return slash == std::string::npos ? reference : reference.substr(0, slash);
}

/// Read an optional "files" array. Only manifests published for remote download carry
/// one; a package read from disk has the real filesystem to enumerate instead.
std::vector<PackageFile> ParsePackageFiles(const nlohmann::json& owner) {
  std::vector<PackageFile> files;
  const auto entry = owner.find("files");
  if (entry == owner.end() || !entry->is_array()) {
    return files;
  }

  for (const auto& item : *entry) {
    PackageFile file;
    if (item.is_string()) {
      file.relative_path = item.get<std::string>();
    } else if (item.is_object()) {
      file.relative_path = item.value("path", "");
      file.size = item.value("size", static_cast<int64_t>(-1));
      file.digest = item.value("digest", item.value("sha256", ""));
    }
    if (!file.relative_path.empty()) {
      files.push_back(std::move(file));
    }
  }
  return files;
}

}  // namespace

VariantConstraints VariantConstraints::FromJson(const nlohmann::json& json) {
  VariantConstraints constraints;
  if (!json.is_object()) {
    return constraints;
  }
  if (auto it = json.find("max_download_bytes"); it != json.end() && it->is_number()) {
    constraints.max_download_bytes = it->get<int64_t>();
  }
  if (auto it = json.find("allowed_devices"); it != json.end() && it->is_array()) {
    for (const auto& entry : *it) {
      if (entry.is_string()) {
        constraints.allowed_devices.push_back(DeviceFromString(entry.get<std::string>()));
      }
    }
  }
  if (auto it = json.find("prefer_smallest"); it != json.end() && it->is_boolean()) {
    constraints.prefer_smallest = it->get<bool>();
  }
  if (auto it = json.find("require_cached"); it != json.end() && it->is_boolean()) {
    constraints.require_cached = it->get<bool>();
  }
  return constraints;
}

/* ------------------------------------------------------------------------- */
/* Parsing                                                                    */
/* ------------------------------------------------------------------------- */

ModelPackage ModelPackage::FromManifest(const nlohmann::json& manifest, const std::string& package_id) {
  if (!manifest.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "model package manifest is not a JSON object");
  }

  ModelPackage package;
  package.id_ = package_id;
  package.schema_version_ = manifest.value("schema_version", manifest.value("version", "1.0"));

  // Shared assets: a map of "sha256:<hex>" to a descriptor. The manifest may override
  // an asset's location to point outside the package, which is what lets a future shared
  // cache work without hard links.
  if (auto assets = manifest.find("shared_assets"); assets != manifest.end() && assets->is_object()) {
    for (const auto& [digest, descriptor] : assets->items()) {
      SharedAsset asset;
      asset.digest = digest;
      if (descriptor.is_string()) {
        asset.relative_path = descriptor.get<std::string>();
      } else if (descriptor.is_object()) {
        asset.relative_path = descriptor.value("path", "shared_assets/" + digest);
        asset.bytes = descriptor.value("size", static_cast<int64_t>(0));
        asset.override_path = descriptor.value("override_path", "");
        asset.files = ParsePackageFiles(descriptor);
        asset.source_entry = descriptor;
      }
      if (asset.relative_path.empty()) {
        asset.relative_path = "shared_assets/" + digest;
      }
      package.shared_assets_.push_back(std::move(asset));
    }
  }

  // Components each hold one or more variants. Stage 1 supports single-component
  // packages; additional components parse but are not loadable, so they are kept in the
  // model rather than dropped, and reported through the variant's `component` field.
  const auto components = manifest.find("components");
  if (components == manifest.end() || !components->is_array() || components->empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "model package manifest has no components");
  }

  for (const auto& component : *components) {
    const std::string component_name = component.value("name", "model");
    const auto variants = component.find("variants");
    if (variants == component.end() || !variants->is_array()) {
      continue;
    }

    for (const auto& entry : *variants) {
      ModelVariant variant;
      variant.component = component_name;
      variant.relative_path = entry.value("path", "");
      variant.id = entry.value("id", "");
      if (variant.id.empty()) {
        // Manifests do not always carry ids; derive a stable one so apps have something
        // to pass back to SelectVariant.
        variant.id = package_id + "." + (variant.relative_path.empty() ? component_name : variant.relative_path);
      }
      variant.execution_provider = entry.value("ep", entry.value("execution_provider", "CPU"));
      variant.device = DeviceFromString(entry.value("device", "cpu"));
      variant.compatibility_string = entry.value("compatibility_string", "");
      variant.platform = entry.value("platform", "any");
      variant.own_bytes = entry.value("size", static_cast<int64_t>(0));
      variant.files = ParsePackageFiles(entry);
      variant.source_entry = entry;

      // A manifest published for remote download lists each variant's files so the
      // downloader knows what to fetch. When sizes are given but the variant's total is
      // not, derive it — the estimate drives the storage check before anything is pulled.
      if (variant.own_bytes == 0 && !variant.files.empty()) {
        int64_t sum = 0;
        bool complete = true;
        for (const PackageFile& file : variant.files) {
          if (file.size < 0) {
            complete = false;
            break;
          }
          sum += file.size;
        }
        if (complete) {
          variant.own_bytes = sum;
        }
      }

      if (auto refs = entry.find("shared_asset_refs"); refs != entry.end() && refs->is_array()) {
        for (const auto& reference : *refs) {
          if (reference.is_string()) {
            variant.shared_asset_refs.push_back(NormalizeAssetRef(reference.get<std::string>()));
          }
        }
      }

      // Foundry-Local-owned bookkeeping. The spec has no manifest-level "variant X uses
      // asset Y" list, so we record ours in additional_metadata and read it back here.
      if (auto metadata = entry.find("additional_metadata"); metadata != entry.end() && metadata->is_object()) {
        variant.additional_metadata = *metadata;
        if (auto fl_assets = metadata->find("foundry_local_shared_assets");
            fl_assets != metadata->end() && fl_assets->is_array()) {
          for (const auto& reference : *fl_assets) {
            if (reference.is_string()) {
              const std::string digest = NormalizeAssetRef(reference.get<std::string>());
              if (std::find(variant.shared_asset_refs.begin(), variant.shared_asset_refs.end(), digest) ==
                  variant.shared_asset_refs.end()) {
                variant.shared_asset_refs.push_back(digest);
              }
            }
          }
        }
      }

      package.variants_.push_back(std::move(variant));
    }
  }

  if (package.variants_.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "model package manifest declares no variants");
  }
  return package;
}

bool ModelPackage::IsPackageDirectory(const std::string& directory) {
  std::error_code ec;
  const fs::path path(directory);
  // Both conditions matter: a flat model directory can contain a manifest.json, and it
  // is the *absence* of a top-level genai_config.json that marks a package.
  return fs::exists(path / "manifest.json", ec) && !fs::exists(path / "genai_config.json", ec);
}

ModelPackage ModelPackage::FromDirectory(const std::string& directory, const std::string& package_id) {
  const fs::path manifest_path = fs::path(directory) / "manifest.json";
  std::ifstream stream(manifest_path);
  if (!stream) {
    throw Error(FLM_ERROR_NOT_FOUND, "model package manifest not found", {{"path", manifest_path.string()}});
  }

  nlohmann::json manifest;
  stream >> manifest;
  ModelPackage package = FromManifest(manifest, package_id);

  // Fill in on-disk state so download estimates reflect reality rather than the manifest.
  const fs::path root(directory);
  for (auto& variant : package.variants_) {
    const fs::path variant_path = root / variant.relative_path;
    std::error_code ec;
    variant.is_cached = fs::exists(variant_path, ec) && fs::exists(variant_path / "genai_config.json", ec);
    if (variant.own_bytes == 0 && variant.is_cached) {
      variant.own_bytes = DirectorySizeBytes(variant_path);
    }
  }
  for (auto& asset : package.shared_assets_) {
    const fs::path asset_path = asset.override_path.empty() ? root / asset.relative_path : fs::path(asset.override_path);
    std::error_code ec;
    asset.is_cached = fs::exists(asset_path, ec);
    if (asset.bytes == 0 && asset.is_cached) {
      asset.bytes = DirectorySizeBytes(asset_path);
    }
  }
  return package;
}

/* ------------------------------------------------------------------------- */
/* Scoring                                                                    */
/* ------------------------------------------------------------------------- */

std::optional<int> ModelPackage::ScoreCompatibilityString(const std::string& variant_compat,
                                                          const ExecutionProviderInfo& ep) {
  // An empty variant compatibility string means "runs anywhere this EP runs" — the
  // normal case for CPU variants.
  if (variant_compat.empty()) {
    return 0;
  }

  const auto required = ParseCompatibilityString(variant_compat);
  const auto available = ParseCompatibilityString(ep.compatibility_string);

  int score = 0;
  for (const auto& [key, required_value] : required) {
    auto it = available.find(key);
    if (it == available.end()) {
      // Fall back to the EP's structured attributes before giving up: platform detection
      // records dsp_arch and soc there even when it has no compatibility string.
      if (ep.attributes.contains(key) && ep.attributes[key].is_string()) {
        const std::string attribute_value = ep.attributes[key].get<std::string>();
        if (attribute_value == required_value) {
          score += 10;
          continue;
        }
        const auto required_version = ParseArchVersion(required_value);
        const auto device_version = ParseArchVersion(attribute_value);
        if (required_version && device_version) {
          // A binary compiled for a newer architecture cannot run on older hardware.
          if (*required_version > *device_version) {
            return std::nullopt;
          }
          // Older binaries run, but the closer the match the better the performance.
          score += 10 - std::min(9, *device_version - *required_version);
          continue;
        }
        return std::nullopt;
      }
      // The device knows nothing about this key. Treat it as unusable rather than
      // optimistically loading a binary that may crash the NPU driver.
      return std::nullopt;
    }

    if (it->second == required_value) {
      score += 10;
      continue;
    }
    const auto required_version = ParseArchVersion(required_value);
    const auto device_version = ParseArchVersion(it->second);
    if (required_version && device_version) {
      if (*required_version > *device_version) {
        return std::nullopt;
      }
      score += 10 - std::min(9, *device_version - *required_version);
      continue;
    }
    return std::nullopt;
  }
  return score;
}

void ModelPackage::ScoreVariants(const DeviceProfile& profile) {
  const int64_t max_model_bytes = profile.MaxModelBytes();

  for (auto& variant : variants_) {
    variant.is_compatible = false;
    variant.compatibility_score = 0;
    variant.incompatibility_reason.clear();

    if (variant.platform != "any" && !variant.platform.empty() && variant.platform != profile.platform) {
      variant.incompatibility_reason = "built for " + variant.platform;
      continue;
    }

    auto ep = std::find_if(profile.execution_providers.begin(), profile.execution_providers.end(),
                           [&variant](const ExecutionProviderInfo& candidate) {
                             return candidate.name == variant.execution_provider && candidate.available;
                           });
    if (ep == profile.execution_providers.end()) {
      variant.incompatibility_reason = "execution provider " + variant.execution_provider + " is not available";
      continue;
    }

    if (variant.device != ep->device && variant.device != FLM_DEVICE_UNKNOWN) {
      variant.incompatibility_reason = std::string("requires a ") + ToString(variant.device) + " device";
      continue;
    }

    const auto compat_score = ScoreCompatibilityString(variant.compatibility_string, *ep);
    if (!compat_score) {
      variant.incompatibility_reason = "hardware does not satisfy '" + variant.compatibility_string + "'";
      continue;
    }

    // A variant that would be killed on load is not compatible, however well it matches
    // on paper. This is the check that keeps a phone from OOM-ing on a model built for a
    // workstation.
    const DownloadEstimate estimate = EstimateDownload({variant.id});
    if (max_model_bytes > 0 && estimate.disk_bytes > max_model_bytes * 3) {
      variant.incompatibility_reason = "model is too large for the available memory";
      continue;
    }

    variant.is_compatible = true;
    // EP priority dominates (0 for an NPU, 30 for CPU), so placement quality outranks a
    // marginally better compatibility-string match on a slower device.
    variant.compatibility_score = 100 - ep->priority + *compat_score;
  }
}

std::optional<std::string> ModelPackage::SelectBestVariant(const VariantConstraints& constraints) const {
  const ModelVariant* best = nullptr;
  int64_t best_bytes = 0;

  for (const auto& variant : variants_) {
    if (!variant.is_compatible) {
      continue;
    }
    if (constraints.require_cached && !variant.is_cached) {
      continue;
    }
    if (!constraints.allowed_devices.empty() &&
        std::find(constraints.allowed_devices.begin(), constraints.allowed_devices.end(), variant.device) ==
            constraints.allowed_devices.end()) {
      continue;
    }

    const int64_t download_bytes = EstimateDownload({variant.id}).download_bytes;
    if (constraints.max_download_bytes && download_bytes > *constraints.max_download_bytes) {
      continue;
    }

    if (best == nullptr) {
      best = &variant;
      best_bytes = download_bytes;
      continue;
    }

    if (constraints.prefer_smallest) {
      if (download_bytes < best_bytes ||
          (download_bytes == best_bytes && variant.compatibility_score > best->compatibility_score)) {
        best = &variant;
        best_bytes = download_bytes;
      }
    } else if (variant.compatibility_score > best->compatibility_score ||
               (variant.compatibility_score == best->compatibility_score && download_bytes < best_bytes)) {
      // Equal scores are broken by size: a cached or smaller variant gets the user to a
      // working app sooner.
      best = &variant;
      best_bytes = download_bytes;
    }
  }

  if (best == nullptr) {
    return std::nullopt;
  }
  return best->id;
}

void ModelPackage::SelectVariant(const std::string& variant_id) {
  const ModelVariant* variant = FindVariant(variant_id);
  if (variant == nullptr) {
    nlohmann::json available = nlohmann::json::array();
    for (const auto& candidate : variants_) {
      available.push_back(candidate.id);
    }
    throw Error(FLM_ERROR_NOT_FOUND, "no variant '" + variant_id + "' in package '" + id_ + "'",
                {{"available_variants", available}});
  }
  selected_variant_id_ = variant_id;
}

const ModelVariant* ModelPackage::FindVariant(const std::string& variant_id) const {
  auto it = std::find_if(variants_.begin(), variants_.end(),
                         [&variant_id](const ModelVariant& variant) { return variant.id == variant_id; });
  return it == variants_.end() ? nullptr : &*it;
}

const SharedAsset* ModelPackage::FindAsset(const std::string& digest) const {
  auto it = std::find_if(shared_assets_.begin(), shared_assets_.end(),
                         [&digest](const SharedAsset& asset) { return asset.digest == digest; });
  return it == shared_assets_.end() ? nullptr : &*it;
}

nlohmann::json ModelPackage::BuildPrunedManifest(const std::string& variant_id) const {
  const ModelVariant* variant = FindVariant(variant_id);
  if (variant == nullptr) {
    throw Error(FLM_ERROR_NOT_FOUND, "unknown variant '" + variant_id + "'", {{"variant_id", variant_id}});
  }

  nlohmann::json manifest;
  manifest["schema_version"] = schema_version_;

  nlohmann::json entry = variant->source_entry.is_object() ? variant->source_entry : nlohmann::json::object();
  // The file list is a Foundry-Local-Mobile download-planning aid, not part of the
  // package format. Drop it so the installed manifest is a plain package manifest.
  entry.erase("files");

  nlohmann::json component;
  component["name"] = variant->component;
  component["variants"] = nlohmann::json::array({std::move(entry)});
  manifest["components"] = nlohmann::json::array({std::move(component)});

  nlohmann::json assets = nlohmann::json::object();
  for (const std::string& reference : variant->shared_asset_refs) {
    const SharedAsset* asset = FindAsset(reference);
    if (asset == nullptr) {
      continue;
    }
    nlohmann::json descriptor =
        asset->source_entry.is_object() ? asset->source_entry : nlohmann::json::object();
    descriptor.erase("files");
    if (!descriptor.contains("path")) {
      descriptor["path"] = asset->relative_path;
    }
    assets[asset->digest] = std::move(descriptor);
  }
  if (!assets.empty()) {
    manifest["shared_assets"] = std::move(assets);
  }

  return manifest;
}

/* ------------------------------------------------------------------------- */
/* Download accounting                                                        */
/* ------------------------------------------------------------------------- */

ModelPackage::DownloadEstimate ModelPackage::EstimateDownload(const std::vector<std::string>& variant_ids) const {
  DownloadEstimate estimate;

  // A set, because two variants sharing a 3 GB weights blob must count it once. Summing
  // per-variant totals is the obvious implementation and it is wrong by gigabytes.
  std::set<std::string> referenced_assets;

  for (const auto& variant_id : variant_ids) {
    const ModelVariant* variant = FindVariant(variant_id);
    if (variant == nullptr) {
      continue;
    }
    estimate.disk_bytes += variant->own_bytes;
    if (variant->is_cached) {
      estimate.already_cached_bytes += variant->own_bytes;
    } else {
      estimate.download_bytes += variant->own_bytes;
    }
    referenced_assets.insert(variant->shared_asset_refs.begin(), variant->shared_asset_refs.end());
  }

  for (const auto& digest : referenced_assets) {
    const SharedAsset* asset = FindAsset(digest);
    if (asset == nullptr) {
      continue;
    }
    estimate.disk_bytes += asset->bytes;
    if (asset->is_cached) {
      estimate.already_cached_bytes += asset->bytes;
    } else {
      estimate.download_bytes += asset->bytes;
    }
  }
  return estimate;
}

nlohmann::json ModelPackage::DownloadEstimate::ToJson(int64_t available_storage_bytes) const {
  // Require headroom beyond the download itself: extraction and verification need
  // temporary space, and a phone that fills its disk mid-download is a bad outcome.
  constexpr double kHeadroomFactor = 1.2;
  const bool fits = available_storage_bytes <= 0 ||
                    static_cast<double>(download_bytes) * kHeadroomFactor < static_cast<double>(available_storage_bytes);
  return nlohmann::json{
      {"download_bytes", download_bytes},
      {"disk_bytes", disk_bytes},
      {"already_cached_bytes", already_cached_bytes},
      {"available_storage_bytes", available_storage_bytes},
      {"fits_on_device", fits},
  };
}

std::vector<std::string> ModelPackage::FindOrphanedAssets(const std::vector<std::string>& remaining_variant_ids) const {
  std::set<std::string> still_referenced;
  for (const auto& variant_id : remaining_variant_ids) {
    if (const ModelVariant* variant = FindVariant(variant_id)) {
      still_referenced.insert(variant->shared_asset_refs.begin(), variant->shared_asset_refs.end());
    }
  }

  std::vector<std::string> orphans;
  for (const auto& asset : shared_assets_) {
    if (asset.is_cached && still_referenced.find(asset.digest) == still_referenced.end()) {
      orphans.push_back(asset.digest);
    }
  }
  return orphans;
}

/* ------------------------------------------------------------------------- */
/* Serialization                                                              */
/* ------------------------------------------------------------------------- */

nlohmann::json ModelPackage::ToJson() const {
  nlohmann::json variants = nlohmann::json::array();
  for (const auto& variant : variants_) {
    const DownloadEstimate estimate = EstimateDownload({variant.id});
    variants.push_back({
        {"id", variant.id},
        {"component", variant.component},
        {"execution_provider", variant.execution_provider},
        {"device", ToString(variant.device)},
        {"compatibility_string", variant.compatibility_string},
        {"platform", variant.platform},
        {"download_size_bytes", estimate.download_bytes},
        {"disk_size_bytes", estimate.disk_bytes},
        {"shared_asset_refs", variant.shared_asset_refs},
        {"is_compatible", variant.is_compatible},
        {"compatibility_score", variant.compatibility_score},
        {"is_cached", variant.is_cached},
        {"incompatibility_reason",
         variant.incompatibility_reason.empty() ? nlohmann::json(nullptr) : nlohmann::json(variant.incompatibility_reason)},
    });
  }

  int64_t shared_assets_bytes = 0;
  for (const auto& asset : shared_assets_) {
    shared_assets_bytes += asset.bytes;
  }

  return nlohmann::json{
      {"package_id", id_},
      {"schema_version", schema_version_},
      {"selected_variant_id", selected_variant_id_.empty() ? nlohmann::json(nullptr) : nlohmann::json(selected_variant_id_)},
      {"shared_assets_bytes", shared_assets_bytes},
      {"variants", variants},
  };
}

}  // namespace flm
