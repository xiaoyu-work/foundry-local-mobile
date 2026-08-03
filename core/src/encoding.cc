// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "encoding.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <filesystem>
#include <fstream>

#include "error.h"

namespace flm {
namespace {

constexpr char kEncodeTable[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Reverse lookup, built once. 0xFF marks an invalid character, 0xFE marks skippable
/// whitespace and padding.
const std::array<uint8_t, 256>& DecodeTable() {
  static const std::array<uint8_t, 256> table = [] {
    std::array<uint8_t, 256> t{};
    t.fill(0xFF);
    for (uint8_t i = 0; i < 64; ++i) {
      t[static_cast<uint8_t>(kEncodeTable[i])] = i;
    }
    // Accept the URL-safe alphabet too. Data URLs and JSON payloads produced by web
    // tooling routinely use it, and rejecting them would be a confusing failure.
    t[static_cast<uint8_t>('-')] = 62;
    t[static_cast<uint8_t>('_')] = 63;
    for (char c : {'=', '\n', '\r', '\t', ' '}) {
      t[static_cast<uint8_t>(c)] = 0xFE;
    }
    return t;
  }();
  return table;
}

}  // namespace

std::vector<uint8_t> Base64Decode(std::string_view input) {
  // Strip a data URL prefix if present; callers frequently pass one straight through
  // from a web or JS layer.
  if (const size_t comma = input.find(","); comma != std::string_view::npos && input.substr(0, 5) == "data:") {
    input = input.substr(comma + 1);
  }

  const auto& table = DecodeTable();
  std::vector<uint8_t> out;
  out.reserve(input.size() / 4 * 3);

  uint32_t buffer = 0;
  int bits = 0;
  for (char c : input) {
    const uint8_t value = table[static_cast<uint8_t>(c)];
    if (value == 0xFE) {
      continue;
    }
    if (value == 0xFF) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "invalid base64 payload");
    }
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<uint8_t>((buffer >> bits) & 0xFF));
    }
  }
  return out;
}

std::string Base64Encode(const uint8_t* data, size_t size) {
  std::string out;
  out.reserve((size + 2) / 3 * 4);
  for (size_t i = 0; i < size; i += 3) {
    const uint32_t a = data[i];
    const uint32_t b = (i + 1 < size) ? data[i + 1] : 0;
    const uint32_t c = (i + 2 < size) ? data[i + 2] : 0;
    const uint32_t triple = (a << 16) | (b << 8) | c;

    out.push_back(kEncodeTable[(triple >> 18) & 0x3F]);
    out.push_back(kEncodeTable[(triple >> 12) & 0x3F]);
    out.push_back(i + 1 < size ? kEncodeTable[(triple >> 6) & 0x3F] : '=');
    out.push_back(i + 2 < size ? kEncodeTable[triple & 0x3F] : '=');
  }
  return out;
}

std::vector<uint8_t> ReadFileBytes(const std::string& path) {
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  if (!stream) {
    throw Error(FLM_ERROR_STORAGE, "cannot open '" + path + "'",
                {{"path", path},
                 {"hint", "the path must be readable by the app sandbox; content:// URIs must be resolved first"}});
  }
  const std::streamsize size = stream.tellg();
  if (size < 0) {
    throw Error(FLM_ERROR_STORAGE, "cannot determine the size of '" + path + "'");
  }
  stream.seekg(0, std::ios::beg);

  std::vector<uint8_t> bytes(static_cast<size_t>(size));
  if (size > 0 && !stream.read(reinterpret_cast<char*>(bytes.data()), size)) {
    throw Error(FLM_ERROR_STORAGE, "cannot read '" + path + "'");
  }
  return bytes;
}

std::string FileExtension(const std::string& path) {
  std::string extension = std::filesystem::path(path).extension().string();
  if (!extension.empty() && extension.front() == '.') {
    extension.erase(extension.begin());
  }
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return extension;
}

}  // namespace flm
