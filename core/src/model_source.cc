// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "model_source.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <set>
#include <system_error>

#include "device_profile.h"
#include "error.h"
#include "job.h"
#include "manager.h"
#include "transport.h"

namespace flm {
namespace {

namespace fs = std::filesystem;

/// Reduce a model name to something safe to use as a directory name. Names come from app
/// configuration and may contain a version separator or path characters.
std::string SanitizeDirectoryName(const std::string& name) {
  std::string result;
  result.reserve(name.size());
  for (const char c : name) {
    const auto uc = static_cast<unsigned char>(c);
    result.push_back((std::isalnum(uc) || c == '-' || c == '_' || c == '.') ? c : '-');
  }
  if (result.empty()) {
    result = "model";
  }
  return result;
}

/// True when the URL names a manifest rather than a directory.
bool LooksLikeManifestUrl(const std::string& url) {
  std::string path = url;
  if (const auto q = path.find('?'); q != std::string::npos) {
    path = path.substr(0, q);
  }
  return path.size() >= 5 && path.compare(path.size() - 5, 5, ".json") == 0;
}

/// The file the runtime's local scan reads a model's id out of. A directory counts as a
/// cached model only when it holds this *and* genai_config.json, with no download.tmp.
constexpr const char* kInferenceModelFileName = "inference_model.json";

/// Make a model directory discoverable by the runtime's catalog.
///
/// The runtime finds a locally present model by walking the model cache directory for a
/// directory holding both genai_config.json and inference_model.json, taking the model's
/// id from the latter's "Name". A model the app supplies — bundled in the APK or fetched
/// by this SDK's own downloader — carries the first file but never the second, because
/// only the runtime's own downloader writes it. Without this step such a model stays
/// invisible: absent from the catalog, absent from the cached list, and impossible to get
/// a handle for, which makes it impossible to load. The bytes being on disk is not enough.
///
/// Writing it is idempotent and preserves an id the model already declares, so a package
/// that was published with its own inference_model.json keeps it. The shape matches what
/// Downloader::WriteInferenceModelJson emits for a downloaded model, so a bundled model
/// and a fetched one are indistinguishable to the scanner.
void PublishModelId(const fs::path& model_dir, const std::string& name,
                    const nlohmann::json& prompt_templates) {
  const fs::path marker = model_dir / kInferenceModelFileName;
  std::error_code ec;
  if (fs::exists(marker, ec)) {
    return;
  }
  nlohmann::json document;
  document["Name"] = name;
  if (prompt_templates.is_object() && !prompt_templates.empty()) {
    document["PromptTemplate"] = prompt_templates;
  } else {
    document["PromptTemplate"] = nullptr;
  }

  std::ofstream stream(marker, std::ios::binary | std::ios::trunc);
  if (!stream) {
    throw Error(FLM_ERROR_STORAGE, "cannot publish the model id for '" + name + "'",
                {{"path", marker.string()}});
  }
  stream << document.dump(2);
  stream.close();
  if (stream.fail()) {
    fs::remove(marker, ec);
    throw Error(FLM_ERROR_STORAGE, "cannot publish the model id for '" + name + "'",
                {{"path", marker.string()}});
  }
}

/// Expose a model directory inside the cache without duplicating its bytes.
///
/// A bundled model is loaded in place, so it sits outside the cache the runtime scans and
/// stays invisible however complete it is. Copying it would double the storage the user
/// paid for once already, so instead the cache gets a real directory of symlinks to the
/// source's files. That also covers a source the app cannot write to — assets extracted
/// read-only, or a path inside the app bundle — where publishing the id in place is not
/// an option.
fs::path LinkModelIntoCache(const fs::path& model_dir, const fs::path& destination, const std::string& name) {
  std::error_code ec;
  fs::remove_all(destination, ec);
  fs::create_directories(destination, ec);
  if (ec) {
    throw Error(FLM_ERROR_STORAGE, "cannot create the cache directory for '" + name + "'",
                {{"path", destination.string()}, {"reason", ec.message()}});
  }

  for (const auto& entry : fs::directory_iterator(model_dir, ec)) {
    if (!entry.is_regular_file(ec)) {
      continue;
    }
    const fs::path link = destination / entry.path().filename();
    fs::create_symlink(fs::absolute(entry.path()), link, ec);
    if (ec) {
      // Filesystems that cannot link still have to end up with a usable model, and a
      // single model directory is small next to the weights it points at.
      ec.clear();
      fs::copy_file(entry.path(), link, fs::copy_options::overwrite_existing, ec);
      if (ec) {
        throw Error(FLM_ERROR_STORAGE, "cannot publish '" + name + "' into the model cache",
                    {{"source", entry.path().string()}, {"destination", link.string()}, {"reason", ec.message()}});
      }
    }
  }
  return destination;
}

}  // namespace

ModelSource ModelSource::FromJson(const nlohmann::json& json) {
  if (!json.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "model source must be a JSON object");
  }

  ModelSource source;

  const std::string kind = json.value("kind", "");
  if (kind == "bundled" || kind == "local" || kind == "path") {
    source.kind = SourceKind::kBundled;
  } else if (kind == "remote" || kind == "url") {
    source.kind = SourceKind::kRemote;
  } else if (kind.empty()) {
    // Infer from what was supplied, so the common cases need no "kind" at all.
    if (json.contains("url")) {
      source.kind = SourceKind::kRemote;
    } else if (json.contains("path")) {
      source.kind = SourceKind::kBundled;
    } else {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "model source needs either 'path' or 'url'");
    }
  } else {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "unknown model source kind '" + kind + "'", {{"kind", kind}});
  }

  source.name = json.value("name", "");
  if (source.name.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "model source requires a 'name'");
  }

  if (source.kind == SourceKind::kBundled) {
    source.path = json.value("path", "");
    if (source.path.empty()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "a bundled model source requires a 'path'");
    }
    source.copy_into_cache = json.value("copy_into_cache", false);
  } else {
    source.url = json.value("url", "");
    if (source.url.empty()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "a remote model source requires a 'url'");
    }
    if (auto headers = json.find("headers"); headers != json.end()) {
      source.headers = ParseHeaderObject(*headers);
    }
  }

  if (auto constraints = json.find("constraints"); constraints != json.end()) {
    source.constraints = VariantConstraints::FromJson(*constraints);
  }
  if (auto templates = json.find("prompt_templates");
      templates != json.end() && templates->is_object()) {
    source.prompt_templates = *templates;
  }
  source.resume = json.value("resume", true);
  source.verify_checksums = json.value("verify_checksums", true);

  return source;
}

std::string ModelSourceResolver::DestinationFor(const ModelSource& source) const {
  // Nested one level under the cache root because the runtime's local scan treats the
  // top level as publisher directories and looks for models inside them.
  return (fs::path(manager_->model_cache_dir()) / "sources" / SanitizeDirectoryName(source.name)).string();
}

nlohmann::json ModelSourceResolver::Resolve(const ModelSource& source, JobContext& context) {
  manager_->ThrowIfShutdown();
  switch (source.kind) {
    case SourceKind::kBundled:
      return ResolveBundled(source, context);
    case SourceKind::kRemote:
      return ResolveRemote(source, context);
  }
  throw Error(FLM_ERROR_INVALID_ARGUMENT, "unhandled model source kind");
}

nlohmann::json ModelSourceResolver::ResolveBundled(const ModelSource& source, JobContext& context) {
  std::error_code ec;
  const fs::path path(source.path);
  if (!fs::is_directory(path, ec)) {
    throw Error(FLM_ERROR_NOT_FOUND, "bundled model directory does not exist: " + source.path,
                {{"path", source.path}});
  }

  // An app bundling several variants gets the same device-aware selection as a remote
  // package. Shipping one APK that runs the NPU build on hardware that has one and falls
  // back to CPU elsewhere is the whole point of bundling a package rather than a model.
  //
  // `model_dir` is what actually holds the weights, which for a package is the selected
  // variant rather than the package root. That distinction matters below: the runtime
  // scans for the directory containing genai_config.json, not for the package.
  std::string variant_id;
  fs::path model_dir = path;
  if (ModelPackage::IsPackageDirectory(source.path)) {
    ModelPackage package = ModelPackage::FromDirectory(source.path, source.name);
    package.ScoreVariants(manager_->device_profile());

    auto selected = package.SelectBestVariant(source.constraints);
    if (!selected) {
      throw Error(FLM_ERROR_INCOMPATIBLE,
                  "no variant in the bundled package '" + source.name + "' can run on this device",
                  {{"name", source.name}, {"package", package.ToJson()}});
    }
    variant_id = *selected;
    if (const ModelVariant* variant = package.FindVariant(variant_id)) {
      model_dir = path / variant->relative_path;
    }
  }

  context.ThrowIfCancelled();

  // A bundled model is normally loaded in place: it is already on the device, and
  // copying it would double the storage a user pays for. Copying is opt-in for the case
  // where the source lives somewhere the app cannot keep, such as a temporary
  // extraction directory.
  //
  // Either way it has to end up visible to the runtime's catalog, which only looks inside
  // the model cache directory. In place means linking it in; a copy is already there.
  const fs::path destination(DestinationFor(source));
  std::string resolved_path;
  if (source.copy_into_cache) {
    std::error_code copy_ec;
    fs::create_directories(destination.parent_path(), copy_ec);
    fs::copy(model_dir, destination, fs::copy_options::recursive | fs::copy_options::overwrite_existing, copy_ec);
    if (copy_ec) {
      throw Error(FLM_ERROR_STORAGE, "cannot copy the bundled model into the cache: " + copy_ec.message(),
                  {{"source", model_dir.string()}, {"destination", destination.string()}});
    }
    resolved_path = destination.string();
  } else {
    resolved_path = LinkModelIntoCache(model_dir, destination, source.name).string();
  }

  PublishModelId(resolved_path, source.name, source.prompt_templates);

  return nlohmann::json{{"name", source.name},
                        {"path", resolved_path},
                        {"variant_id", variant_id},
                        {"bytes_downloaded", 0},
                        {"bytes_reused", 0},
                        {"was_cached", true}};
}

DownloadPlan ModelSourceResolver::PlanPackageDownload(const ModelSource& source,
                                                      const nlohmann::json& manifest,
                                                      const std::string& destination,
                                                      std::string* out_variant_id, JobContext& context) {
  ModelPackage package = ModelPackage::FromManifest(manifest, source.name);
  package.ScoreVariants(manager_->device_profile());

  auto selected = package.SelectBestVariant(source.constraints);
  if (!selected) {
    throw Error(FLM_ERROR_INCOMPATIBLE,
                "no variant of '" + source.name + "' can run on this device",
                {{"name", source.name}, {"package", package.ToJson()}});
  }
  *out_variant_id = *selected;

  const ModelVariant* variant = package.FindVariant(*selected);
  if (variant->files.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "variant '" + variant->id +
                    "' lists no files, so the download cannot be planned. A manifest published for "
                    "remote download must give each variant a 'files' array.",
                {{"variant_id", variant->id}});
  }

  DownloadPlan plan;
  plan.model_name = source.name;
  plan.destination_dir = destination;
  plan.layout = DownloadPlan::Layout::kPackage;
  plan.headers = source.headers;
  plan.prompt_templates = source.prompt_templates;
  plan.resume = source.resume;
  plan.verify_checksums = source.verify_checksums;
  plan.manifest_override = package.BuildPrunedManifest(*selected);

  // Only the selected variant's files, plus the shared assets it references. Every other
  // variant in the package is skipped, which is the entire reason selective download
  // exists on a device with a metered connection and finite storage.
  auto append = [&](const PackageFile& file) {
    RemoteFile remote;
    remote.relative_path = file.relative_path;
    remote.url = Downloader::ResolveUrl(source.url, file.relative_path);
    remote.size = file.size;
    remote.digest = file.digest;
    plan.files.push_back(std::move(remote));
    if (file.size > 0) {
      plan.total_bytes += file.size;
    }
  };

  for (const PackageFile& file : variant->files) {
    append(file);
  }

  // A shared asset referenced by several variants must still be fetched once.
  std::set<std::string> seen;
  for (const std::string& reference : variant->shared_asset_refs) {
    const SharedAsset* asset = package.FindSharedAsset(reference);
    if (asset == nullptr || !seen.insert(asset->digest).second) {
      continue;
    }
    if (asset->files.empty()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT,
                  "shared asset '" + asset->digest + "' lists no files, so it cannot be downloaded",
                  {{"digest", asset->digest}});
    }
    for (const PackageFile& file : asset->files) {
      append(file);
    }
  }

  context.ThrowIfCancelled();
  return plan;
}

DownloadPlan ModelSourceResolver::PlanDirectoryDownload(const ModelSource& source,
                                                        const nlohmann::json& listing,
                                                        const std::string& destination) {
  DownloadPlan plan;
  plan.model_name = source.name;
  plan.destination_dir = destination;
  plan.layout = DownloadPlan::Layout::kFlatModel;
  plan.headers = source.headers;
  plan.prompt_templates = source.prompt_templates;
  plan.resume = source.resume;
  plan.verify_checksums = source.verify_checksums;

  const auto files = listing.find("files");
  if (files == listing.end() || !files->is_array() || files->empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "the model index at " + source.url + " lists no files", {{"url", source.url}});
  }

  if (auto templates = listing.find("prompt_templates");
      templates != listing.end() && templates->is_object() && plan.prompt_templates.empty()) {
    plan.prompt_templates = *templates;
  }

  for (const auto& item : *files) {
    RemoteFile file;
    if (item.is_string()) {
      file.relative_path = item.get<std::string>();
    } else if (item.is_object()) {
      file.relative_path = item.value("path", "");
      file.size = item.value("size", static_cast<int64_t>(-1));
      file.digest = item.value("digest", item.value("sha256", ""));
    }
    if (file.relative_path.empty()) {
      continue;
    }
    file.url = Downloader::ResolveUrl(source.url, item.is_object() && item.contains("url")
                                                      ? item.value("url", "")
                                                      : file.relative_path);
    if (file.size > 0) {
      plan.total_bytes += file.size;
    }
    plan.files.push_back(std::move(file));
  }

  return plan;
}

nlohmann::json ModelSourceResolver::ResolveRemote(const ModelSource& source, JobContext& context) {
  if (!Transport::Instance().IsInstalled()) {
    throw Error(FLM_ERROR_INVALID_STATE,
                "downloading requires an HTTP transport; the platform binding installs one at startup");
  }

  const std::string destination = DestinationFor(source);

  // Already downloaded and committed: nothing to do. The sentinel check inside
  // IsCompleteModelDirectory is what makes an interrupted download not count.
  if (Downloader::IsCompleteModelDirectory(destination)) {
    // The manifest left behind was pruned to the variant that was actually fetched, so a
    // cache hit can name it. Reporting "" here instead would make the same call answer
    // differently depending on whether it happened to be cached — an app that records
    // which variant it holds would silently lose it on the second run.
    std::string variant_id;
    if (ModelPackage::IsPackageDirectory(destination)) {
      try {
        const ModelPackage package = ModelPackage::FromDirectory(destination, source.name);
        if (package.variants().size() == 1) {
          variant_id = package.variants().front().id;
        }
      } catch (const Error&) {
        // A model that is on disk and usable is not worth failing over an unreadable
        // manifest; the caller loses the variant id, not the model.
      }
    }
    return nlohmann::json{{"name", source.name},
                          {"path", destination},
                          {"variant_id", variant_id},
                          {"bytes_downloaded", 0},
                          {"bytes_reused", 0},
                          {"was_cached", true}};
  }

  // Check the network policy before fetching anything. The manifest itself is small, but
  // failing here keeps the error about the download the caller actually asked for.
  const DeviceProfile profile = GetDeviceProfile();
  if (profile.network == NetworkState::kNone) {
    throw Error(FLM_ERROR_NETWORK, "no network connection is available for this download");
  }

  context.ReportProgress(0.0f, "resolving", 0, FLM_UNKNOWN_SIZE, source.name);

  const nlohmann::json document = Downloader::FetchJson(source.url, source.headers, context);

  std::string variant_id;
  DownloadPlan plan;

  // A manifest with components is a model package; anything else is a flat file index.
  // Sniffing the document rather than the URL means a host can serve either from any
  // path, which matters when the URL is a signed blob link with no meaningful name.
  const bool is_package = document.contains("components");
  if (is_package) {
    plan = PlanPackageDownload(source, document, destination, &variant_id, context);
  } else if (document.contains("files")) {
    plan = PlanDirectoryDownload(source, document, destination);
  } else {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "the document at " + source.url +
                    " is neither a model package manifest ('components') nor a file index ('files')",
                {{"url", source.url}, {"looks_like_manifest", LooksLikeManifestUrl(source.url)}});
  }

  // Enforce the metered-network policy now that the real size is known.
  const bool allow_metered = manager_->settings().download_on_metered_network;
  if (!allow_metered && !profile.CanDownloadSilently(plan.total_bytes)) {
    throw Error(FLM_ERROR_NETWORK,
                "this download requires a large transfer on a metered connection. Enable "
                "download_on_metered_network to proceed.",
                {{"download_bytes", plan.total_bytes}, {"network", ToString(profile.network)}});
  }

  nlohmann::json result = Downloader::Execute(plan, context);
  result["name"] = source.name;
  result["variant_id"] = variant_id;
  result["was_cached"] = false;
  return result;
}

}  // namespace flm
