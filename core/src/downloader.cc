// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "downloader.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <system_error>

#include "device_profile.h"
#include "error.h"
#include "job.h"
#include "sha256.h"
#include "transport.h"

namespace flm {
namespace {

namespace fs = std::filesystem;

/// Foundry Local's marker for an incomplete download. Its presence makes the catalog's
/// local scan skip the directory, which is exactly the semantics a resumable download
/// needs, so it doubles as this downloader's commit marker.
constexpr const char* kDownloadSentinel = "download.tmp";
constexpr const char* kGenAiConfigFile = "genai_config.json";
constexpr const char* kInferenceModelFile = "inference_model.json";

/// A digest mismatch is retried once: the overwhelmingly common cause is a truncated or
/// corrupted resume, which a clean re-fetch fixes. A second failure means the bytes on
/// the server genuinely disagree with the manifest, and retrying forever would just burn
/// the user's data.
constexpr int kDigestRetries = 1;

bool HasScheme(const std::string& url) {
  const auto pos = url.find("://");
  return pos != std::string::npos && pos > 0;
}

int64_t FileSizeOrZero(const fs::path& path) {
  std::error_code ec;
  const auto size = fs::file_size(path, ec);
  return ec ? 0 : static_cast<int64_t>(size);
}

}  // namespace

void Downloader::ValidateRelativePath(const std::string& path) {
  if (path.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "manifest contains an empty file path");
  }

  const fs::path candidate(path);
  if (candidate.is_absolute()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "manifest file path must be relative: '" + path + "'",
                {{"path", path}});
  }
  for (const auto& part : candidate) {
    if (part == "..") {
      throw Error(FLM_ERROR_INVALID_ARGUMENT,
                  "manifest file path must not traverse outside the model directory: '" + path + "'",
                  {{"path", path}});
    }
  }
  // Windows drive-relative forms and UNC prefixes never appear on mobile, but a manifest
  // is remote input and a backslash would be a literal filename character here, so
  // reject it rather than silently creating a strangely named file.
  if (path.find('\\') != std::string::npos) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "manifest file path must use '/' separators: '" + path + "'",
                {{"path", path}});
  }
}

std::string Downloader::ResolveUrl(const std::string& base, const std::string& reference) {
  if (reference.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "manifest entry has an empty URL");
  }
  if (HasScheme(reference)) {
    return reference;
  }
  if (base.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "manifest entry '" + reference + "' is relative but no base URL is known",
                {{"reference", reference}});
  }

  // Resolve against the base's directory, preserving any query string the base carries —
  // a SAS token lives there, and dropping it would turn every file request into a 403.
  std::string base_path = base;
  std::string query;
  if (const auto q = base_path.find('?'); q != std::string::npos) {
    query = base_path.substr(q);
    base_path = base_path.substr(0, q);
  }

  const auto slash = base_path.rfind('/');
  if (slash == std::string::npos || slash < base_path.find("://") + 3) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "cannot resolve '" + reference + "' against '" + base + "'");
  }

  return base_path.substr(0, slash + 1) + reference + query;
}

std::string Downloader::FetchToMemory(const std::string& url, const std::map<std::string, std::string>& headers,
                                      JobContext& context) {
  const HttpResult result = Transport::Instance().Fetch(url, "GET", headers, /*destination_path=*/"",
                                                        /*offset=*/0, /*expected_bytes=*/FLM_UNKNOWN_SIZE,
                                                        &context);
  if (result.cancelled) {
    throw Error(FLM_ERROR_CANCELLED, "download cancelled");
  }
  if (!result.ok()) {
    throw Error(FLM_ERROR_NETWORK,
                "request for " + url + " failed" +
                    (result.error_message.empty() ? " with status " + std::to_string(result.status_code)
                                                  : ": " + result.error_message),
                {{"url", url}, {"status_code", result.status_code}});
  }
  return result.body;
}

nlohmann::json Downloader::FetchJson(const std::string& url, const std::map<std::string, std::string>& headers,
                                     JobContext& context) {
  const std::string body = FetchToMemory(url, headers, context);
  try {
    return nlohmann::json::parse(body);
  } catch (const nlohmann::json::exception& ex) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "response from " + url + " is not valid JSON: " + ex.what(),
                {{"url", url}});
  }
}

bool Downloader::IsCompleteModelDirectory(const std::string& dir) {
  const fs::path path(dir);
  std::error_code ec;
  if (!fs::is_directory(path, ec)) {
    return false;
  }
  return fs::exists(path / kGenAiConfigFile, ec) && fs::exists(path / kInferenceModelFile, ec) &&
         !fs::exists(path / kDownloadSentinel, ec);
}

void Downloader::WriteInferenceModelJson(const DownloadPlan& plan) {
  // Shape must match what Foundry Local's local model scanner reads: a "Name" string and
  // a "PromptTemplate" object or null.
  nlohmann::json document;
  document["Name"] = plan.model_name;
  if (plan.prompt_templates.is_object() && !plan.prompt_templates.empty()) {
    document["PromptTemplate"] = plan.prompt_templates;
  } else {
    document["PromptTemplate"] = nullptr;
  }

  const fs::path path = fs::path(plan.destination_dir) / kInferenceModelFile;
  std::ofstream out(path);
  if (!out) {
    throw Error(FLM_ERROR_STORAGE, "cannot write " + path.string(), {{"path", path.string()}});
  }
  out << document.dump(2);
  out.close();
  if (out.fail()) {
    std::error_code ec;
    fs::remove(path, ec);
    throw Error(FLM_ERROR_STORAGE, "failed to write " + path.string(), {{"path", path.string()}});
  }
}

nlohmann::json Downloader::Execute(const DownloadPlan& plan, JobContext& context) {
  if (plan.files.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "download plan contains no files");
  }

  const fs::path destination(plan.destination_dir);
  std::error_code ec;

  fs::create_directories(destination, ec);
  if (ec) {
    throw Error(FLM_ERROR_STORAGE, "cannot create " + destination.string() + ": " + ec.message(),
                {{"path", destination.string()}});
  }

  // Refuse to start a download the device cannot hold. A 1.2x factor covers the
  // filesystem overhead and leaves the device usable afterwards; filling the last byte
  // of storage on a phone breaks unrelated apps.
  const int64_t available = GetDeviceProfile().available_storage_bytes;
  if (available > 0 && plan.total_bytes > 0 &&
      static_cast<double>(available) < static_cast<double>(plan.total_bytes) * 1.2) {
    throw Error(FLM_ERROR_STORAGE, "not enough free storage for this model",
                {{"required_bytes", plan.total_bytes}, {"available_bytes", available}});
  }

  // Raise the sentinel before the first byte lands, so an interrupted download is never
  // mistaken for a usable model.
  const fs::path sentinel = destination / kDownloadSentinel;
  {
    std::ofstream marker(sentinel);
    if (!marker) {
      throw Error(FLM_ERROR_STORAGE, "cannot create " + sentinel.string(), {{"path", sentinel.string()}});
    }
  }

  int64_t downloaded = 0;
  int64_t reused = 0;
  const int64_t total = plan.total_bytes;

  auto report = [&](int64_t file_bytes, const std::string& detail) {
    const int64_t done = downloaded + reused + file_bytes;
    const float percent = total > 0 ? std::min(100.0f, 100.0f * static_cast<float>(done) /
                                                           static_cast<float>(total))
                                    : 0.0f;
    context.ReportProgress(percent, "downloading", done, total > 0 ? total : FLM_UNKNOWN_SIZE, detail);
  };

  for (const RemoteFile& file : plan.files) {
    context.ThrowIfCancelled();
    ValidateRelativePath(file.relative_path);

    const fs::path target = destination / file.relative_path;
    fs::create_directories(target.parent_path(), ec);
    if (ec) {
      throw Error(FLM_ERROR_STORAGE, "cannot create " + target.parent_path().string() + ": " + ec.message());
    }

    // An already-complete file from an earlier attempt is kept if it still verifies.
    // Re-downloading gigabytes because the app was killed near the end is the single
    // worst thing a mobile downloader can do.
    if (fs::exists(target, ec)) {
      const int64_t existing = FileSizeOrZero(target);
      const bool size_matches = file.size < 0 || existing == file.size;
      const bool digest_ok = !plan.verify_checksums || file.digest.empty() ||
                             DigestMatches(file.digest, Sha256File(target.string()));
      if (size_matches && digest_ok) {
        reused += existing;
        report(0, file.relative_path);
        continue;
      }
    }

    bool succeeded = false;
    for (int attempt = 0; attempt <= kDigestRetries && !succeeded; ++attempt) {
      context.ThrowIfCancelled();

      // Resume from whatever is already on disk, unless this is a retry after a digest
      // mismatch — in that case the existing bytes are suspect and must go.
      int64_t offset = 0;
      if (attempt > 0 || !plan.resume) {
        fs::remove(target, ec);
      } else if (fs::exists(target, ec)) {
        const int64_t existing = FileSizeOrZero(target);
        if (file.size > 0 && existing < file.size) {
          offset = existing;
        } else if (existing > 0 && file.size < 0) {
          // Unknown expected size: cannot tell partial from complete, so start over.
          fs::remove(target, ec);
        } else if (file.size > 0 && existing > file.size) {
          fs::remove(target, ec);
        }
      }

      const int64_t base_bytes = offset;
      const HttpResult result = Transport::Instance().Fetch(
          file.url, "GET", plan.headers, target.string(), offset, file.size, &context,
          [&](int64_t completed, int64_t /*file_total*/) { report(base_bytes + completed, file.relative_path); });

      if (result.cancelled) {
        throw Error(FLM_ERROR_CANCELLED, "download cancelled");
      }
      if (!result.ok()) {
        throw Error(FLM_ERROR_NETWORK,
                    "failed to download " + file.relative_path +
                        (result.error_message.empty() ? " (status " + std::to_string(result.status_code) + ")"
                                                      : ": " + result.error_message),
                    {{"url", file.url}, {"status_code", result.status_code}, {"path", file.relative_path}});
      }

      const int64_t landed = FileSizeOrZero(target);
      if (file.size >= 0 && landed != file.size) {
        if (attempt == kDigestRetries) {
          throw Error(FLM_ERROR_NETWORK,
                      "downloaded " + file.relative_path + " is " + std::to_string(landed) +
                          " bytes, expected " + std::to_string(file.size),
                      {{"path", file.relative_path}, {"expected_bytes", file.size}, {"actual_bytes", landed}});
        }
        continue;
      }

      if (plan.verify_checksums && !file.digest.empty()) {
        const std::string actual = Sha256File(target.string());
        if (!DigestMatches(file.digest, actual)) {
          if (attempt == kDigestRetries) {
            fs::remove(target, ec);
            throw Error(FLM_ERROR_INTERNAL,
                        "checksum mismatch for " + file.relative_path + "; the file was discarded",
                        {{"path", file.relative_path}, {"expected", file.digest}, {"actual", actual}});
          }
          continue;
        }
      }

      downloaded += landed - base_bytes;
      reused += base_bytes;
      succeeded = true;
      report(0, file.relative_path);
    }
  }

  context.ThrowIfCancelled();

  if (plan.layout == DownloadPlan::Layout::kPackage) {
    // Prune the manifest to the variant that was actually fetched, so the directory
    // describes itself accurately instead of advertising variants whose files are absent.
    if (!plan.manifest_override.is_null()) {
      const fs::path manifest_path = destination / "manifest.json";
      std::ofstream out(manifest_path);
      if (!out) {
        throw Error(FLM_ERROR_STORAGE, "cannot write " + manifest_path.string(),
                    {{"path", manifest_path.string()}});
      }
      out << plan.manifest_override.dump(2);
      out.close();
      if (out.fail()) {
        throw Error(FLM_ERROR_STORAGE, "failed to write " + manifest_path.string(),
                    {{"path", manifest_path.string()}});
      }
    }
    if (!fs::exists(destination / "manifest.json", ec)) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "the downloaded package has no manifest.json",
                  {{"path", destination.string()}});
    }
  } else if (!fs::exists(destination / kGenAiConfigFile, ec)) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "the downloaded model has no genai_config.json, so the runtime cannot load it",
                {{"path", destination.string()}});
  }

  WriteInferenceModelJson(plan);

  // Committing. Once the sentinel is gone the catalog's scan will adopt this directory.
  fs::remove(sentinel, ec);
  if (ec) {
    throw Error(FLM_ERROR_STORAGE, "cannot finalize the download: " + ec.message(),
                {{"path", sentinel.string()}});
  }

  context.ReportProgress(100.0f, "downloading", total, total);

  return nlohmann::json{{"path", destination.string()},
                        {"bytes_downloaded", downloaded},
                        {"bytes_reused", reused}};
}

}  // namespace flm
