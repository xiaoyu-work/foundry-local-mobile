// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// The exported flm_* C ABI.
//
// Every function here is a thin, noexcept shell: validate arguments, resolve handles,
// delegate to the core, and translate any exception into a status code. Nothing else
// belongs in this file — the moment logic leaks in here it becomes untestable from C++
// and invisible to the bindings.

#include "foundry_local_mobile/flm_api.h"

#include <atomic>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "catalog.h"
#include "error.h"
#include "handle_table.h"
#include "job.h"
#include "manager.h"
#include "model.h"
#include "model_source.h"
#include "runtime.h"
#include "session.h"
#include "transport.h"
#include "third_party/json.h"

namespace {

using namespace flm;  // NOLINT(build/namespaces) — this file exists to expose flm to C.

std::atomic<flm_log_callback> g_log_callback{nullptr};
std::atomic<void*> g_log_user_data{nullptr};
std::atomic<flm_log_level> g_log_level{FLM_LOG_WARNING};

/// Copy a std::string into a caller-freed C buffer.
/// Allocated with std::malloc so flm_string_free can use std::free, keeping the
/// allocation symmetric across every binding that might route through it.
char* DuplicateString(const std::string& value) {
  auto* buffer = static_cast<char*>(std::malloc(value.size() + 1));
  if (buffer == nullptr) {
    throw Error(FLM_ERROR_OUT_OF_MEMORY, "out of memory while returning a string");
  }
  std::memcpy(buffer, value.c_str(), value.size() + 1);
  return buffer;
}

char* DuplicateJson(const nlohmann::json& value) { return DuplicateString(value.dump()); }

/// Parse an optional JSON argument. NULL and "" both mean "no value", which lets every
/// binding pass a null string without special-casing.
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

/// Reject a versioned struct this build cannot interpret. A binding compiled against a
/// newer header may set fields past the end of what this core knows about, so reading it
/// would be undefined; a version older than the current one is fine, since fields are
/// only ever appended.
void RequireVersion(uint32_t version, const char* name) {
  if (version == 0 || version > FLM_API_VERSION) {
    throw Error(FLM_ERROR_UNSUPPORTED_VERSION,
                std::string(name) + " reports version " + std::to_string(version) + ", but this build supports " +
                    std::to_string(FLM_API_VERSION),
                {{"struct", name}, {"version", version}, {"supported_version", FLM_API_VERSION}});
  }
}

std::shared_ptr<Manager> ResolveManager(flm_manager handle) {
  return HandleTable::Instance().Get<Manager>(handle, HandleKind::kManager);
}
std::shared_ptr<Catalog> ResolveCatalog(flm_catalog handle) {
  return HandleTable::Instance().Get<Catalog>(handle, HandleKind::kCatalog);
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

/// Register a model and tie its lifetime to its manager, so releasing the manager
/// invalidates it instead of leaving a handle pointing at freed runtime state.
flm_model RegisterModel(const std::shared_ptr<Model>& model) {
  const flm_model handle = HandleTable::Instance().Add(HandleKind::kModel, model);
  HandleTable::Instance().SetOwner(handle, model->manager()->handle());
  return handle;
}

/// Create, register and submit a job.
///
/// The job handle is registered *before* submission so a completion callback that fires
/// immediately still sees a valid handle. `out_job` may be NULL for fire-and-forget work.
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
    // Documented to return NULL rather than fail: callers use it to decide whether to
    // prompt for a runtime download.
    return nullptr;
  }
}

void FLM_CALL flm_string_free(char* str) FLM_NOEXCEPT { std::free(str); }

flm_status FLM_CALL flm_set_log_callback(flm_log_callback callback, void* user_data) FLM_NOEXCEPT {
  // Order matters: publish the user data before the callback, so a concurrent log call
  // can never pair a new callback with stale user data.
  g_log_user_data.store(user_data, std::memory_order_release);
  g_log_callback.store(callback, std::memory_order_release);
  return FLM_OK;
}

flm_status FLM_CALL flm_set_log_level(flm_log_level level) FLM_NOEXCEPT {
  g_log_level.store(level, std::memory_order_relaxed);
  return FLM_OK;
}

flm_status FLM_CALL flm_set_runtime_library_path(const char* path) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(path, "path");
  Runtime::SetLibraryPath(path);
  return FLM_OK;
  FLM_CATCH
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
  // A manager owns itself so RemoveAllOwnedBy sweeps derived handles uniformly.
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
    return FLM_OK;  // Releasing twice is not an error; bindings often have two owners.
  }
  instance->Shutdown();

  // Drop derived handles first. Otherwise a session or model handle would outlive the
  // runtime state it points at, and using it would be a use-after-free rather than a
  // clean FLM_ERROR_INVALID_HANDLE.
  HandleTable::Instance().RemoveAllOwnedBy(manager);
  HandleTable::Instance().Remove(manager, HandleKind::kManager);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_manager_get_catalog(flm_manager manager, flm_catalog* out_catalog) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_catalog, "out_catalog");
  *out_catalog = FLM_INVALID_HANDLE;

  auto instance = ResolveManager(manager);
  auto catalog = instance->catalog();

  const flm_catalog handle = HandleTable::Instance().Add(HandleKind::kCatalog, catalog);
  HandleTable::Instance().SetOwner(handle, manager);
  *out_catalog = handle;
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
 * Model sources
 * ========================================================================= */

flm_status FLM_CALL flm_set_transport(const flm_transport* transport) FLM_NOEXCEPT {
  FLM_TRY
  if (transport != nullptr) {
    RequireVersion(transport->version, "flm_transport");
    if (transport->send == nullptr) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "flm_transport.send must not be NULL");
    }
  }
  Transport::Instance().Install(transport);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_transport_report_progress(uint64_t request_id, int64_t completed_bytes,
                                                  int64_t total_bytes) FLM_NOEXCEPT {
  FLM_TRY
  Transport::Instance().ReportProgress(request_id, completed_bytes, total_bytes);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_transport_report_body(uint64_t request_id, const char* data, size_t size) FLM_NOEXCEPT {
  FLM_TRY
  Transport::Instance().ReportBody(request_id, data, size);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_transport_report_complete(uint64_t request_id, int32_t status_code,
                                                  const char* headers_json,
                                                  const char* error_message) FLM_NOEXCEPT {
  FLM_TRY
  Transport::Instance().ReportComplete(request_id, status_code, headers_json, error_message);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_manager_add_model_source_async(flm_manager manager, const char* source_json,
                                                       flm_progress_callback on_progress,
                                                       flm_completion_callback on_complete, void* user_data,
                                                       flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(source_json, "source_json");
  auto instance = ResolveManager(manager);

  // Parse before submitting so a malformed descriptor fails synchronously, where the
  // caller can see it, rather than as an asynchronous job failure.
  const ModelSource source = ModelSource::FromJson(ParseJsonOrEmpty(source_json, "source_json"));

  return SubmitJob(
      instance, "manager.add_model_source",
      [instance, source](JobContext& context) {
        nlohmann::json result = ModelSourceResolver(instance).Resolve(source, context);

        // Hand back a usable model, not just a path. The files are on disk now, so the
        // catalog's local scan will find them; resolving here saves every binding an
        // extra async round-trip through flm_catalog_get_model_async just to reach the
        // model it explicitly asked for.
        //
        // This is strictly a convenience, so nothing it does may fail the job: the bytes
        // are already committed to disk, and reporting a completed download as a failure
        // would send the caller back to re-fetch hundreds of megabytes, potentially over
        // a metered connection. Any failure here just means no handle.
        try {
          if (auto model = instance->catalog()->GetModel(result.value("name", std::string()))) {
            result["model_handle"] = RegisterModel(model);
          }
        } catch (...) {
          // Left absent below.
        }
        if (!result.contains("model_handle")) {
          result["model_handle"] = FLM_INVALID_HANDLE;
        }
        return result;
      },
      on_progress, nullptr, on_complete, user_data, out_job);
  FLM_CATCH
}

/* =========================================================================
 * Catalog
 * ========================================================================= */

flm_status FLM_CALL flm_catalog_list_models_async(flm_catalog catalog, const char* filter_json,
                                                  flm_completion_callback on_complete, void* user_data,
                                                  flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  auto instance = ResolveCatalog(catalog);
  const nlohmann::json filter = ParseJsonOrEmpty(filter_json, "filter_json");

  return SubmitJob(
      instance->manager(), "catalog.list_models",
      [instance, filter](JobContext& context) { return instance->ListModels(filter, context); }, nullptr, nullptr,
      on_complete, user_data, out_job);
  FLM_CATCH
}

flm_status FLM_CALL flm_catalog_get_model_async(flm_catalog catalog, const char* alias,
                                                flm_completion_callback on_complete, void* user_data,
                                                flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(alias, "alias");
  auto instance = ResolveCatalog(catalog);
  const std::string alias_copy = alias;

  return SubmitJob(
      instance->manager(), "catalog.get_model",
      [instance, alias_copy](JobContext&) {
        auto model = instance->GetModel(alias_copy);
        return nlohmann::json{{"model_handle", RegisterModel(model)}};
      },
      nullptr, nullptr, on_complete, user_data, out_job);
  FLM_CATCH
}

flm_status FLM_CALL flm_catalog_get_model_by_id_async(flm_catalog catalog, const char* model_id,
                                                      flm_completion_callback on_complete, void* user_data,
                                                      flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(model_id, "model_id");
  auto instance = ResolveCatalog(catalog);
  const std::string id_copy = model_id;

  return SubmitJob(
      instance->manager(), "catalog.get_model_by_id",
      [instance, id_copy](JobContext&) {
        auto model = instance->GetModelById(id_copy);
        return nlohmann::json{{"model_handle", RegisterModel(model)}};
      },
      nullptr, nullptr, on_complete, user_data, out_job);
  FLM_CATCH
}

flm_status FLM_CALL flm_catalog_list_cached_models_json(flm_catalog catalog, char** out_json) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_json, "out_json");
  *out_json = nullptr;
  *out_json = DuplicateJson(ResolveCatalog(catalog)->ListCachedModels());
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_catalog_get_cache_size_bytes(flm_catalog catalog, int64_t* out_bytes) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_bytes, "out_bytes");
  *out_bytes = ResolveCatalog(catalog)->GetCacheSizeBytes();
  return FLM_OK;
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

flm_status FLM_CALL flm_model_download_async(flm_model model, const char* options_json,
                                             flm_progress_callback on_progress, flm_completion_callback on_complete,
                                             void* user_data, flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  auto instance = ResolveModel(model);
  const nlohmann::json options = ParseJsonOrEmpty(options_json, "options_json");

  return SubmitJob(
      instance->manager(), "model.download",
      [instance, options](JobContext& context) { return instance->Download(options, context); }, on_progress, nullptr,
      on_complete, user_data, out_job);
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

flm_status FLM_CALL flm_model_delete_async(flm_model model, flm_completion_callback on_complete, void* user_data,
                                           flm_job* out_job) FLM_NOEXCEPT {
  FLM_TRY
  auto instance = ResolveModel(model);

  return SubmitJob(
      instance->manager(), "model.delete",
      [instance](JobContext&) {
        instance->Delete();
        return nlohmann::json::object();
      },
      nullptr, nullptr, on_complete, user_data, out_job);
  FLM_CATCH
}

/* =========================================================================
 * Model packages
 * ========================================================================= */

flm_status FLM_CALL flm_model_is_package(flm_model model, int32_t* out_is_package) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_is_package, "out_is_package");
  *out_is_package = ResolveModel(model)->IsPackage() ? 1 : 0;
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_package_get_variants_json(flm_model package, char** out_json) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_json, "out_json");
  *out_json = nullptr;
  *out_json = DuplicateJson(ResolveModel(package)->GetPackage().ToJson());
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_package_select_variant(flm_model package, const char* variant_id) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(variant_id, "variant_id");
  ResolveModel(package)->SelectVariant(variant_id);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_package_select_best_variant(flm_model package, const char* constraints_json,
                                                    char** out_variant_id) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_variant_id, "out_variant_id");
  *out_variant_id = nullptr;

  const nlohmann::json constraints = ParseJsonOrEmpty(constraints_json, "constraints_json");
  *out_variant_id = DuplicateString(ResolveModel(package)->SelectBestVariant(constraints));
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_package_get_variant(flm_model package, const char* variant_id,
                                            flm_model* out_variant) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(variant_id, "variant_id");
  RequireNonNull(out_variant, "out_variant");
  *out_variant = FLM_INVALID_HANDLE;

  auto variant = ResolveModel(package)->GetVariantModel(variant_id);
  *out_variant = RegisterModel(variant);
  return FLM_OK;
  FLM_CATCH
}

flm_status FLM_CALL flm_package_estimate_download_json(flm_model package, const char* variant_ids_json,
                                                       char** out_json) FLM_NOEXCEPT {
  FLM_TRY
  RequireNonNull(out_json, "out_json");
  *out_json = nullptr;

  std::optional<std::vector<std::string>> ids;
  if (variant_ids_json != nullptr && variant_ids_json[0] != '\0') {
    const nlohmann::json parsed = nlohmann::json::parse(variant_ids_json, nullptr, false);
    if (parsed.is_discarded() || !parsed.is_array()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "variant_ids_json must be a JSON array of variant ids");
    }
    ids = parsed.get<std::vector<std::string>>();
  }

  *out_json = DuplicateJson(ResolveModel(package)->EstimateDownload(ids));
  return FLM_OK;
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
    // Distinguish "not finished" from "already taken": the fixes are different, and a
    // binding that polls needs to tell them apart.
    if (instance->state() == FLM_JOB_PENDING || instance->state() == FLM_JOB_RUNNING) {
      throw Error(FLM_ERROR_INVALID_STATE, "the job has not finished yet");
    }
    // A job that failed never had a result to take, so reporting one as taken would send
    // the caller looking for a double-take in their own code instead of at the failure.
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
  // Load the callback before the user data: the store side publishes them in the
  // opposite order, so this pairing can never mix a new callback with stale data.
  const flm_log_callback callback = g_log_callback.load(std::memory_order_acquire);
  if (callback == nullptr) {
    return;
  }
  callback(level, tag != nullptr ? tag : "flm", message != nullptr ? message : "",
           g_log_user_data.load(std::memory_order_acquire));
}

}  // namespace flm
