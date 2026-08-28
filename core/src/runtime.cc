// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "runtime.h"

#include <string>

namespace flm {
namespace {

/// Map common OGA error substrings to our status taxonomy.
flm_status ClassifyOgaError(const char* message) noexcept {
  if (message == nullptr) return FLM_ERROR_INTERNAL;
  const std::string_view msg(message);
  if (msg.find("not implemented") != std::string_view::npos ||
      msg.find("not supported") != std::string_view::npos)
    return FLM_ERROR_NOT_IMPLEMENTED;
  if (msg.find("invalid") != std::string_view::npos ||
      msg.find("Invalid") != std::string_view::npos)
    return FLM_ERROR_INVALID_ARGUMENT;
  if (msg.find("cancelled") != std::string_view::npos ||
      msg.find("canceled") != std::string_view::npos ||
      msg.find("terminated") != std::string_view::npos)
    return FLM_ERROR_CANCELLED;
  if (msg.find("memory") != std::string_view::npos ||
      msg.find("alloc") != std::string_view::npos)
    return FLM_ERROR_OUT_OF_MEMORY;
  if (msg.find("not found") != std::string_view::npos ||
      msg.find("No such file") != std::string_view::npos ||
      msg.find("does not exist") != std::string_view::npos)
    return FLM_ERROR_NOT_FOUND;
  return FLM_ERROR_INTERNAL;
}

}  // namespace

Runtime& Runtime::Instance() {
  static Runtime* instance = new Runtime();
  return *instance;
}

Runtime::Runtime() {
  // OGA initialises lazily on first model creation, so nothing to do here.
  version_ = FLM_OGA_VERSION_STRING;
}

Runtime::~Runtime() {
  // OgaShutdown must only be called after all OGA objects are destroyed.
  // In practice the Runtime singleton leaks (process exit), but if reached:
  OgaShutdown();
}

void Runtime::Check(OgaResult* result, std::string_view operation) const {
  if (result == nullptr) {
    return;
  }
  const char* message = OgaResultGetError(result);
  std::string message_copy = message != nullptr ? message : "unspecified OGA error";
  const flm_status status = ClassifyOgaError(message);
  OgaDestroyResult(result);

  std::string op(operation);
  throw Error(status, op + ": " + message_copy,
              {{"operation", op}});
}

flm_status Runtime::CheckNoThrow(OgaResult* result) const noexcept {
  if (result == nullptr) {
    return FLM_OK;
  }
  const char* message = OgaResultGetError(result);
  const flm_status status = ClassifyOgaError(message);
  OgaDestroyResult(result);
  return status;
}

}  // namespace flm
