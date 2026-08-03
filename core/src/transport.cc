// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "transport.h"

#include <algorithm>
#include <cctype>
#include <chrono>

#include "error.h"
#include "job.h"

namespace flm {
namespace {

/// How often a blocked download thread wakes to check for job cancellation. Long enough
/// not to matter for battery, short enough that a user tapping "cancel" sees it act.
constexpr auto kCancelPollInterval = std::chrono::milliseconds(100);

std::string ToLowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return value;
}

}  // namespace

/* --- PendingRequest ----------------------------------------------------- */

void PendingRequest::ReportProgress(int64_t completed, int64_t total) noexcept {
  completed_bytes_.store(completed, std::memory_order_release);
  total_bytes_.store(total, std::memory_order_release);
}

void PendingRequest::AppendBody(const char* data, size_t size) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (finished_) {
    return;
  }
  result_.body.append(data, size);
}

void PendingRequest::Complete(int32_t status_code, const char* headers_json,
                              const char* error_message) noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  if (finished_) {
    // A transport that reports completion twice would otherwise overwrite the real
    // outcome with a spurious one; the first report wins.
    return;
  }

  result_.status_code = status_code;
  if (error_message != nullptr && *error_message != '\0') {
    result_.error_message = error_message;
  }

  if (headers_json != nullptr && *headers_json != '\0') {
    try {
      const auto parsed = nlohmann::json::parse(headers_json);
      if (parsed.is_object()) {
        for (const auto& [key, value] : parsed.items()) {
          if (value.is_string()) {
            result_.headers[ToLowerAscii(key)] = value.get<std::string>();
          }
        }
      }
    } catch (...) {
      // Malformed headers are not worth failing an otherwise-successful download over.
    }
  }

  result_.bytes_written = completed_bytes_.load(std::memory_order_acquire);
  finished_ = true;
  cv_.notify_all();
}

HttpResult PendingRequest::Await(JobContext* context, const std::function<void()>& on_cancel,
                                const std::function<void(int64_t, int64_t)>& on_poll) {
  bool cancel_sent = false;

  std::unique_lock<std::mutex> lock(mutex_);
  while (!finished_) {
    if (context != nullptr && context->IsCancelled() && !cancel_sent) {
      cancel_sent = true;
      // Ask the transport to abort, but keep waiting: the contract is that it always
      // reports completion, and returning early would leave it writing into a
      // destination this thread is about to delete.
      lock.unlock();
      on_cancel();
      lock.lock();
      continue;
    }

    cv_.wait_for(lock, kCancelPollInterval);

    if (on_poll) {
      // Report outside the lock — the callback reaches into the job, which takes its
      // own lock, and holding both invites a lock-order inversion.
      const int64_t completed = completed_bytes_.load(std::memory_order_acquire);
      const int64_t total = total_bytes_.load(std::memory_order_acquire);
      lock.unlock();
      on_poll(completed, total);
      lock.lock();
    }
  }

  HttpResult result = std::move(result_);
  result.cancelled = cancel_sent;
  return result;
}

/* --- Transport ---------------------------------------------------------- */

Transport& Transport::Instance() noexcept {
  // Intentionally leaked: a download may still be in flight during static destruction,
  // and the platform transport could call back into a destroyed registry.
  static Transport* instance = new Transport();
  return *instance;
}

void Transport::Install(const flm_transport* transport) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (transport == nullptr || transport->send == nullptr) {
    installed_ = false;
    transport_ = {};
    return;
  }
  transport_ = *transport;
  installed_ = true;
}

bool Transport::IsInstalled() const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  return installed_;
}

std::shared_ptr<PendingRequest> Transport::Find(uint64_t request_id) const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = pending_.find(request_id);
  return it == pending_.end() ? nullptr : it->second;
}

HttpResult Transport::Fetch(const std::string& url, const std::string& method,
                            const std::map<std::string, std::string>& headers,
                            const std::string& destination_path, int64_t offset, int64_t expected_bytes,
                            JobContext* context, const std::function<void(int64_t, int64_t)>& on_progress) {
  flm_transport transport{};
  uint64_t request_id = 0;
  auto pending = std::make_shared<PendingRequest>(0);

  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!installed_) {
      throw Error(FLM_ERROR_INVALID_STATE,
                  "no HTTP transport is installed; call flm_set_transport() before downloading",
                  {{"url", url}});
    }
    transport = transport_;
    request_id = next_request_id_++;
    pending = std::make_shared<PendingRequest>(request_id);
    pending_[request_id] = pending;
  }

  // Remove the bookkeeping entry no matter how this function exits, including the
  // cancellation throw below.
  struct Cleanup {
    Transport* self;
    uint64_t id;
    ~Cleanup() {
      std::lock_guard<std::mutex> lock(self->mutex_);
      self->pending_.erase(id);
    }
  } cleanup{this, request_id};

  nlohmann::json header_json = nlohmann::json::object();
  for (const auto& [key, value] : headers) {
    header_json[key] = value;
  }
  const std::string header_text = header_json.dump();

  flm_http_request request{};
  request.version = FLM_API_VERSION;
  request.request_id = request_id;
  request.url = url.c_str();
  request.method = method.c_str();
  request.headers_json = header_text.c_str();
  request.destination_path = destination_path.empty() ? nullptr : destination_path.c_str();
  request.offset = offset;
  request.expected_bytes = expected_bytes;

  if (transport.send(&request, transport.user_data) != 0) {
    throw Error(FLM_ERROR_NETWORK, "the transport rejected the request for " + url, {{"url", url}});
  }

  auto cancel = [&transport, request_id]() {
    if (transport.cancel != nullptr) {
      transport.cancel(request_id, transport.user_data);
    }
  };

  HttpResult result = pending->Await(context, cancel, on_progress);
  if (on_progress) {
    // Final counts, so a job doesn't end reporting the second-to-last poll.
    on_progress(pending->completed_bytes(), pending->total_bytes());
  }
  return result;
}

void Transport::ReportProgress(uint64_t request_id, int64_t completed, int64_t total) noexcept {
  if (auto pending = Find(request_id)) {
    pending->ReportProgress(completed, total);
  }
}

void Transport::ReportBody(uint64_t request_id, const char* data, size_t size) noexcept {
  if (data == nullptr || size == 0) {
    return;
  }
  if (auto pending = Find(request_id)) {
    try {
      pending->AppendBody(data, size);
    } catch (...) {
      // Only reachable on allocation failure; the request will fail on its own.
    }
  }
}

void Transport::ReportComplete(uint64_t request_id, int32_t status_code, const char* headers_json,
                               const char* error_message) noexcept {
  if (auto pending = Find(request_id)) {
    pending->Complete(status_code, headers_json, error_message);
  }
}

std::map<std::string, std::string> ParseHeaderObject(const nlohmann::json& value) {
  std::map<std::string, std::string> headers;
  if (value.is_null()) {
    return headers;
  }
  if (!value.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "'headers' must be a JSON object of string values");
  }
  for (const auto& [key, item] : value.items()) {
    if (!item.is_string()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "header '" + key + "' must be a string");
    }
    headers[key] = item.get<std::string>();
  }
  return headers;
}

}  // namespace flm
