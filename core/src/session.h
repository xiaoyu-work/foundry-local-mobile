// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Inference sessions built directly on the OGA C API.

#ifndef FOUNDRY_LOCAL_MOBILE_SESSION_H_
#define FOUNDRY_LOCAL_MOBILE_SESSION_H_

#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "job.h"
#include "model.h"
#include "runtime.h"
#include "third_party/json.h"

namespace flm {

enum class SessionType {
  kChat,
  kAudio,
  kEmbedding,
};

SessionType ParseSessionType(const std::string& value);
const char* ToString(SessionType type) noexcept;

class Session {
 public:
  Session(std::shared_ptr<Model> model, const nlohmann::json& options);
  ~Session();

  Session(const Session&) = delete;
  Session& operator=(const Session&) = delete;

  void SetOptions(const nlohmann::json& options);

  nlohmann::json Complete(const nlohmann::json& request, JobContext& context);
  nlohmann::json SubmitToolResults(const nlohmann::json& tool_results, JobContext& context);

  nlohmann::json Transcribe(const nlohmann::json& request, JobContext& context);
  void PushAudio(const void* pcm_data, size_t byte_count, int32_t sample_rate, int32_t channels, bool is_final);

  nlohmann::json Embed(const nlohmann::json& request, JobContext& context);

  size_t GetTurnCount() const;
  void UndoTurns(size_t count);
  void ClearHistory();

  nlohmann::json ExportHistory() const;
  void RestoreHistory(const nlohmann::json& history);

  SessionType type() const noexcept { return type_; }
  const std::shared_ptr<Model>& model() const noexcept { return model_; }

 private:
  /// Build a chat-template prompt from OpenAI-shaped messages + optional tool definitions.
  /// Includes full accumulated conversation history to provide context for the fresh OGA generator.
  std::string BuildPrompt(const nlohmann::json& messages, const nlohmann::json& tools,
                          OgaTokenizer* tokenizer);

  /// Run the token generation loop, streaming deltas.
  nlohmann::json Generate(const std::string& prompt, const nlohmann::json& gen_options,
                          Model::InferenceLease& lease, JobContext& context);

  std::shared_ptr<Model> model_;
  SessionType type_ = SessionType::kChat;

  mutable std::mutex mutex_;
  nlohmann::json options_ = nlohmann::json::object();
  bool keep_history_ = true;

  /// Mirror of conversation for export/restore.
  nlohmann::json history_ = nlohmann::json::array();

  /// Registered tool definitions for chat template rendering.
  nlohmann::json tool_definitions_ = nlohmann::json::array();

  /// Serialises requests; the OGA generator is not reentrant.
  std::mutex request_mutex_;
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_SESSION_H_
