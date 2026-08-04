// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Model downloader.
//
// Foundry Local ships its own downloader, but it is built for the desktop story: it
// resolves models out of the Azure model catalog and fetches the desktop-targeted
// builds published there. Mobile needs neither. Apps ship their own models or host them
// on their own storage, so this downloader fetches from a URL the app supplies, with
// credentials the app supplies, and knows nothing about any catalog.
//
// What it produces, though, is deliberately Foundry Local's on-disk layout, because
// that is the only way to hand a model to the runtime. The C ABI has no "load from
// path" entry point — every flModel comes from a flCatalog — but the catalog scans the
// cache directory and adopts any directory it finds there as a local model. A directory
// qualifies when it holds genai_config.json and an inference_model.json naming the
// model, and does not hold download.tmp.
//
// That last file is Foundry Local's own incomplete-download sentinel, and this
// downloader reuses it as the commit marker: bytes land directly in their final
// location, which makes resume trivial, while the sentinel keeps the half-finished
// directory invisible to the scanner. Deleting it is the atomic "this model is ready"
// step.

#ifndef FOUNDRY_LOCAL_MOBILE_DOWNLOADER_H_
#define FOUNDRY_LOCAL_MOBILE_DOWNLOADER_H_

#include <cstdint>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

#include "third_party/json.h"

namespace flm {

class JobContext;

/// One file to retrieve.
struct RemoteFile {
  std::string relative_path;  ///< Path within the model directory. Must stay inside it.
  std::string url;            ///< Absolute URL.
  int64_t size = -1;          ///< Expected size, or -1 if the manifest omits it.
  std::string digest;         ///< Expected SHA-256, optionally "sha256:"-prefixed. May be empty.
};

/// A fully resolved download: every file, where it goes, and what it must hash to.
struct DownloadPlan {
  /// What the finished directory should look like. This decides the completeness check:
  /// a flat model must end up with genai_config.json at the top level, whereas in a
  /// package that file lives inside each variant directory and the top level carries
  /// manifest.json instead.
  enum class Layout {
    kFlatModel,
    kPackage,
  };

  std::string model_name;                       ///< Written to inference_model.json as "Name".
  std::string destination_dir;                  ///< Final model directory.
  Layout layout = Layout::kFlatModel;
  std::vector<RemoteFile> files;
  std::map<std::string, std::string> headers;   ///< Applied to every request.
  nlohmann::json prompt_templates = nlohmann::json::object();

  /// Written to the destination before committing. Used for a package, where the
  /// manifest is pruned to describe only the variant that was actually downloaded.
  nlohmann::json manifest_override;

  bool resume = true;
  bool verify_checksums = true;

  int64_t total_bytes = 0;
};

class Downloader {
 public:
  /// Retrieve a small document into memory. Used for manifests, never for weights.
  static std::string FetchToMemory(const std::string& url, const std::map<std::string, std::string>& headers,
                                   JobContext& context);

  /// Retrieve and parse a JSON document.
  static nlohmann::json FetchJson(const std::string& url, const std::map<std::string, std::string>& headers,
                                  JobContext& context);

  /// Execute a plan. Resumes partial files, verifies digests, and commits atomically by
  /// removing the sentinel. Returns {"path", "bytes_downloaded", "bytes_reused"}.
  static nlohmann::json Execute(const DownloadPlan& plan, JobContext& context);

  /// True if `dir` holds a model the Foundry Local catalog would adopt.
  static bool IsCompleteModelDirectory(const std::string& dir);

  /// Resolve a possibly-relative URL against a base. Absolute URLs pass through.
  static std::string ResolveUrl(const std::string& base, const std::string& reference);

  /// Reject paths that escape the model directory. A manifest is remote input, so a
  /// "../../" entry would otherwise let a host write anywhere the app can.
  static void ValidateRelativePath(const std::string& path);

 private:
  /// Write the file that makes a finished download discoverable, into `model_dir`.
  ///
  /// It has to land beside genai_config.json, because the runtime's scan only counts a
  /// directory holding *both*. For a flat model that is the destination itself; for a
  /// package it is the downloaded variant's directory, not the package root.
  static void WriteInferenceModelJson(const DownloadPlan& plan, const std::filesystem::path& model_dir);
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_DOWNLOADER_H_
