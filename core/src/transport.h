// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// HTTP transport bridge.
//
// The core plans downloads but never performs them. It decides which manifest to read,
// which variant fits this device, which files that implies and what each must hash to;
// the platform binding moves the bytes.
//
// The split is forced by mobile reality. A model download is hundreds of megabytes to
// several gigabytes, so it must survive the app being backgrounded, and the only APIs
// that can do that are URLSession background sessions on Apple platforms and
// WorkManager/DownloadManager on Android — both of which hand the transfer to a system
// daemon that keeps running after the process is suspended. A socket loop inside C++ is
// suspended with the process and then killed. Delegating also means the app's
// certificate pinning, proxy settings, Android Network Security Config and per-app VPN
// rules apply for free, and credentials stay in the app's own code where they can be
// refreshed, rather than being marshalled across the ABI on every retry.

#ifndef FOUNDRY_LOCAL_MOBILE_TRANSPORT_H_
#define FOUNDRY_LOCAL_MOBILE_TRANSPORT_H_

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <functional>
#include <unordered_map>
#include <vector>

#include "foundry_local_mobile/flm_types.h"
#include "third_party/json.h"

namespace flm {

class JobContext;

/// Outcome of a single HTTP exchange.
struct HttpResult {
  int32_t status_code = 0;
  std::string body;                             ///< Populated only for in-memory requests.
  std::map<std::string, std::string> headers;   ///< Lowercased response header names.
  int64_t bytes_written = 0;                    ///< For file requests.
  bool cancelled = false;
  std::string error_message;                    ///< Non-empty when the transport failed outright.

  bool ok() const noexcept { return error_message.empty() && status_code >= 200 && status_code < 300; }
};

/// One pending exchange. Owned by the registry until the transport reports completion.
class PendingRequest {
 public:
  explicit PendingRequest(uint64_t id) : id_(id) {}

  uint64_t id() const noexcept { return id_; }

  void ReportProgress(int64_t completed, int64_t total) noexcept;
  void AppendBody(const char* data, size_t size);
  void Complete(int32_t status_code, const char* headers_json, const char* error_message) noexcept;

  /// Block until the transport reports completion, polling `context` for cancellation.
  /// `on_poll` is invoked on each wakeup so the caller can relay byte counts to its job.
  /// Returns the result; on cancellation the transport is asked to abort first.
  HttpResult Await(JobContext* context, const std::function<void()>& on_cancel,
                   const std::function<void(int64_t, int64_t)>& on_poll = {});

  int64_t completed_bytes() const noexcept { return completed_bytes_.load(std::memory_order_acquire); }
  int64_t total_bytes() const noexcept { return total_bytes_.load(std::memory_order_acquire); }

 private:
  const uint64_t id_;

  std::mutex mutex_;
  std::condition_variable cv_;
  bool finished_ = false;
  HttpResult result_;

  std::atomic<int64_t> completed_bytes_{0};
  std::atomic<int64_t> total_bytes_{FLM_UNKNOWN_SIZE};
};

/// Process-wide transport registry.
class Transport {
 public:
  static Transport& Instance() noexcept;

  /// Install the platform transport. Passing a null struct clears it.
  void Install(const flm_transport* transport);

  bool IsInstalled() const noexcept;

  /// Perform a request, blocking the calling job thread until it completes.
  ///
  /// `destination_path` empty means "give me the body in memory" — only ever used for
  /// manifests, which are small. Model files always stream to disk so a multi-gigabyte
  /// download never has to be resident.
  HttpResult Fetch(const std::string& url, const std::string& method,
                   const std::map<std::string, std::string>& headers, const std::string& destination_path,
                   int64_t offset, int64_t expected_bytes, JobContext* context,
                   const std::function<void(int64_t, int64_t)>& on_progress = {});

  /* Entry points called by the platform, via the flm_transport_report_* exports. */
  void ReportProgress(uint64_t request_id, int64_t completed, int64_t total) noexcept;
  void ReportBody(uint64_t request_id, const char* data, size_t size) noexcept;
  void ReportComplete(uint64_t request_id, int32_t status_code, const char* headers_json,
                      const char* error_message) noexcept;

 private:
  Transport() = default;

  std::shared_ptr<PendingRequest> Find(uint64_t request_id) const noexcept;

  mutable std::mutex mutex_;
  flm_transport transport_{};
  bool installed_ = false;
  uint64_t next_request_id_ = 1;
  std::unordered_map<uint64_t, std::shared_ptr<PendingRequest>> pending_;
};

/// Parse a JSON object of headers into a map, rejecting non-string values.
std::map<std::string, std::string> ParseHeaderObject(const nlohmann::json& value);

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_TRANSPORT_H_
