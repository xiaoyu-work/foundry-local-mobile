// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "error.h"

#include <new>
#include <stdexcept>
#include <system_error>

namespace flm {
namespace {

// Thread-local so concurrent failures on different threads never overwrite each other.
// Held as strings (not string_views) because the ABI hands out borrowed pointers that
// must stay valid until the next failure on the same thread.
struct LastError {
  std::string message;
  std::string detail_json = R"({"code":0,"name":"FLM_OK","message":"","retryable":false,"context":{}})";
};

LastError& TlsError() noexcept {
  thread_local LastError error;
  return error;
}

}  // namespace

const char* StatusName(flm_status status) noexcept {
  switch (status) {
    case FLM_OK: return "FLM_OK";
    case FLM_ERROR_INTERNAL: return "FLM_ERROR_INTERNAL";
    case FLM_ERROR_INVALID_ARGUMENT: return "FLM_ERROR_INVALID_ARGUMENT";
    case FLM_ERROR_INVALID_HANDLE: return "FLM_ERROR_INVALID_HANDLE";
    case FLM_ERROR_INVALID_STATE: return "FLM_ERROR_INVALID_STATE";
    case FLM_ERROR_NOT_FOUND: return "FLM_ERROR_NOT_FOUND";
    case FLM_ERROR_NOT_IMPLEMENTED: return "FLM_ERROR_NOT_IMPLEMENTED";
    case FLM_ERROR_CANCELLED: return "FLM_ERROR_CANCELLED";
    case FLM_ERROR_NETWORK: return "FLM_ERROR_NETWORK";
    case FLM_ERROR_STORAGE: return "FLM_ERROR_STORAGE";
    case FLM_ERROR_OUT_OF_MEMORY: return "FLM_ERROR_OUT_OF_MEMORY";
    case FLM_ERROR_INCOMPATIBLE: return "FLM_ERROR_INCOMPATIBLE";
    case FLM_ERROR_TIMEOUT: return "FLM_ERROR_TIMEOUT";
    case FLM_ERROR_UNSUPPORTED_VERSION: return "FLM_ERROR_UNSUPPORTED_VERSION";
    case FLM_ERROR_MEMORY_PRESSURE: return "FLM_ERROR_MEMORY_PRESSURE";
    case FLM_ERROR_SHUTDOWN: return "FLM_ERROR_SHUTDOWN";
  }
  return "FLM_ERROR_INTERNAL";
}

bool IsRetryable(flm_status status) noexcept {
  switch (status) {
    // Transient conditions: the same call may succeed later.
    case FLM_ERROR_NETWORK:
    case FLM_ERROR_TIMEOUT:
    case FLM_ERROR_MEMORY_PRESSURE:
    case FLM_ERROR_OUT_OF_MEMORY:
      return true;
    default:
      // Programming errors, missing models and cancellations will not fix themselves.
      return false;
  }
}

nlohmann::json MakeErrorJson(flm_status status, const std::string& message, const nlohmann::json& context) {
  return nlohmann::json{
      {"code", static_cast<int>(status)},
      {"name", StatusName(status)},
      {"message", message},
      {"retryable", IsRetryable(status)},
      {"context", context.is_null() ? nlohmann::json::object() : context},
  };
}

flm_status SetLastError(flm_status status, const std::string& message, const nlohmann::json& context) noexcept {
  LastError& error = TlsError();
  try {
    error.message = message;
    error.detail_json = MakeErrorJson(status, message, context).dump();
  } catch (...) {
    // Serializing the error must never itself throw out of the ABI. Degrade gracefully.
    error.message = message;
    error.detail_json = R"({"code":2,"name":"FLM_ERROR_INTERNAL","message":"error serialization failed","retryable":false,"context":{}})";
  }
  return status;
}

void ClearLastError() noexcept {
  LastError& error = TlsError();
  error.message.clear();
  error.detail_json = R"({"code":0,"name":"FLM_OK","message":"","retryable":false,"context":{}})";
}

const char* LastErrorMessage() noexcept { return TlsError().message.c_str(); }

const char* LastErrorDetailJson() noexcept { return TlsError().detail_json.c_str(); }

flm_status TranslateException(const std::exception_ptr& eptr) noexcept {
  if (!eptr) {
    return SetLastError(FLM_ERROR_INTERNAL, "unknown failure");
  }
  try {
    std::rethrow_exception(eptr);
  } catch (const Error& e) {
    return SetLastError(e.status(), e.message(), e.context());
  } catch (const nlohmann::json::exception& e) {
    // Malformed JSON from the caller is by far the most common binding bug, so it gets a
    // dedicated mapping with the parser's own diagnostic preserved.
    return SetLastError(FLM_ERROR_INVALID_ARGUMENT, std::string("invalid JSON: ") + e.what(),
                        {{"json_error_id", e.id}});
  } catch (const std::bad_alloc&) {
    return SetLastError(FLM_ERROR_OUT_OF_MEMORY, "allocation failed");
  } catch (const std::invalid_argument& e) {
    return SetLastError(FLM_ERROR_INVALID_ARGUMENT, e.what());
  } catch (const std::system_error& e) {
    return SetLastError(FLM_ERROR_STORAGE, e.what(), {{"errno", e.code().value()}});
  } catch (const std::exception& e) {
    return SetLastError(FLM_ERROR_INTERNAL, e.what());
  } catch (...) {
    return SetLastError(FLM_ERROR_INTERNAL, "unknown failure");
  }
}

}  // namespace flm
