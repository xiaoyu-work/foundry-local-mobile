// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Inference sessions built directly on the OGA C API.

#ifndef FOUNDRY_LOCAL_MOBILE_SESSION_H_
#define FOUNDRY_LOCAL_MOBILE_SESSION_H_

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
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

  /// Signal shutdown for any blocked streaming transcription.
  void ShutdownAudioQueue() noexcept;

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
  /// When `preserve_media` is true, image/audio content parts are kept as type-only markers
  /// so the chat template can insert the correct multimodal placeholders.
  std::string BuildPrompt(const nlohmann::json& messages, const nlohmann::json& tools,
                          OgaTokenizer* tokenizer, bool preserve_media = false);

  /// Run the token generation loop with integrated tool-call and reasoning parsing.
  /// When `mm_inputs` and `mm_processor` are non-null, the generator is seeded via
  /// OgaGenerator_SetInputs (multimodal path) instead of token encoding.
  nlohmann::json Generate(const std::string& prompt, const nlohmann::json& gen_options,
                          const nlohmann::json& tool_defs,
                          Model::InferenceLease& lease, JobContext& context,
                          OgaNamedTensors* mm_inputs = nullptr,
                          OgaMultiModalProcessor* mm_processor = nullptr);

  // -- Audio helpers --

  /// Build the Whisper special-token prompt for a given language and task.
  static std::string BuildWhisperPrompt(const std::string& language, bool translate);

  /// File/buffer transcription using OgaMultiModalProcessor.
  nlohmann::json TranscribeBatch(const nlohmann::json& request, JobContext& context);

  /// Streaming transcription reading from the audio queue.
  nlohmann::json TranscribeStreaming(const nlohmann::json& request, JobContext& context);

  /// Convert signed-16-bit little-endian PCM bytes to float32 [-1, 1].
  static std::vector<float> ConvertS16LEToFloat(const uint8_t* pcm_bytes, size_t byte_count);

  std::shared_ptr<Model> model_;
  SessionType type_ = SessionType::kChat;

  mutable std::mutex mutex_;
  nlohmann::json options_ = nlohmann::json::object();
  bool keep_history_ = true;

  /// Mirror of conversation for export/restore.
  nlohmann::json history_ = nlohmann::json::array();

  /// Registered tool definitions for chat template rendering.
  nlohmann::json tool_definitions_ = nlohmann::json::array();
  uint64_t next_tool_call_id_ = 0;

  /// Serialises requests; the OGA generator is not reentrant.
  std::mutex request_mutex_;

  // -- Audio streaming queue --

  struct AudioChunk {
    std::vector<uint8_t> data;
    bool is_final = false;
  };

  std::mutex audio_mutex_;
  std::condition_variable audio_cv_;
  std::deque<AudioChunk> audio_queue_;
  std::atomic<bool> audio_shutdown_{false};
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_SESSION_H_
