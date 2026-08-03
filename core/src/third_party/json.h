// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Single include point for the JSON library.
//
// Centralized so the dependency can be swapped or vendored without touching every
// source file, and so the warning suppressions live in exactly one place.

#ifndef FOUNDRY_LOCAL_MOBILE_THIRD_PARTY_JSON_H_
#define FOUNDRY_LOCAL_MOBILE_THIRD_PARTY_JSON_H_

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#elif defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#endif

#include <nlohmann/json.hpp>

#if defined(__clang__)
#pragma clang diagnostic pop
#elif defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

#endif  // FOUNDRY_LOCAL_MOBILE_THIRD_PARTY_JSON_H_
