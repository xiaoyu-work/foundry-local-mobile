// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// The exported flm_* C ABI (path-only, no catalog/download/transport).

#include "foundry_local_mobile/flm_api.h"

#include <atomic>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

#include "error.h"
#include "handle_table.h"
#include "job.h"
#include "manager.h"
#include "model.h"
#include "runtime.h"
#include "session.h"
#include "third_party/json.h"

namespace {

using namespace flm;  // NOLINT(build/namespaces)

std::atomic<flm_log_callback> g_log_callback{nullptr};
std::atomic<void*> g_log_user_data{nullptr};
std::atomic<flm_log_level> g_log_level{FLM_LOG_WARNING};

char* DuplicateString(const std::string& value) {
  auto* buffer = static_cast<char*>(std::malloc(value.size() + 1));
  if (buffer == nullptr) {
    throw Error(FLM_ERROR_OUT_OF_MEMORY, "out of memory while returning a string");
  }
  std::memcpy(buffer, value.c_str(), value.size() + 1);
  return buffer;
}

char* DuplicateJson(const nlohmann::json& value) { return DuplicateString(value.dump()); }

nlohmann::json ParseJsonOrEmpty(const char* json, const char* what) {
  if (json == nullptr || json[0] == '\0') {
    return nlohmann::json::object();
  }
  try {
    return nlohmann::json::parse(json);
  } catch (const nlohmann::json::exception& e) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, std::string("invalid JSON for ") + what + ": " + e.what());
  }
}

void RequireNonNull(const void* pointer, const char* name) {
  if (pointer == nullptr) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, std::string(name) + " must not be NULL");
  }
}

std::shared_ptr<Manager> ResolveManager(flm_manager handle) {
  return HandleTable::Instance().Get<Manager>(handle, HandleKind::kManager);
}
std::shared_ptr<Model> ResolveModel(flm_model handle) {
  return HandleTable::Instance().Get<Model>(handle, HandleKind::kModel);
}
std::shared_ptr<Session> ResolveSession(flm_session handle) {
  return HandleTable::Instance().Get<Session>(handle, HandleKind::kSession);
}
std::shared_ptr<Job> ResolveJob(flm_job handle) {
  return HandleTable::Instance().Get<Job>(handle, HandleKind::kJob);
}

flm_model RegisterModel(const std::shared_ptr<Model>& model) {
  const flm_model handle = HandleTable::Instance().Add(HandleKind::kModel, model);
  HandleTable::Instance().SetOwner(handle, model->manager()->handle());
  return handle;
}

flm_status SubmitJob(const std::shared_ptr<Manager>& manager, std::string name, Job::Body body,
                     flm_progress_callback on_progress, flm_delta_callback on_delta,
                     flm_completion_callback on_complete, void* user_data, flm_job* out_job) {
  manager->ThrowIfShutdown();

  auto job = std::make_shared<Job>(std::move(name), std::move(body));
  job->SetCallbacks(on_progress, on_delta, on_complete, user_data);

  const flm_job handle = HandleTable::Instance().Add(HandleKind::kJob, job);
  HandleTable::Instance().SetOwner(handle, manager->handle());
  job->SetHandle(handle);

  if (out_job != nullptr) {
    *out_job = handle;
  }

  manager->job_pool().Submit(job);
  return FLM_OK;
}

/// Derive a model name from the directory name when no explicit name is given.
std::string DefaultModelName(const std::string& model_path) {
  std::filesystem::path p(model_path);
  std::string name = p.filename().string();
  if (name.empty() || name == "." || name == "..") {
    name = p.parent_path().filename().string();
  }
  return name.empty() ? "model" : name;
}

}  // namespace

extern "C" {

/* =========================================================================
 * Library-wide
 * ========================================================================= */

const char* FLM_CALL flm_version_string(void) FLM_NOEXCEPT { return FLM_VERSION_STRING; }

uint32_t FLM_CALL flm_api_version(void) FLM_NOEXCEPT { return FLM_API_VERSION; }

const char* FLM_CALL flm_runtime_version_string(void) FLM_NOEXCEPT {
  try {
    return Runtime::Instance().version().c_str();
  } catch (...) {
    return nullptr;
  }
}

void FLM_CALL flm_string_free(char* str) FLM_NOEXCEPT { std::free(str); }

flm_status FLM_CALL flm_set_log_callback(flm_log_callback callback, void* user_data) FLM_NOEXCEPT {
  g_log_user_data.store(user_data, std::memory_order_release);
  g_log_callback.store(callback, std::memory_order_release);
  return FLM_OK;
}

flm_status FLM_CALL flm_set_log_level(flm_log_level level) FLM_NOEXCEPT {
  g_log_level.store(level, std::memory_order_relaxed);
  return FLM_OK;
}

int32_t FLM_CALL flm_is_runtime_available(void) FLM_NOEXCEPT { return Runtime::IsAvailable() ? 1 : 0; }

/* =========================================================================
 * Errors
 * ========================================================================= */

const char* FLM_CALL flm_last_error_message(void) FLM_NOEXCEPT { return LastErrorMessage(); }

const char* FLM_CALL flm_last_error_detail_json(void) FLM_NOEXCEPT { return LastErrorDetailJson(); }

void FLM_CALL flm_clear_last_error(void) FLM_NOEXCEPT { ClearLastError(); }

/* =========================================================================
 * Manager
 * ========================================================================= */

flm_status FLM_CALL flm_manager_create(const char* config_json, flm_manager* out_manager) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_manager, "out_manager");
  *out_manager = FLM_INVALID_HANDLE;

  const nlohmann::json config = ParseJsonOrEmpty(config_json, "config_json");
  auto manager = Manager::Create(config);

  const flm_manager handle = HandleTable::Instance().Add(HandleKind::kManager, manager);
  manager->set_handle(handle);
  HandleTable::Instance().SetOwner(handle, handle);

  *out_manager = handle;
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_manager_shutdown(flm_manager manager) FLM_NOEXCEPT {
  FLM_TRY
  ResolveManager(manager)->Shutdown();
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_manager_release(flm_manager manager) FLM_NOEXCEPT {
  FLM_TRY
  auto instance = HandleTable::Instance().TryGet<Manager>(manager, HandleKind::kManager);
  if (!instance) {
    return FLM_OK;
  }
  instance->Shutdown();
  HandleTable::Instance().RemoveAllOwnedBy(manager);
  HandleTable::Instance().Remove(manager, HandleKind::kManager);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_manager_get_device_profile_json(flm_manager manager, char** out_json) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_json, "out_json");
  *out_json = nullptr;
  *out_json = DuplicateJson(ResolveManager(manager)->device_profile().ToJson());
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_manager_notify_lifecycle(flm_manager manager, flm_lifecycle_event event) FLM_NOEXCEPT {
  FLM_TRY
  ResolveManager(manager)->NotifyLifecycle(event);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_manager_update_settings(flm_manager manager, const char* settings_json) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(settings_json, "settings_json");
  ResolveManager(manager)->UpdateSettings(ParseJsonOrEmpty(settings_json, "settings_json"));
  return FLM_OK;
  FLM_CATCH
}

/* =========================================================================
 * Model loading
 * ========================================================================= */

flm_status FLM_CALL flm_manager_load_model_async(flm_manager manager, const char* model_path,
                                                  const char* options_json,
                                                  flm_progress_callback on_progress,
                                                  flm_completion_callback on_complete,
                                                  void* user_data, flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(model_path, "model_path");
  auto instance = ResolveManager(manager);

  const std::string path_copy = model_path;
  const nlohmann::json options = ParseJsonOrEmpty(options_json, "options_json");

  // Validate synchronously that the path exists.
  {
    std::error_code ec;
    if (!std::filesystem::is_directory(path_copy, ec)) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT,
                  "model_path does not exist or is not a directory: " + path_copy,
                  {{"path", path_copy}});
    }
  }

  const std::string name = DefaultModelName(path_copy);

  return SubmitJob(
      instance, "manager.load_model",
      [instance, path_copy, name, options](JobContext& context) {
        auto model = std::make_shared<Model>(instance, path_copy, name);

        // Load the model through OGA.
        model->Load(options, context);

        // Register with the manager.
        instance->RegisterModel(model);
        const flm_model model_handle = RegisterModel(model);

        // Build result JSON with model metadata.
        nlohmann::json result = model->GetInfo();
        result["model_handle"] = model_handle;
        result["path"] = path_copy;
        return result;
      },
      on_progress, nullptr, on_complete, user_data, out_job);
  FLM_CATCH
}

/* =========================================================================
 * Model
 * ========================================================================= */

flm_status FLM_CALL flm_model_release(flm_model model) FLM_NOEXCEPT {
  FLM_TRY
  HandleTable::Instance().Remove(model, HandleKind::kModel);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_model_get_info_json(flm_model model, char** out_json) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_json, "out_json");
  *out_json = nullptr;
  *out_json = DuplicateJson(ResolveModel(model)->GetInfo());
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_model_is_cached(flm_model model, int32_t* out_cached) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_cached, "out_cached");
  *out_cached = ResolveModel(model)->IsCached() ? 1 : 0;
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_model_is_loaded(flm_model model, int32_t* out_loaded) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_loaded, "out_loaded");
  *out_loaded = ResolveModel(model)->IsLoaded() ? 1 : 0;
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_model_get_path(flm_model model, char** out_path) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_path, "out_path");
  *out_path = nullptr;
  *out_path = DuplicateString(ResolveModel(model)->GetPath());
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_model_load_async(flm_model model, const char* options_json, flm_progress_callback on_progress,
                                         flm_completion_callback on_complete, void* user_data,
                                         flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  auto instance = ResolveModel(model);
  const nlohmann::json options = ParseJsonOrEmpty(options_json, "options_json");

  return SubmitJob(
      instance->manager(), "model.load",
      [instance, options](JobContext& context) { return instance->Load(options, context); }, on_progress, nullptr,
      on_complete, user_data, out_job);
  FLM_CATCH
}

flm_status FLM_CALL flm_model_unload_async(flm_model model, flm_completion_callback on_complete, void* user_data,
                                           flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  auto instance = ResolveModel(model);

  return SubmitJob(
      instance->manager(), "model.unload",
      [instance](JobContext&) {
        instance->Unload();
        return nlohmann::json::object();
      },
      nullptr, nullptr, on_complete, user_data, out_job);
  FLM_CATCH
}

/* =========================================================================
 * Sessions
 * ========================================================================= */

flm_status FLM_CALL flm_session_create(flm_model model, const char* options_json,
                                       flm_session* out_session) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_session, "out_session");
  *out_session = FLM_INVALID_HANDLE;

  auto model_instance = ResolveModel(model);
  const nlohmann::json options = ParseJsonOrEmpty(options_json, "options_json");

  auto session = std::make_shared<Session>(model_instance, options);
  const flm_session handle = HandleTable::Instance().Add(HandleKind::kSession, session);
  HandleTable::Instance().SetOwner(handle, model_instance->manager()->handle());

  *out_session = handle;
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_session_release(flm_session session) FLM_NOEXCEPT {
  FLM_TRY
  HandleTable::Instance().Remove(session, HandleKind::kSession);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_session_set_options(flm_session session, const char* options_json) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(options_json, "options_json");
  ResolveSession(session)->SetOptions(ParseJsonOrEmpty(options_json, "options_json"));
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_session_complete_async(flm_session session, const char* request_json,
                                               flm_delta_callback on_delta, flm_completion_callback on_complete,
                                               void* user_data, flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(request_json, "request_json");
  auto instance = ResolveSession(session);
  const nlohmann::json request = ParseJsonOrEmpty(request_json, "request_json");
  auto manager = instance->model()->manager();

  return SubmitJob(
      manager, "session.complete",
      [instance, request](JobContext& context) { return instance->Complete(request, context); }, nullptr, on_delta,
      on_complete, user_data, out_job);
  FLM_CATCH
}

flm_status FLM_CALL flm_session_submit_tool_results_async(flm_session session, const char* tool_results_json,
                                                          flm_delta_callback on_delta,
                                                          flm_completion_callback on_complete, void* user_data,
                                                          flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(tool_results_json, "tool_results_json");
  auto instance = ResolveSession(session);

  const nlohmann::json results = nlohmann::json::parse(tool_results_json, nullptr, false);
  if (results.is_discarded() || !results.is_array()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "tool_results_json must be a JSON array");
  }
  auto manager = instance->model()->manager();

  return SubmitJob(
      manager, "session.submit_tool_results",
      [instance, results](JobContext& context) { return instance->SubmitToolResults(results, context); }, nullptr,
      on_delta, on_complete, user_data, out_job);
  FLM_CATCH
}

flm_status FLM_CALL flm_session_transcribe_async(flm_session session, const char* request_json,
                                                 flm_delta_callback on_delta, flm_completion_callback on_complete,
                                                 void* user_data, flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  auto instance = ResolveSession(session);
  const nlohmann::json request = ParseJsonOrEmpty(request_json, "request_json");
  auto manager = instance->model()->manager();

  return SubmitJob(
      manager, "session.transcribe",
      [instance, request](JobContext& context) { return instance->Transcribe(request, context); }, nullptr, on_delta,
      on_complete, user_data, out_job);
  FLM_CATCH
}

flm_status FLM_CALL flm_session_push_audio(flm_session session, const void* pcm_data, size_t byte_count,
                                           int32_t sample_rate, int32_t channels, int32_t is_final) FLM_NOEXCEPT {
  FLM_TRY
  ResolveSession(session)->PushAudio(pcm_data, byte_count, sample_rate, channels, is_final != 0);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_session_embed_async(flm_session session, const char* request_json,
                                            flm_completion_callback on_complete, void* user_data,
                                            flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(request_json, "request_json");
  auto instance = ResolveSession(session);
  const nlohmann::json request = ParseJsonOrEmpty(request_json, "request_json");
  auto manager = instance->model()->manager();

  return SubmitJob(
      manager, "session.embed", [instance, request](JobContext& context) { return instance->Embed(request, context); },
      nullptr, nullptr, on_complete, user_data, out_job);
  FLM_CATCH
}

flm_status FLM_CALL flm_session_get_turn_count(flm_session session, size_t* out_count) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_count, "out_count");
  *out_count = ResolveSession(session)->GetTurnCount();
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_session_undo_turns(flm_session session, size_t count) FLM_NOEXCEPT {
  FLM_TRY
  ResolveSession(session)->UndoTurns(count);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_session_clear_history(flm_session session) FLM_NOEXCEPT {
  FLM_TRY
  ResolveSession(session)->ClearHistory();
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_session_export_history_json(flm_session session, char** out_json) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_json, "out_json");
  *out_json = nullptr;
  *out_json = DuplicateJson(ResolveSession(session)->ExportHistory());
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_session_restore_history_json(flm_session session, const char* history_json) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(history_json, "history_json");
  ResolveSession(session)->RestoreHistory(ParseJsonOrEmpty(history_json, "history_json"));
  return FLM_OK;
  FLM_CATCH
}

/* =========================================================================
 * Jobs
 * ========================================================================= */

flm_status FLM_CALL flm_job_get_state(flm_job job, flm_job_state* out_state) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_state, "out_state");
  *out_state = ResolveJob(job)->state();
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_job_cancel(flm_job job) FLM_NOEXCEPT {
  FLM_TRY
  ResolveJob(job)->Cancel();
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_job_take_result_json(flm_job job, char** out_json) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_json, "out_json");
  *out_json = nullptr;

  auto instance = ResolveJob(job);
  auto result = instance->TakeResult();
  if (!result) {
    if (instance->state() == FLM_JOB_PENDING || instance->state() == FLM_JOB_RUNNING) {
      throw Error(FLM_ERROR_INVALID_STATE, "the job has not finished yet");
    }
    instance->ThrowIfFailed();
    throw Error(FLM_ERROR_INVALID_STATE, "the job's result has already been taken");
  }
  *out_json = DuplicateString(*result);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_job_release(flm_job job) FLM_NOEXCEPT {
  FLM_TRY
  HandleTable::Instance().Remove(job, HandleKind::kJob);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_job_wait(flm_job job, int32_t timeout_ms) FLM_NOEXCEPT {
  FLM_TRY
  if (!ResolveJob(job)->Wait(timeout_ms)) {
    return SetLastError(FLM_ERROR_TIMEOUT, "timed out waiting for the job",
                        {{"timeout_ms", timeout_ms}});
  }
  return FLM_OK;
  FLM_CATCH
}

}  // extern "C"

namespace flm {

void EmitLog(flm_log_level level, const char* tag, const char* message) noexcept {
  if (level < g_log_level.load(std::memory_order_relaxed)) {
    return;
  }
  const flm_log_callback callback = g_log_callback.load(std::memory_order_acquire);
  if (callback == nullptr) {
    return;
  }
  callback(level, tag != nullptr ? tag : "flm", message != nullptr ? message : "",
           g_log_user_data.load(std::memory_order_acquire));
}

}  // namespace flm
