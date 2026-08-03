// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Asynchronous job infrastructure.
//
// Every operation that can exceed a few milliseconds runs here rather than on the
// caller's thread, because on Android and iOS a blocked UI thread is an ANR or a
// watchdog kill. Bindings map a Job onto a coroutine, a Swift continuation, a Dart
// Future or a JS Promise; cancellation, progress and completion work identically for
// all four.

#ifndef FOUNDRY_LOCAL_MOBILE_JOB_H_
#define FOUNDRY_LOCAL_MOBILE_JOB_H_

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "error.h"
#include "foundry_local_mobile/flm_types.h"
#include "third_party/json.h"

namespace flm {

class Job;

/// Passed to job bodies so they can report progress and check for cancellation without
/// knowing anything about the ABI callbacks behind them.
class JobContext {
 public:
  explicit JobContext(Job& job) : job_(job) {}

  /// True once cancellation has been requested. Long loops must poll this.
  bool IsCancelled() const noexcept;

  /// Throw Error(FLM_ERROR_CANCELLED) if cancellation was requested. Call at safe points.
  void ThrowIfCancelled() const;

  /// Report progress. `percent` is clamped to [0, 100]. Byte counters may be
  /// FLM_UNKNOWN_SIZE. Rate and ETA are derived automatically from the byte counters.
  void ReportProgress(float percent, const std::string& stage, int64_t completed_bytes = FLM_UNKNOWN_SIZE,
                      int64_t total_bytes = FLM_UNKNOWN_SIZE, const std::string& detail = {});

  /// Emit a streaming delta to the job's delta callback, if one was supplied.
  /// Returns false if the consumer requested cancellation.
  bool EmitDelta(const flm_delta& delta);

  Job& job() noexcept { return job_; }

 private:
  Job& job_;
};

/// A unit of asynchronous work with progress, streaming and cancellation.
class Job : public std::enable_shared_from_this<Job> {
 public:
  using Body = std::function<nlohmann::json(JobContext&)>;

  Job(std::string name, Body body);
  ~Job();

  Job(const Job&) = delete;
  Job& operator=(const Job&) = delete;

  /// Wire up the ABI callbacks. Must be called before the job is submitted.
  void SetCallbacks(flm_progress_callback on_progress, flm_delta_callback on_delta,
                    flm_completion_callback on_complete, void* user_data);

  /// The handle used to identify this job across the ABI. Set at registration time.
  void SetHandle(flm_job handle) noexcept { handle_ = handle; }
  flm_job handle() const noexcept { return handle_; }

  const std::string& name() const noexcept { return name_; }
  flm_job_state state() const noexcept { return state_.load(std::memory_order_acquire); }

  /// Request cancellation. Safe from any thread, including a callback.
  void Cancel() noexcept;
  bool IsCancelRequested() const noexcept { return cancel_requested_.load(std::memory_order_acquire); }

  /// Block until the job reaches a terminal state. `timeout_ms < 0` waits forever.
  /// Returns false on timeout.
  bool Wait(int32_t timeout_ms);

  /// Take the result JSON, transferring ownership. Empty after the first call.
  std::optional<std::string> TakeResult();

  /// Run the body inline on the calling thread. Called by the pool worker.
  void Execute();

 private:
  friend class JobContext;

  void Finish(flm_status status, nlohmann::json result, const std::string& error_message,
              const nlohmann::json& error_context);

  std::string name_;
  Body body_;
  flm_job handle_ = FLM_INVALID_HANDLE;

  std::atomic<flm_job_state> state_{FLM_JOB_PENDING};
  std::atomic<bool> cancel_requested_{false};

  flm_progress_callback on_progress_ = nullptr;
  flm_delta_callback on_delta_ = nullptr;
  flm_completion_callback on_complete_ = nullptr;
  void* user_data_ = nullptr;

  mutable std::mutex mutex_;
  std::condition_variable finished_cv_;
  bool finished_ = false;
  std::optional<std::string> result_json_;

  // Progress rate estimation state, guarded by mutex_.
  int64_t last_progress_bytes_ = 0;
  std::chrono::steady_clock::time_point last_progress_time_{};
  double smoothed_bytes_per_second_ = 0.0;
};

/// Fixed-size worker pool. Sized conservatively on mobile: model downloads and inference
/// are I/O- and accelerator-bound, and extra threads mostly add memory and scheduler
/// pressure on a phone.
class JobPool {
 public:
  /// `thread_count == 0` derives a sensible value from the core count (2–4).
  explicit JobPool(size_t thread_count = 0);
  ~JobPool();

  JobPool(const JobPool&) = delete;
  JobPool& operator=(const JobPool&) = delete;

  void Submit(std::shared_ptr<Job> job);

  /// Cancel everything queued or running, then stop the workers. Idempotent.
  void Shutdown();

  bool IsShuttingDown() const noexcept { return shutting_down_.load(std::memory_order_acquire); }

  size_t PendingCount() const noexcept;

 private:
  void WorkerLoop();

  std::vector<std::thread> workers_;
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<std::shared_ptr<Job>> queue_;
  std::vector<std::weak_ptr<Job>> running_;
  std::atomic<bool> shutting_down_{false};
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_JOB_H_
