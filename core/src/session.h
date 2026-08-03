// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Inference sessions.
//
// A session owns the model's KV cache, which on a phone is usually the single largest
// allocation the app makes. It is therefore explicitly scoped rather than implicit in a
// "chat" call, so an app can drop it when a screen closes.
//
// Requests arrive as OpenAI-shaped JSON because every mobile ecosystem already has code
// and mental models for that shape. They are translated here into the runtime's flItem
// graph, and streamed output is translated back into flat flm_delta structs — never into
// JSON, since a JSON document per token would dominate the cost of generation itself.

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

/// Owns upstream flItem handles for the duration of a request.
///
/// Message parts are *borrowed* by the MESSAGE item that references them, and the
/// request borrows items added with take_ownership=false. Keeping every item alive in
/// one arena until the request completes is the only way to satisfy both rules without
/// tracking each item's role.
class ItemArena {
 public:
  ItemArena() = default;
  ~ItemArena();

  ItemArena(const ItemArena&) = delete;
  ItemArena& operator=(const ItemArena&) = delete;

  /// Create an item of `type` and keep it alive until the arena is destroyed.
  flItem* Create(flItemType type);

  /// Adopt an already-created item.
  flItem* Adopt(flItem* item);

 private:
  std::vector<flItem*> items_;
};

class Session {
 public:
  Session(std::shared_ptr<Model> model, const nlohmann::json& options);
  ~Session();

  Session(const Session&) = delete;
  Session& operator=(const Session&) = delete;

  void SetOptions(const nlohmann::json& options);

  /// Run a chat completion. Streams deltas through `context` and returns the aggregate
  /// result as JSON.
  nlohmann::json Complete(const nlohmann::json& request, JobContext& context);

  /// Continue a turn that stopped with FLM_FINISH_TOOL_CALLS.
  nlohmann::json SubmitToolResults(const nlohmann::json& tool_results, JobContext& context);

  /// Transcribe audio, streaming partial and final segments.
  nlohmann::json Transcribe(const nlohmann::json& request, JobContext& context);

  /// Feed PCM into a live transcription started with {"streaming": true}.
  void PushAudio(const void* pcm_data, size_t byte_count, int32_t sample_rate, int32_t channels, bool is_final);

  nlohmann::json Embed(const nlohmann::json& request, JobContext& context);

  size_t GetTurnCount() const;
  void UndoTurns(size_t count);
  void ClearHistory();

  nlohmann::json ExportHistory() const;
  void RestoreHistory(const nlohmann::json& history);

  SessionType type() const noexcept { return type_; }

 private:
  /// Translate generation parameters into upstream key/value options.
  void ApplyOptions(const nlohmann::json& options);

  /// Register tool definitions declared on a request. Idempotent per tool name.
  void SyncToolDefinitions(const nlohmann::json& tools);

  /// Run a prepared request, forwarding streamed items to `context` and collecting the
  /// aggregate result.
  nlohmann::json RunRequest(flRequest* request, JobContext& context);

  /// Convert one streamed or final item into deltas. Returns false to request
  /// cancellation.
  bool DispatchItem(const flItem* item, JobContext& context, nlohmann::json& aggregate);

  std::shared_ptr<Model> model_;
  SessionType type_ = SessionType::kChat;
  flSession* upstream_ = nullptr;

  mutable std::mutex mutex_;
  nlohmann::json options_ = nlohmann::json::object();
  std::vector<std::string> registered_tools_;
  bool keep_history_ = true;

  /// Mirror of the conversation, maintained for export. The runtime owns the real state;
  /// this exists because the process can be killed at any moment on mobile and the user
  /// expects their conversation back.
  nlohmann::json history_ = nlohmann::json::array();

  /// Restored history not yet sent to the runtime. Prepended to the next request, which
  /// is exactly correct for a fresh session with no state of its own.
  nlohmann::json pending_history_ = nlohmann::json::array();

  /// Live-capture queue for streaming transcription. Owned by `audio_queue_item_`, which
  /// lives in the in-flight request's arena, so both are cleared when the request ends.
  flItemQueue* audio_queue_ = nullptr;
  flItem* audio_queue_item_ = nullptr;

  /// Guards against two concurrent requests on one session; the runtime's generator
  /// state is not reentrant.
  std::mutex request_mutex_;
};

}  // namespace flm

#endif  // FOUNDRY_LOCAL_MOBILE_SESSION_H_
