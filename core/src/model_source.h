// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Model sources: where a model comes from.
//
// Mobile apps acquire models in two ways, and the SDK has to make both land in the same
// place so everything downstream is identical.
//
//   bundled — the model ships inside the app. The app extracts it from its assets (or
//             points at any directory it controls) and hands over the path. No network,
//             works offline from first launch, and the model is as reviewed as the
//             binary. Costs app size, so it suits small models.
//
//   remote  — the app hosts the model on storage it controls and supplies the URL and
//             credentials. Keeps the download out of the app bundle and lets the model
//             be updated without shipping a release.
//
// The remote path is deliberately generic: the SDK is told a URL and a set of headers
// and asks for nothing else. That covers a blob SAS URL, an API key, a bearer token, a
// signed CDN URL, or a plain unauthenticated host, with no per-provider code. Anything
// that needs a live credential — a token that must be refreshed mid-download — is
// handled by the platform transport, which is the app's own code.
//
// A remote source may point at either a model package manifest or a plain directory.
// When it is a package, the device is scored against the variants and only the matching
// one is fetched, along with the shared assets it references. That is the difference
// between a 400 MB download and a 3 GB one on a metered connection, and unlike desktop
// it is not an optimization — the variants a phone cannot run are routinely larger than
// the one it can.

#ifndef FOUNDRY_LOCAL_MOBILE_MODEL_SOURCE_H_
#define FOUNDRY_LOCAL_MOBILE_MODEL_SOURCE_H_

#include <map>
#include <memory>
#include <string>

#include "downloader.h"
#include "model_package.h"
#include "third_party/json.h"

namespace flm {

class Manager;
class JobContext;

/// How a model is obtained.
enum class SourceKind {
  kBundled,  ///< Already on disk, shipped with or extracted by the app.
  kRemote,   ///< Fetched from a URL the app supplies.
};

/// A parsed source descriptor. See ParseModelSource for the JSON schema.
struct ModelSource {
  SourceKind kind = SourceKind::kBundled;

  std::string name;  ///< Model name registered with the runtime. Required.

  // Bundled.
  std::string path;  ///< Directory holding the model or package.
  bool copy_into_cache = false;

  // Remote.
  std::string url;                             ///< Manifest URL, or a directory base URL.
  std::map<std::string, std::string> headers;  ///< Sent with every request.

  VariantConstraints constraints;
  nlohmann::json prompt_templates = nlohmann::json::object();

  static ModelSource FromJson(const nlohmann::json& json);
};

/// Resolves a source into a model directory the runtime can load.
class ModelSourceResolver {
 public:
  explicit ModelSourceResolver(std::shared_ptr<Manager> manager) : manager_(std::move(manager)) {}

  /// Make the model available locally and return a description of what landed:
  /// {"name", "path", "variant_id", "bytes_downloaded", "bytes_reused", "was_cached"}.
  nlohmann::json Resolve(const ModelSource& source, JobContext& context);

 private:
  nlohmann::json ResolveBundled(const ModelSource& source, JobContext& context);
  nlohmann::json ResolveRemote(const ModelSource& source, JobContext& context);

  /// Fetch a remote manifest, pick the variant this device should run, and build the
  /// file list for it. Throws FLM_ERROR_INCOMPATIBLE when nothing is runnable here.
  DownloadPlan PlanPackageDownload(const ModelSource& source, const nlohmann::json& manifest,
                                   const std::string& destination, std::string* out_variant_id,
                                   JobContext& context);

  /// Build the file list for a remote directory that is not a package.
  DownloadPlan PlanDirectoryDownload(const ModelSource& source, const nlohmann::json& listing,
                                     const std::string& destination);

  /// Where a source's files belong under the model cache.
  std::string DestinationFor(const ModelSource& source) const;

  std::shared_ptr<Manager> manager_;
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_MODEL_SOURCE_H_
