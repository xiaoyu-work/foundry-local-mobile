// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// SHA-256, for verifying downloaded model files.
//
// Model packages address shared assets by `sha256:<hex>`, and a model downloaded from a
// user-controlled URL is untrusted input that the runtime will subsequently mmap and
// execute operators from. Verification is not optional, and a self-contained
// implementation avoids pulling a crypto library into every mobile binary just for this.

#ifndef FOUNDRY_LOCAL_MOBILE_SHA256_H_
#define FOUNDRY_LOCAL_MOBILE_SHA256_H_

#include <cstddef>
#include <cstdint>
#include <string>

namespace flm {

class Sha256 {
 public:
  Sha256() noexcept { Reset(); }

  void Reset() noexcept;
  void Update(const void* data, size_t size) noexcept;

  /// Lowercase hex digest. The object must not be reused afterwards without Reset().
  std::string Finalize() noexcept;

 private:
  void Transform(const uint8_t block[64]) noexcept;

  uint32_t state_[8]{};
  uint8_t buffer_[64]{};
  size_t buffer_size_ = 0;
  uint64_t total_bits_ = 0;
};

/// Hash a file's contents. Throws Error(FLM_ERROR_STORAGE) if it cannot be read.
std::string Sha256File(const std::string& path);

/// Compare a computed hex digest against a reference that may carry a `sha256:` prefix.
/// Case-insensitive, and tolerant of the prefix being absent.
bool DigestMatches(const std::string& expected, const std::string& actual_hex) noexcept;

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_SHA256_H_
