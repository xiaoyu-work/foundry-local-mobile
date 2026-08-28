// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#ifndef FOUNDRY_LOCAL_MOBILE_MODEL_H_
#define FOUNDRY_LOCAL_MOBILE_MODEL_H_

#include <memory>
#include <mutex>
#include <string>

#include "job.h"
#include "runtime.h"
#include "third_party/json.h"

namespace flm {

class Manager;

/// A model backed directly by ONNX Runtime GenAI.
///
/// Owns OgaModel, OgaTokenizer and metadata derived from the filesystem path and
/// genai_config.json. Model path is always caller-owned; the SDK never deletes it.
class Model : public std::enable_shared_from_this<Model> {
 public:
  Model(std::shared_ptr<Manager> manager, const std::string& path, const std::string& name);
  ~Model();

  Model(const Model&) = delete;
  Model& operator=(const Model&) = delete;

  nlohmann::json GetInfo() const;
  std::string GetId() const;
  std::string GetTask() const;
  std::string GetPath() const;
  bool IsCached() const;
  bool IsLoaded() const;

  nlohmann::json Load(const nlohmann::json& options, JobContext& context);
  nlohmann::json Reload(JobContext& context);
  void Unload();

  /// Acquire a shared lease on the OGA model and tokenizer. While the lease is held,
  /// the model cannot be unloaded. Returns nullptr if the model is not loaded.
  class InferenceLease {
   public:
    InferenceLease() = default;
    InferenceLease(std::shared_ptr<Model> model, std::unique_lock<std::mutex> lock,
                   OgaModel* oga_model, OgaTokenizer* oga_tokenizer);

    InferenceLease(InferenceLease&&) = default;
    InferenceLease& operator=(InferenceLease&&) = default;

    InferenceLease(const InferenceLease&) = delete;
    InferenceLease& operator=(const InferenceLease&) = delete;

    OgaModel* oga_model() const noexcept { return oga_model_; }
    OgaTokenizer* oga_tokenizer() const noexcept { return oga_tokenizer_; }
    explicit operator bool() const noexcept { return oga_model_ != nullptr; }

   private:
    std::shared_ptr<Model> model_;
    std::unique_lock<std::mutex> lock_;
    OgaModel* oga_model_ = nullptr;
    OgaTokenizer* oga_tokenizer_ = nullptr;
  };

  /// Acquire a shared lease preventing Unload while OGA operations run.
  /// Throws FLM_ERROR_INVALID_STATE if the model is not loaded.
  InferenceLease AcquireInferenceLease();

  const std::shared_ptr<Manager>& manager() const noexcept { return manager_; }

 private:
  void LoadMetadataFromConfig();

  std::shared_ptr<Manager> manager_;
  std::string path_;
  std::string name_;

  // OGA objects — owned, created on Load, destroyed on Unload.
  OgaModel* oga_model_ = nullptr;
  OgaTokenizer* oga_tokenizer_ = nullptr;
  OgaConfig* oga_config_ = nullptr;

  /// Serializes OGA operations for this model and protects handle lifetime.
  mutable std::mutex oga_mutex_;

  /// Protects metadata_ and loaded_.
  mutable std::mutex mutex_;

  nlohmann::json metadata_;
  nlohmann::json load_options_ = nlohmann::json::object();
  bool loaded_ = false;
  std::string execution_provider_;
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_MODEL_H_
