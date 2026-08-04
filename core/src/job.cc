// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "job.h"

#include <algorithm>
#include <chrono>

namespace flm {
namespace {

constexpr double kRateSmoothingFactor = 0.3;  // EWMA weight for new rate samples.

}  // namespace

/* ------------------------------------------------------------------------- */
/* JobContext                                                                 */
/* ------------------------------------------------------------------------- */

bool JobContext::IsCancelled() const noexcept { return job_.IsCancelRequested(); }

void JobContext::ThrowIfCancelled() const {
  if (job_.IsCancelRequested()) {
    throw Error(FLM_ERROR_CANCELLED, "operation cancelled");
  }
}

void JobContext::ReportProgress(float percent, const std::string& stage, int64_t completed_bytes, int64_t total_bytes,
                                const std::string& detail) {
  if (job_.on_progress_ == nullptr) {
    return;
  }

  int64_t bytes_per_second = FLM_UNKNOWN_SIZE;
  int64_t eta_ms = FLM_UNKNOWN_SIZE;

  if (completed_bytes >= 0) {
    const auto now = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(job_.mutex_);
    if (job_.last_progress_time_.time_since_epoch().count() != 0) {
      const auto elapsed = std::chrono::duration<double>(now - job_.last_progress_time_).count();
      const int64_t delta_bytes = completed_bytes - job_.last_progress_bytes_;
      // Ignore sub-100ms samples: they produce wildly noisy rates that make UI
      // estimates jitter.
      if (elapsed > 0.1 && delta_bytes >= 0) {
        const double instant_rate = static_cast<double>(delta_bytes) / elapsed;
        job_.smoothed_bytes_per_second_ = job_.smoothed_bytes_per_second_ == 0.0
                                              ? instant_rate
                                              : kRateSmoothingFactor * instant_rate +
                                                    (1.0 - kRateSmoothingFactor) * job_.smoothed_bytes_per_second_;
        job_.last_progress_bytes_ = completed_bytes;
        job_.last_progress_time_ = now;
      }
    } else {
      job_.last_progress_bytes_ = completed_bytes;
      job_.last_progress_time_ = now;
    }

    if (job_.smoothed_bytes_per_second_ > 1.0) {
      bytes_per_second = static_cast<int64_t>(job_.smoothed_bytes_per_second_);
      if (total_bytes > completed_bytes) {
        eta_ms = static_cast<int64_t>((static_cast<double>(total_bytes - completed_bytes) /
                                       job_.smoothed_bytes_per_second_) * 1000.0);
      }
    }
  }

  flm_progress progress{};
  progress.version = FLM_API_VERSION;
  progress.percent = std::clamp(percent, 0.0f, 100.0f);
  progress.completed_bytes = completed_bytes;
  progress.total_bytes = total_bytes;
  progress.bytes_per_second = bytes_per_second;
  progress.eta_ms = eta_ms;
  progress.stage = stage.c_str();
  progress.detail = detail.empty() ? nullptr : detail.c_str();

  if (job_.on_progress_(job_.handle_, &progress, job_.user_data_) != 0) {
    job_.Cancel();
  }
}

bool JobContext::EmitDelta(const flm_delta& delta) {
  if (job_.on_delta_ == nullptr) {
    return !job_.IsCancelRequested();
  }
  if (job_.on_delta_(job_.handle_, &delta, job_.user_data_) != 0) {
    job_.Cancel();
    return false;
  }
  return !job_.IsCancelRequested();
}

/* ------------------------------------------------------------------------- */
/* Job                                                                        */
/* ------------------------------------------------------------------------- */

Job::Job(std::string name, Body body) : name_(std::move(name)), body_(std::move(body)) {}

Job::~Job() = default;

void Job::SetCallbacks(flm_progress_callback on_progress, flm_delta_callback on_delta,
                       flm_completion_callback on_complete, void* user_data) {
  on_progress_ = on_progress;
  on_delta_ = on_delta;
  on_complete_ = on_complete;
  user_data_ = user_data;
}

void Job::Cancel() noexcept {
  cancel_requested_.store(true, std::memory_order_release);

  // A job that never started can be completed immediately — no worker will ever pick it
  // up in a state where it could report its own cancellation.
  flm_job_state expected = FLM_JOB_PENDING;
  if (state_.compare_exchange_strong(expected, FLM_JOB_CANCELLED, std::memory_order_acq_rel)) {
    try {
      Finish(FLM_ERROR_CANCELLED, nlohmann::json(), "operation cancelled", nlohmann::json::object());
    } catch (...) {
      // Finish only throws if a user callback throws, which is a contract violation.
    }
  }
}

void Job::Execute() {
  flm_job_state expected = FLM_JOB_PENDING;
  if (!state_.compare_exchange_strong(expected, FLM_JOB_RUNNING, std::memory_order_acq_rel)) {
    return;  // Already cancelled before it started.
  }

  JobContext context(*this);
  try {
    nlohmann::json result = body_(context);
    if (cancel_requested_.load(std::memory_order_acquire)) {
      state_.store(FLM_JOB_CANCELLED, std::memory_order_release);
      Finish(FLM_ERROR_CANCELLED, nlohmann::json(), "operation cancelled", nlohmann::json::object());
      return;
    }
    state_.store(FLM_JOB_SUCCEEDED, std::memory_order_release);
    Finish(FLM_OK, std::move(result), {}, nlohmann::json::object());
  } catch (const Error& e) {
    const bool cancelled = e.status() == FLM_ERROR_CANCELLED;
    state_.store(cancelled ? FLM_JOB_CANCELLED : FLM_JOB_FAILED, std::memory_order_release);
    Finish(e.status(), nlohmann::json(), e.message(), e.context());
  } catch (const std::exception& e) {
    state_.store(FLM_JOB_FAILED, std::memory_order_release);
    Finish(FLM_ERROR_INTERNAL, nlohmann::json(), e.what(), nlohmann::json::object());
  } catch (...) {
    state_.store(FLM_JOB_FAILED, std::memory_order_release);
    Finish(FLM_ERROR_INTERNAL, nlohmann::json(), "unknown failure", nlohmann::json::object());
  }
}

void Job::Finish(flm_status status, nlohmann::json result, const std::string& error_message,
                 const nlohmann::json& error_context) {
  std::string error_json;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (finished_) {
      return;  // Cancel() racing with Execute() completing normally.
    }
    finished_ = true;
    if (status == FLM_OK && !result.is_null()) {
      result_json_ = result.dump();
    }
    if (status != FLM_OK) {
      status_ = status;
      error_message_ = error_message;
      error_context_ = error_context;
      error_json = MakeErrorJson(status, error_message, error_context).dump();
    }
  }
  finished_cv_.notify_all();

  // Invoke the completion callback outside the lock: bindings commonly release the job
  // or start another one from inside it.
  if (on_complete_ != nullptr) {
    on_complete_(handle_, status, error_json.empty() ? nullptr : error_json.c_str(), user_data_);
  }
}

bool Job::Wait(int32_t timeout_ms) {
  std::unique_lock<std::mutex> lock(mutex_);
  if (timeout_ms < 0) {
    finished_cv_.wait(lock, [this] { return finished_; });
    return true;
  }
  return finished_cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms), [this] { return finished_; });
}

std::optional<std::string> Job::TakeResult() {
  std::lock_guard<std::mutex> lock(mutex_);
  auto result = std::move(result_json_);
  result_json_.reset();
  return result;
}

void Job::ThrowIfFailed() const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (status_ != FLM_OK) {
    throw Error(status_, error_message_, error_context_);
  }
}

/* ------------------------------------------------------------------------- */
/* JobPool                                                                    */
/* ------------------------------------------------------------------------- */

JobPool::JobPool(size_t thread_count) {
  if (thread_count == 0) {
    // Phones are thermally constrained and this work is I/O- or NPU-bound; more threads
    // buy nothing and cost memory. Two to four is the useful range.
    const unsigned hardware = std::max(1u, std::thread::hardware_concurrency());
    thread_count = std::clamp<size_t>(hardware / 2, 2, 4);
  }
  workers_.reserve(thread_count);
  for (size_t i = 0; i < thread_count; ++i) {
    workers_.emplace_back([this] { WorkerLoop(); });
  }
}

JobPool::~JobPool() { Shutdown(); }

void JobPool::Submit(std::shared_ptr<Job> job) {
  if (shutting_down_.load(std::memory_order_acquire)) {
    throw Error(FLM_ERROR_SHUTDOWN, "manager is shutting down; no new work accepted");
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.push_back(std::move(job));
  }
  cv_.notify_one();
}

void JobPool::WorkerLoop() {
  for (;;) {
    std::shared_ptr<Job> job;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      cv_.wait(lock, [this] { return !queue_.empty() || shutting_down_.load(std::memory_order_acquire); });
      if (queue_.empty()) {
        return;  // Shutting down and drained.
      }
      job = std::move(queue_.front());
      queue_.pop_front();

      // Track it weakly so Shutdown can cancel in-flight work without extending its life.
      running_.erase(std::remove_if(running_.begin(), running_.end(),
                                    [](const std::weak_ptr<Job>& w) { return w.expired(); }),
                     running_.end());
      running_.push_back(job);
    }
    job->Execute();
  }
}

void JobPool::Shutdown() {
  if (shutting_down_.exchange(true, std::memory_order_acq_rel)) {
    return;
  }

  std::vector<std::shared_ptr<Job>> to_cancel;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Queued jobs must still get their completion callback, or a binding's coroutine
    // waits forever. Cancelling delivers FLM_ERROR_CANCELLED to each.
    for (auto& job : queue_) {
      to_cancel.push_back(job);
    }
    queue_.clear();
    for (auto& weak : running_) {
      if (auto job = weak.lock()) {
        to_cancel.push_back(std::move(job));
      }
    }
    running_.clear();
  }
  for (auto& job : to_cancel) {
    job->Cancel();
  }

  cv_.notify_all();
  for (auto& worker : workers_) {
    if (worker.joinable()) {
      worker.join();
    }
  }
  workers_.clear();
}

size_t JobPool::PendingCount() const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  return queue_.size();
}

}  // namespace flm
