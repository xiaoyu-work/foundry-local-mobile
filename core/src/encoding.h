// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Binary payload helpers.
//
// Mobile bindings cannot cheaply hand a raw byte buffer across every FFI boundary we
// support (dart:ffi can, JNI can, but a React Native bridge cannot), so image and audio
// payloads travel as base64 inside the request JSON. Decoding happens once, here.

#ifndef FOUNDRY_LOCAL_MOBILE_ENCODING_H_
#define FOUNDRY_LOCAL_MOBILE_ENCODING_H_

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace flm {

/// Decode standard base64, tolerating missing padding and embedded whitespace.
/// Throws Error(FLM_ERROR_INVALID_ARGUMENT) on an invalid character.
std::vector<uint8_t> Base64Decode(std::string_view input);

std::string Base64Encode(const uint8_t* data, size_t size);

/// Read a file from the app sandbox. Throws Error(FLM_ERROR_STORAGE) when unreadable.
std::vector<uint8_t> ReadFileBytes(const std::string& path);

/// Lowercase file extension without the dot, e.g. "png". Empty when there is none.
std::string FileExtension(const std::string& path);

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_ENCODING_H_
