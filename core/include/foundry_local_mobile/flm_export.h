// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Symbol visibility and calling-convention macros for the Foundry Local Mobile C ABI.

#ifndef FOUNDRY_LOCAL_MOBILE_FLM_EXPORT_H_
#define FOUNDRY_LOCAL_MOBILE_FLM_EXPORT_H_

#if defined(_WIN32)
#if defined(FLM_BUILDING_SHARED)
#define FLM_EXPORT __declspec(dllexport)
#elif defined(FLM_STATIC)
#define FLM_EXPORT
#else
#define FLM_EXPORT __declspec(dllimport)
#endif
#define FLM_CALL __cdecl
#else
#if defined(FLM_STATIC)
#define FLM_EXPORT
#else
#define FLM_EXPORT __attribute__((visibility("default")))
#endif
#define FLM_CALL
#endif

// Callbacks are invoked by the library on its own threads and must not throw.
#define FLM_CALLBACK FLM_CALL

#if defined(__cplusplus)
#define FLM_NOEXCEPT noexcept
#else
#define FLM_NOEXCEPT
#endif

#endif  // FOUNDRY_LOCAL_MOBILE_FLM_EXPORT_H_
