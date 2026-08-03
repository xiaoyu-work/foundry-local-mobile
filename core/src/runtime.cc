// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "runtime.h"

#include <mutex>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace flm {
namespace {

using GetApiFn = const flApi*(FL_API_CALL*)(uint32_t);
using GetVersionStringFn = const char*(FL_API_CALL*)(void);

std::mutex g_path_mutex;
std::string g_library_path;

/// Candidate names, in preference order. An explicit path always wins; the bare names
/// let the platform loader resolve from the app's own library directory, which is where
/// the runtime lives once packaged into an AAR or a framework.
std::vector<std::string> CandidateLibraryNames() {
  std::vector<std::string> candidates;
  {
    std::lock_guard<std::mutex> lock(g_path_mutex);
    if (!g_library_path.empty()) {
      candidates.push_back(g_library_path);
    }
  }
#if defined(__APPLE__)
  // Inside an XCFramework the runtime is a framework binary, not a loose dylib.
  candidates.emplace_back("@rpath/foundry_local.framework/foundry_local");
  candidates.emplace_back("@loader_path/../Frameworks/foundry_local.framework/foundry_local");
  candidates.emplace_back("libfoundry_local.dylib");
#elif defined(_WIN32)
  candidates.emplace_back("foundry_local.dll");
#else
  candidates.emplace_back("libfoundry_local.so");
#endif
  return candidates;
}

void* OpenLibrary(const std::string& name, std::string* error_out) {
#if defined(_WIN32)
  void* handle = static_cast<void*>(::LoadLibraryA(name.c_str()));
  if (handle == nullptr && error_out != nullptr) {
    *error_out = "LoadLibraryA failed with " + std::to_string(::GetLastError());
  }
  return handle;
#else
  // RTLD_LOCAL keeps the runtime's symbols out of the global namespace, so an app that
  // also links its own ONNX Runtime does not get its symbols hijacked — a real and very
  // hard-to-debug failure mode on Android.
  void* handle = ::dlopen(name.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (handle == nullptr && error_out != nullptr) {
    const char* message = ::dlerror();
    *error_out = message != nullptr ? message : "dlopen failed";
  }
  return handle;
#endif
}

void* ResolveSymbol(void* library, const char* symbol) {
#if defined(_WIN32)
  return reinterpret_cast<void*>(::GetProcAddress(static_cast<HMODULE>(library), symbol));
#else
  return ::dlsym(library, symbol);
#endif
}

void CloseLibrary(void* library) {
  if (library == nullptr) {
    return;
  }
#if defined(_WIN32)
  ::FreeLibrary(static_cast<HMODULE>(library));
#else
  ::dlclose(library);
#endif
}

/// Map an upstream error code onto our status taxonomy.
flm_status MapUpstreamError(flErrorCode code) noexcept {
  switch (code) {
    case FOUNDRY_LOCAL_OK: return FLM_OK;
    case FOUNDRY_LOCAL_ERROR_NOT_IMPLEMENTED: return FLM_ERROR_NOT_IMPLEMENTED;
    case FOUNDRY_LOCAL_ERROR_INVALID_ARGUMENT: return FLM_ERROR_INVALID_ARGUMENT;
    case FOUNDRY_LOCAL_ERROR_INVALID_USAGE: return FLM_ERROR_INVALID_STATE;
    case FOUNDRY_LOCAL_ERROR_OPERATION_CANCELLED: return FLM_ERROR_CANCELLED;
    case FOUNDRY_LOCAL_ERROR_NETWORK: return FLM_ERROR_NETWORK;
    case FOUNDRY_LOCAL_ERROR_INTERNAL: return FLM_ERROR_INTERNAL;
  }
  return FLM_ERROR_INTERNAL;
}

}  // namespace

void Runtime::SetLibraryPath(std::string path) {
  std::lock_guard<std::mutex> lock(g_path_mutex);
  g_library_path = std::move(path);
}

Runtime& Runtime::Instance() {
  // Function-local static gives thread-safe one-time initialization. If loading throws,
  // the static stays uninitialized and the next call retries — which is what we want
  // when the app downloads the runtime after first launch.
  static Runtime* instance = new Runtime();
  return *instance;
}

bool Runtime::IsAvailable() noexcept {
  try {
    (void)Instance();
    return true;
  } catch (...) {
    return false;
  }
}

Runtime::Runtime() {
  LoadLibrary();
  ResolveApiTables();
}

Runtime::~Runtime() {
  // Deliberately not unloading: the runtime may still own background threads, and the
  // process is ending anyway. Unloading a library with live threads is how you get
  // crashes in atexit handlers.
}

void Runtime::LoadLibrary() {
  std::vector<std::string> attempts;
  for (const std::string& name : CandidateLibraryNames()) {
    std::string error;
    if (void* handle = OpenLibrary(name, &error)) {
      library_handle_ = handle;
      return;
    }
    attempts.push_back(name + ": " + error);
  }

  nlohmann::json context;
  context["attempts"] = attempts;
  throw Error(FLM_ERROR_NOT_IMPLEMENTED,
              "the Foundry Local runtime library could not be loaded. Ensure it is bundled with the app, "
              "or call flm_set_runtime_library_path() with its absolute path.",
              context);
}

void Runtime::ResolveApiTables() {
  auto get_api = reinterpret_cast<GetApiFn>(ResolveSymbol(library_handle_, "FoundryLocalGetApi"));
  if (get_api == nullptr) {
    CloseLibrary(library_handle_);
    library_handle_ = nullptr;
    throw Error(FLM_ERROR_INTERNAL, "FoundryLocalGetApi not found; the library is not a Foundry Local runtime");
  }

  api_ = get_api(FOUNDRY_LOCAL_API_VERSION);
  if (api_ == nullptr) {
    CloseLibrary(library_handle_);
    library_handle_ = nullptr;
    throw Error(FLM_ERROR_UNSUPPORTED_VERSION,
                "the Foundry Local runtime does not support API version " +
                    std::to_string(FOUNDRY_LOCAL_API_VERSION),
                {{"requested_version", FOUNDRY_LOCAL_API_VERSION}});
  }

  catalog_api_ = api_->GetCatalogApi();
  config_api_ = api_->GetConfigurationApi();
  item_api_ = api_->GetItemApi();
  inference_api_ = api_->GetInferenceApi();
  model_api_ = api_->GetModelApi();

  if (catalog_api_ == nullptr || config_api_ == nullptr || item_api_ == nullptr || inference_api_ == nullptr ||
      model_api_ == nullptr) {
    throw Error(FLM_ERROR_INTERNAL, "the Foundry Local runtime returned an incomplete API table");
  }

  if (auto get_version = reinterpret_cast<GetVersionStringFn>(ResolveSymbol(library_handle_,
                                                                            "FoundryLocalGetVersionString"))) {
    if (const char* version = get_version()) {
      version_ = version;
    }
  }
}

void Runtime::Check(flStatus* status, std::string_view operation) const {
  if (status == nullptr) {
    return;
  }
  const flErrorCode code = api_->Status_GetErrorCode(status);
  const char* message = api_->Status_GetErrorMessage(status);
  std::string message_copy = message != nullptr ? message : "unspecified runtime error";
  api_->Status_Release(status);

  std::string operation_copy(operation);
  throw Error(MapUpstreamError(code), operation_copy + ": " + message_copy,
              {{"operation", operation_copy}, {"upstream_code", static_cast<int>(code)}});
}

flm_status Runtime::CheckNoThrow(flStatus* status) const noexcept {
  if (status == nullptr) {
    return FLM_OK;
  }
  const flErrorCode code = api_->Status_GetErrorCode(status);
  api_->Status_Release(status);
  return MapUpstreamError(code);
}

}  // namespace flm
