// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Thread-local error state backing flm_last_error_message / flm_last_error_detail_json.

#ifndef FOUNDRY_LOCAL_MOBILE_ERROR_H_
#define FOUNDRY_LOCAL_MOBILE_ERROR_H_

#include <exception>
#include <string>

#include "foundry_local_mobile/flm_types.h"
#include "third_party/json.h"

namespace flm {

/// Exception used internally to unwind to the ABI boundary. Never escapes the ABI.
class Error : public std::exception {
 public:
  Error(flm_status status, std::string message) : status_(status), message_(std::move(message)) {}
  Error(flm_status status, std::string message, nlohmann::json context)
      : status_(status), message_(std::move(message)), context_(std::move(context)) {}

  flm_status status() const noexcept { return status_; }
  const char* what() const noexcept override { return message_.c_str(); }
  const std::string& message() const noexcept { return message_; }
  const nlohmann::json& context() const noexcept { return context_; }

 private:
  flm_status status_;
  std::string message_;
  nlohmann::json context_ = nlohmann::json::object();
};

/// Stable string name for a status code, e.g. "FLM_ERROR_NETWORK".
const char* StatusName(flm_status status) noexcept;

/// Whether retrying the same operation could plausibly succeed. Bindings surface this so
/// apps can decide between an automatic retry and telling the user.
bool IsRetryable(flm_status status) noexcept;

/// Record a failure for the calling thread and return the status, so call sites can
/// `return SetLastError(...)`.
flm_status SetLastError(flm_status status, const std::string& message,
                        const nlohmann::json& context = nlohmann::json::object()) noexcept;

void ClearLastError() noexcept;
const char* LastErrorMessage() noexcept;
const char* LastErrorDetailJson() noexcept;

/// JSON detail document for an error, matching flm_last_error_detail_json's schema.
nlohmann::json MakeErrorJson(flm_status status, const std::string& message, const nlohmann::json& context);

/// Translate an in-flight exception into a status, recording it as this thread's last
/// error. Used by the FLM_TRY/FLM_CATCH wrapper at every ABI entry point.
flm_status TranslateException(const std::exception_ptr& eptr) noexcept;

}  // namespace flm

/// Every ABI entry point is wrapped so that no exception can cross the C boundary.
#define FLM_TRY try {
#define FLM_CATCH                          \
  }                                        \
  catch (...) {                            \
    return ::flm::TranslateException(std::current_exception()); \
  }

#endif  // FOUNDRY_LOCAL_MOBILE_ERROR_H_
