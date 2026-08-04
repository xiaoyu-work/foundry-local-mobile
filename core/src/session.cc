// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "session.h"

#include <algorithm>
#include <cstring>

#include "encoding.h"

namespace flm {
namespace {

/// Session/request options are passed upstream as key/value strings. Only keys the
/// runtime understands are forwarded; unknown keys are dropped rather than passed through
/// so a typo in app code cannot silently change generation behaviour.
constexpr const char* kGenerationOptionKeys[] = {
    FOUNDRY_LOCAL_PARAM_TEMPERATURE,       FOUNDRY_LOCAL_PARAM_TOP_P,
    FOUNDRY_LOCAL_PARAM_TOP_K,             FOUNDRY_LOCAL_PARAM_MAX_OUTPUT_TOKENS,
    FOUNDRY_LOCAL_PARAM_FREQUENCY_PENALTY, FOUNDRY_LOCAL_PARAM_PRESENCE_PENALTY,
    FOUNDRY_LOCAL_PARAM_SEED,              FOUNDRY_LOCAL_PARAM_EARLY_STOPPING,
    FOUNDRY_LOCAL_PARAM_DO_SAMPLE,         FOUNDRY_LOCAL_PARAM_TOOL_CHOICE,
};

/// Render a JSON value the way the runtime's option parser expects: bare scalars, not
/// quoted JSON. `"0.7"` is a float; `"\"0.7\""` is not.
std::string OptionValueToString(const nlohmann::json& value) {
  if (value.is_string()) {
    return value.get<std::string>();
  }
  if (value.is_boolean()) {
    return value.get<bool>() ? "true" : "false";
  }
  return value.dump();
}

flMessageRole ParseRole(const std::string& role) {
  if (role == "system") return FOUNDRY_LOCAL_ROLE_SYSTEM;
  if (role == "user") return FOUNDRY_LOCAL_ROLE_USER;
  if (role == "assistant") return FOUNDRY_LOCAL_ROLE_ASSISTANT;
  if (role == "tool") return FOUNDRY_LOCAL_ROLE_TOOL;
  if (role == "developer") return FOUNDRY_LOCAL_ROLE_DEVELOPER;
  throw Error(FLM_ERROR_INVALID_ARGUMENT, "unknown message role '" + role + "'");
}

flm_finish_reason MapFinishReason(flFinishReason reason) {
  switch (reason) {
    case FOUNDRY_LOCAL_FINISH_STOP: return FLM_FINISH_STOP;
    case FOUNDRY_LOCAL_FINISH_LENGTH: return FLM_FINISH_LENGTH;
    case FOUNDRY_LOCAL_FINISH_TOOL_CALLS: return FLM_FINISH_TOOL_CALLS;
    case FOUNDRY_LOCAL_FINISH_ERROR: return FLM_FINISH_ERROR;
    case FOUNDRY_LOCAL_FINISH_NONE:
    default: return FLM_FINISH_NONE;
  }
}

const char* FinishReasonName(flm_finish_reason reason) noexcept {
  switch (reason) {
    case FLM_FINISH_STOP: return "stop";
    case FLM_FINISH_LENGTH: return "length";
    case FLM_FINISH_TOOL_CALLS: return "tool_calls";
    case FLM_FINISH_CANCELLED: return "cancelled";
    case FLM_FINISH_ERROR: return "error";
    case FLM_FINISH_NONE:
    default: return "none";
  }
}

/// Streaming bridge state. Lives on the stack of RunRequest for the duration of the
/// upstream call, so no ownership transfer or lifetime extension is needed.
struct StreamState {
  Session* session;
  JobContext* context;
  nlohmann::json* aggregate;
  bool cancelled = false;
};

int64_t DurationOrUnknown(int64_t value) {
  return value == FOUNDRY_LOCAL_DURATION_UNSET ? FLM_UNKNOWN_SIZE : value;
}

}  // namespace

SessionType ParseSessionType(const std::string& value) {
  if (value.empty() || value == "chat") return SessionType::kChat;
  if (value == "audio" || value == "transcription") return SessionType::kAudio;
  if (value == "embedding" || value == "embeddings") return SessionType::kEmbedding;
  throw Error(FLM_ERROR_INVALID_ARGUMENT, "unknown session type '" + value + "'");
}

const char* ToString(SessionType type) noexcept {
  switch (type) {
    case SessionType::kAudio: return "audio";
    case SessionType::kEmbedding: return "embedding";
    case SessionType::kChat:
    default: return "chat";
  }
}

/* ------------------------------------------------------------------------- */
/* ItemArena                                                                  */
/* ------------------------------------------------------------------------- */

ItemArena::~ItemArena() {
  const Runtime& runtime = Runtime::Instance();
  // Release in reverse order: a MESSAGE created after its parts must go first, so the
  // parts it borrows are still alive while it tears down.
  for (auto it = items_.rbegin(); it != items_.rend(); ++it) {
    if (*it != nullptr) {
      runtime.item_api().Item_Release(*it);
    }
  }
}

flItem* ItemArena::Create(flItemType type) {
  const Runtime& runtime = Runtime::Instance();
  flItem* item = nullptr;
  runtime.Check(runtime.item_api().Create(type, &item), "create item");
  items_.push_back(item);
  return item;
}

flItem* ItemArena::Adopt(flItem* item) {
  if (item != nullptr) {
    items_.push_back(item);
  }
  return item;
}

/* ------------------------------------------------------------------------- */
/* Session lifecycle                                                          */
/* ------------------------------------------------------------------------- */

Session::Session(std::shared_ptr<Model> model, const nlohmann::json& options) : model_(std::move(model)) {
  if (!model_) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "a session requires a model");
  }
  if (!model_->IsLoaded()) {
    throw Error(FLM_ERROR_INVALID_STATE,
                "the model must be loaded before creating a session",
                {{"hint", "call flm_model_load_async first"}});
  }

  type_ = ParseSessionType(options.value("type", std::string("chat")));
  keep_history_ = options.value("keep_history", true);

  const Runtime& runtime = Runtime::Instance();

  // The runtime picks a session implementation from the model's task, and it learns the
  // task from the Azure catalog. A model the app supplied itself is never in that
  // catalog, so it arrives with an empty task and the runtime rejects it with a message
  // that names no cause -- "unsupported model task: " and nothing after the colon. Say
  // what is actually wrong, because the app cannot fix it and should not spend a day
  // discovering that.
  if (const std::string task = model_->GetTask(); task.empty()) {
    throw Error(FLM_ERROR_NOT_IMPLEMENTED,
                "the runtime will not open a session on '" + model_->GetId() +
                    "' because it does not know what kind of model it is",
                {{"model", model_->GetId()},
                 {"cause",
                  "a model's task comes from the Foundry Local catalog, and a model the app "
                  "supplied -- bundled or downloaded from its own URL -- is not in it"},
                 {"consequence", "the model downloads, installs and loads, but cannot infer"}});
  }

  runtime.Check(runtime.inference_api().Session_Create(model_->upstream(), &upstream_), "create session");

  ApplyOptions(options);

  // A system prompt is part of the conversation, not an option, so it is recorded as the
  // first history entry and replayed with the first request.
  if (const auto it = options.find("system_prompt"); it != options.end() && it->is_string()) {
    const std::string prompt = it->get<std::string>();
    if (!prompt.empty()) {
      pending_history_.push_back(nlohmann::json{{"role", "system"}, {"content", prompt}});
      history_.push_back(nlohmann::json{{"role", "system"}, {"content", prompt}});
    }
  }
}

Session::~Session() {
  if (upstream_ == nullptr) {
    return;
  }
  const Runtime& runtime = Runtime::Instance();
  // Drop the streaming callback first. It captures stack state from RunRequest, and a
  // late invocation during teardown would dereference freed memory.
  runtime.CheckNoThrow(runtime.inference_api().Session_SetStreamingCallback(upstream_, nullptr, nullptr));
  runtime.inference_api().Session_Release(upstream_);
  upstream_ = nullptr;
}

void Session::ApplyOptions(const nlohmann::json& options) {
  if (!options.is_object()) {
    return;
  }
  const Runtime& runtime = Runtime::Instance();

  flKeyValuePairs* pairs = nullptr;
  runtime.api().CreateKeyValuePairs(&pairs);
  UpstreamHandle<flKeyValuePairs, decltype(flApi::KeyValuePairs_Release)> owned_pairs(
      pairs, runtime.api().KeyValuePairs_Release);

  bool any = false;
  for (const char* key : kGenerationOptionKeys) {
    const auto it = options.find(key);
    if (it == options.end() || it->is_null()) {
      continue;
    }
    runtime.api().AddKeyValuePair(owned_pairs.get(), key, OptionValueToString(*it).c_str());
    any = true;
  }

  // Audio sessions take a language hint the same way, but under the runtime's own key.
  if (type_ == SessionType::kAudio) {
    if (const auto it = options.find("language"); it != options.end() && it->is_string()) {
      runtime.api().AddKeyValuePair(owned_pairs.get(), "language", it->get<std::string>().c_str());
      any = true;
    }
  }

  if (any) {
    runtime.Check(runtime.inference_api().Session_SetOptions(upstream_, owned_pairs.get()), "set session options");
  }

  std::lock_guard<std::mutex> lock(mutex_);
  for (const auto& [key, value] : options.items()) {
    options_[key] = value;
  }
}

void Session::SetOptions(const nlohmann::json& options) {
  if (!options.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "session options must be a JSON object");
  }
  if (options.contains("type")) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "a session's type is fixed at creation; create a new session instead");
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (const auto it = options.find("keep_history"); it != options.end() && it->is_boolean()) {
      keep_history_ = it->get<bool>();
    }
  }
  ApplyOptions(options);
}

/* ------------------------------------------------------------------------- */
/* Request construction                                                       */
/* ------------------------------------------------------------------------- */

namespace {

/// Build a TEXT part item.
flItem* MakeTextItem(ItemArena& arena, const std::string& text, flTextItemType text_type) {
  const Runtime& runtime = Runtime::Instance();
  flItem* item = arena.Create(FOUNDRY_LOCAL_ITEM_TEXT);

  flTextData data{};
  data.version = FOUNDRY_LOCAL_API_VERSION;
  data.text = text.c_str();
  data.type = text_type;
  runtime.Check(runtime.item_api().SetText(item, &data), "set text");
  return item;
}

/// Build an IMAGE part from a `path` or `data_base64` content part.
/// `storage` keeps the decoded bytes alive; the item borrows them until the request ends.
flItem* MakeImageItem(ItemArena& arena, const nlohmann::json& part, std::vector<std::vector<uint8_t>>& storage) {
  const Runtime& runtime = Runtime::Instance();
  flItem* item = arena.Create(FOUNDRY_LOCAL_ITEM_IMAGE);

  std::string format = part.value("format", std::string());
  flImageData data{};
  data.version = FOUNDRY_LOCAL_API_VERSION;

  if (const auto it = part.find("path"); it != part.end() && it->is_string()) {
    const std::string path = it->get<std::string>();
    if (format.empty()) {
      format = FileExtension(path);
    }
    // Read the file rather than passing the URI through: on Android the runtime runs
    // without the app's storage permissions for anything outside its own sandbox, and a
    // failure there surfaces as an opaque decode error.
    storage.push_back(ReadFileBytes(path));
  } else if (const auto b64 = part.find("data_base64"); b64 != part.end() && b64->is_string()) {
    storage.push_back(Base64Decode(b64->get<std::string>()));
  } else {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "an image part needs either 'path' or 'data_base64'");
  }

  data.data = storage.back().data();
  data.data_size = storage.back().size();
  static const std::string kDefaultImageFormat = "png";
  data.format = format.empty() ? kDefaultImageFormat.c_str() : format.c_str();

  runtime.Check(runtime.item_api().SetImage(item, &data), "set image");
  return item;
}

flItem* MakeAudioItem(ItemArena& arena, const nlohmann::json& part, std::vector<std::vector<uint8_t>>& storage) {
  const Runtime& runtime = Runtime::Instance();
  flItem* item = arena.Create(FOUNDRY_LOCAL_ITEM_AUDIO);

  std::string format = part.value("format", std::string());
  flAudioData data{};
  data.version = FOUNDRY_LOCAL_API_VERSION;

  if (const auto it = part.find("path"); it != part.end() && it->is_string()) {
    const std::string path = it->get<std::string>();
    if (format.empty()) {
      format = FileExtension(path);
    }
    storage.push_back(ReadFileBytes(path));
  } else if (const auto b64 = part.find("data_base64"); b64 != part.end() && b64->is_string()) {
    storage.push_back(Base64Decode(b64->get<std::string>()));
  } else {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "an audio part needs either 'path' or 'data_base64'");
  }

  data.data = storage.back().data();
  data.data_size = storage.back().size();
  static const std::string kDefaultAudioFormat = "wav";
  data.format = format.empty() ? kDefaultAudioFormat.c_str() : format.c_str();
  data.sample_rate = part.value("sample_rate", 0);
  data.channels = part.value("channels", 0);

  runtime.Check(runtime.item_api().SetAudio(item, &data), "set audio");
  return item;
}

/// Convert one OpenAI-shaped message into a MESSAGE item.
///
/// `strings` and `buffers` own every byte the item borrows. They must outlive the item,
/// which is why they are passed in rather than kept locally.
flItem* MakeMessageItem(ItemArena& arena, const nlohmann::json& message, std::vector<std::string>& strings,
                        std::vector<std::vector<uint8_t>>& buffers) {
  const Runtime& runtime = Runtime::Instance();

  const std::string role_name = message.value("role", std::string("user"));
  const flMessageRole role = ParseRole(role_name);

  std::vector<const flItem*> parts;
  const auto content = message.find("content");
  if (content == message.end()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "message is missing 'content'");
  }

  if (content->is_string()) {
    strings.push_back(content->get<std::string>());
    parts.push_back(MakeTextItem(arena, strings.back(), FOUNDRY_LOCAL_TEXT_ITEM_TYPE_DEFAULT));
  } else if (content->is_array()) {
    for (const auto& part : *content) {
      if (part.is_string()) {
        strings.push_back(part.get<std::string>());
        parts.push_back(MakeTextItem(arena, strings.back(), FOUNDRY_LOCAL_TEXT_ITEM_TYPE_DEFAULT));
        continue;
      }
      if (!part.is_object()) {
        throw Error(FLM_ERROR_INVALID_ARGUMENT, "each content part must be a string or an object");
      }
      const std::string type = part.value("type", std::string("text"));
      if (type == "text") {
        strings.push_back(part.value("text", std::string()));
        parts.push_back(MakeTextItem(arena, strings.back(), FOUNDRY_LOCAL_TEXT_ITEM_TYPE_DEFAULT));
      } else if (type == "image" || type == "image_url") {
        parts.push_back(MakeImageItem(arena, part, buffers));
      } else if (type == "audio" || type == "input_audio") {
        parts.push_back(MakeAudioItem(arena, part, buffers));
      } else {
        throw Error(FLM_ERROR_INVALID_ARGUMENT, "unsupported content part type '" + type + "'");
      }
    }
  } else {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "'content' must be a string or an array of parts");
  }

  if (parts.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "message content is empty");
  }

  flItem* item = arena.Create(FOUNDRY_LOCAL_ITEM_MESSAGE);
  flMessageData data{};
  data.version = FOUNDRY_LOCAL_API_VERSION;
  data.role = role;
  data.content_items = parts.data();
  data.content_items_count = parts.size();
  if (const auto name = message.find("name"); name != message.end() && name->is_string()) {
    strings.push_back(name->get<std::string>());
    data.name = strings.back().c_str();
  }
  runtime.Check(runtime.item_api().SetMessage(item, &data), "set message");
  return item;
}

}  // namespace

void Session::SyncToolDefinitions(const nlohmann::json& tools) {
  if (!tools.is_array()) {
    return;
  }
  const Runtime& runtime = Runtime::Instance();

  std::vector<std::string> wanted;
  for (const auto& tool : tools) {
    // Accept both the bare shape and OpenAI's {"type":"function","function":{...}}.
    const nlohmann::json& def = tool.contains("function") ? tool.at("function") : tool;
    const std::string name = def.value("name", std::string());
    if (name.empty()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "each tool needs a 'name'");
    }
    wanted.push_back(name);

    std::lock_guard<std::mutex> lock(mutex_);
    if (std::find(registered_tools_.begin(), registered_tools_.end(), name) != registered_tools_.end()) {
      continue;
    }

    const std::string description = def.value("description", std::string());
    const nlohmann::json schema = def.contains("parameters") ? def.at("parameters")
                                  : def.contains("json_schema") ? def.at("json_schema")
                                                                : nlohmann::json::object();
    const std::string schema_text = schema.dump();

    flToolDefinition tool_def{};
    tool_def.version = FOUNDRY_LOCAL_API_VERSION;
    tool_def.name = name.c_str();
    tool_def.description = description.c_str();
    tool_def.json_schema = schema_text.c_str();
    runtime.Check(runtime.inference_api().Session_AddToolDefinition(upstream_, &tool_def),
                  "add tool definition '" + name + "'");
    registered_tools_.push_back(name);
  }

  // Remove tools the caller dropped. A model that can still see a tool the app no longer
  // implements will eventually call it, and the app has nothing to answer with.
  std::vector<std::string> stale;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& registered : registered_tools_) {
      if (std::find(wanted.begin(), wanted.end(), registered) == wanted.end()) {
        stale.push_back(registered);
      }
    }
  }
  for (const auto& name : stale) {
    bool removed = false;
    runtime.CheckNoThrow(runtime.inference_api().Session_RemoveToolDefinition(upstream_, name.c_str(), &removed));
    std::lock_guard<std::mutex> lock(mutex_);
    registered_tools_.erase(std::remove(registered_tools_.begin(), registered_tools_.end(), name),
                            registered_tools_.end());
  }
}

/* ------------------------------------------------------------------------- */
/* Streaming                                                                  */
/* ------------------------------------------------------------------------- */

bool Session::DispatchItem(const flItem* item, JobContext& context, nlohmann::json& aggregate) {
  const Runtime& runtime = Runtime::Instance();
  const flItemType type = runtime.item_api().GetType(item);

  switch (type) {
    case FOUNDRY_LOCAL_ITEM_TEXT: {
      flTextData text{};
      text.version = FOUNDRY_LOCAL_API_VERSION;
      if (runtime.CheckNoThrow(runtime.item_api().GetText(item, &text)) != FLM_OK || text.text == nullptr) {
        return true;
      }
      const bool reasoning = text.type == FOUNDRY_LOCAL_TEXT_ITEM_TYPE_REASONING;

      flm_delta delta{};
      delta.version = FLM_API_VERSION;
      delta.kind = reasoning ? FLM_DELTA_REASONING : FLM_DELTA_TEXT;
      delta.text = text.text;
      delta.text_length = std::strlen(text.text);
      delta.finish_reason = FLM_FINISH_NONE;

      if (reasoning) {
        aggregate["reasoning"] = aggregate.value("reasoning", std::string()) + text.text;
      } else {
        aggregate["text"] = aggregate.value("text", std::string()) + text.text;
      }
      return context.EmitDelta(delta);
    }

    case FOUNDRY_LOCAL_ITEM_TOOL_CALL: {
      flToolCallData call{};
      call.version = FOUNDRY_LOCAL_API_VERSION;
      if (runtime.CheckNoThrow(runtime.item_api().GetToolCall(item, &call)) != FLM_OK) {
        return true;
      }

      nlohmann::json entry;
      entry["call_id"] = call.call_id != nullptr ? call.call_id : "";
      entry["name"] = call.name != nullptr ? call.name : "";
      entry["arguments"] = call.arguments != nullptr ? call.arguments : "{}";
      aggregate["tool_calls"].push_back(entry);

      flm_delta delta{};
      delta.version = FLM_API_VERSION;
      delta.kind = FLM_DELTA_TOOL_CALL;
      delta.tool_call_id = call.call_id;
      delta.tool_name = call.name;
      delta.tool_arguments_json = call.arguments;
      delta.finish_reason = FLM_FINISH_NONE;
      return context.EmitDelta(delta);
    }

    case FOUNDRY_LOCAL_ITEM_SPEECH_SEGMENT: {
      flSpeechSegmentData segment{};
      segment.version = FOUNDRY_LOCAL_API_VERSION;
      if (runtime.CheckNoThrow(runtime.item_api().GetSpeechSegment(item, &segment)) != FLM_OK) {
        return true;
      }
      const bool final_segment = segment.kind != FOUNDRY_LOCAL_SPEECH_SEGMENT_PARTIAL;

      flm_delta delta{};
      delta.version = FLM_API_VERSION;
      delta.kind = final_segment ? FLM_DELTA_SPEECH_FINAL : FLM_DELTA_SPEECH_PARTIAL;
      delta.text = segment.text;
      delta.text_length = segment.text != nullptr ? std::strlen(segment.text) : 0;
      delta.start_time_ms = DurationOrUnknown(segment.start_time_ms);
      delta.end_time_ms = DurationOrUnknown(segment.end_time_ms);
      delta.finish_reason = FLM_FINISH_NONE;

      // Only final segments are accumulated. A partial is a replacement hypothesis for
      // the current utterance, so appending them would repeat the same words.
      if (final_segment && segment.text != nullptr) {
        nlohmann::json entry;
        entry["text"] = segment.text;
        entry["start_time_ms"] = DurationOrUnknown(segment.start_time_ms);
        entry["end_time_ms"] = DurationOrUnknown(segment.end_time_ms);
        if (segment.language != nullptr) {
          entry["language"] = segment.language;
        }
        aggregate["segments"].push_back(std::move(entry));
        aggregate["text"] = aggregate.value("text", std::string()) + segment.text;
      }
      return context.EmitDelta(delta);
    }

    case FOUNDRY_LOCAL_ITEM_SPEECH_RESULT: {
      flSpeechResultData result{};
      result.version = FOUNDRY_LOCAL_API_VERSION;
      if (runtime.CheckNoThrow(runtime.item_api().GetSpeechResult(item, &result)) != FLM_OK) {
        return true;
      }
      // The aggregate result is authoritative over the segments we accumulated.
      if (result.text != nullptr) {
        aggregate["text"] = result.text;
      }
      if (result.language != nullptr) {
        aggregate["language"] = result.language;
      }
      if (result.duration_ms != FOUNDRY_LOCAL_DURATION_UNSET) {
        aggregate["duration_ms"] = result.duration_ms;
      }
      return true;
    }

    case FOUNDRY_LOCAL_ITEM_TENSOR: {
      flTensorData tensor{};
      tensor.version = FOUNDRY_LOCAL_API_VERSION;
      if (runtime.CheckNoThrow(runtime.item_api().GetTensor(item, &tensor)) != FLM_OK || tensor.data == nullptr) {
        return true;
      }
      if (tensor.data_type != FOUNDRY_LOCAL_TENSOR_FLOAT) {
        throw Error(FLM_ERROR_NOT_IMPLEMENTED, "only float32 embedding tensors are supported");
      }
      size_t count = 1;
      for (size_t i = 0; i < tensor.rank; ++i) {
        count *= static_cast<size_t>(tensor.shape[i]);
      }
      const size_t dimensions = tensor.rank > 0 ? static_cast<size_t>(tensor.shape[tensor.rank - 1]) : count;
      const auto* values = static_cast<const float*>(tensor.data);

      // Reshape into one vector per input, which is what an embeddings caller wants
      // regardless of whether the model emitted a batched or a flat tensor.
      for (size_t offset = 0; dimensions > 0 && offset + dimensions <= count; offset += dimensions) {
        aggregate["embeddings"].push_back(std::vector<float>(values + offset, values + offset + dimensions));
      }
      aggregate["dimensions"] = dimensions;
      return true;
    }

    default:
      return true;
  }
}

nlohmann::json Session::RunRequest(flRequest* request, JobContext& context) {
  const Runtime& runtime = Runtime::Instance();

  nlohmann::json aggregate = nlohmann::json::object();
  StreamState state{this, &context, &aggregate, false};

  auto callback = [](flStreamingCallbackData event, void* user_data) -> int {
    auto* stream = static_cast<StreamState*>(user_data);
    if (stream == nullptr || event.item_queue == nullptr) {
      return 0;
    }
    const Runtime& rt = Runtime::Instance();

    flItem* item = nullptr;
    while (rt.item_api().ItemQueue_TryPop(event.item_queue, &item)) {
      if (item == nullptr) {
        continue;
      }
      // The queue transfers ownership on pop, so every path below must release.
      bool keep_going = true;
      try {
        keep_going = stream->session->DispatchItem(item, *stream->context, *stream->aggregate);
      } catch (...) {
        rt.item_api().Item_Release(item);
        stream->cancelled = true;
        return 1;
      }
      rt.item_api().Item_Release(item);

      if (!keep_going || stream->context->IsCancelled()) {
        stream->cancelled = true;
        return 1;
      }
    }
    return 0;
  };

  runtime.Check(runtime.inference_api().Session_SetStreamingCallback(upstream_, callback, &state),
                "set streaming callback");

  // Always detach the callback before leaving: it points at `state`, which lives on this
  // stack frame, and the session outlives the call.
  struct CallbackGuard {
    const Runtime& runtime;
    flSession* session;
    ~CallbackGuard() {
      runtime.CheckNoThrow(runtime.inference_api().Session_SetStreamingCallback(session, nullptr, nullptr));
    }
  } guard{runtime, upstream_};

  flResponse* response = nullptr;
  flStatus* status = runtime.inference_api().Session_ProcessRequest(upstream_, request, &response);
  UpstreamHandle<flResponse, decltype(flInferenceApi::Response_Release)> owned_response(
      response, runtime.inference_api().Response_Release);

  if (status != nullptr) {
    if (context.IsCancelled() || state.cancelled) {
      // A cancelled request reports a transport-level failure upstream. Surfacing that
      // as an error would make every cancellation look like a bug to the app.
      runtime.CheckNoThrow(status);
      context.ThrowIfCancelled();
    }
    runtime.Check(status, "process request");
  }

  context.ThrowIfCancelled();

  // Drain non-streamed outputs. A non-streaming call delivers everything here, and a
  // streaming one may still append a final aggregate item.
  if (owned_response) {
    const size_t count = runtime.inference_api().Response_GetItemCount(owned_response.get());
    for (size_t i = 0; i < count; ++i) {
      const flItem* item = nullptr;
      if (runtime.CheckNoThrow(runtime.inference_api().Response_GetItem(owned_response.get(), i, &item)) != FLM_OK ||
          item == nullptr) {
        continue;
      }
      // Response items are owned by the response, so they are not released here.
      DispatchItem(item, context, aggregate);
    }

    flUsage usage{};
    usage.version = FOUNDRY_LOCAL_API_VERSION;
    if (runtime.CheckNoThrow(runtime.inference_api().Response_GetUsage(owned_response.get(), &usage)) == FLM_OK) {
      aggregate["usage"] = nlohmann::json{{"prompt_tokens", usage.prompt_tokens},
                                          {"completion_tokens", usage.completion_tokens},
                                          {"total_tokens", usage.total_tokens}};
    }

    const flm_finish_reason finish =
        MapFinishReason(runtime.inference_api().Response_GetFinishReason(owned_response.get()));
    aggregate["finish_reason"] = FinishReasonName(finish);

    flm_delta done{};
    done.version = FLM_API_VERSION;
    done.kind = FLM_DELTA_COMPLETED;
    done.finish_reason = finish;
    done.prompt_tokens = usage.prompt_tokens;
    done.completion_tokens = usage.completion_tokens;
    context.EmitDelta(done);
  }

  if (!aggregate.contains("text")) {
    aggregate["text"] = "";
  }
  return aggregate;
}

/* ------------------------------------------------------------------------- */
/* Chat                                                                       */
/* ------------------------------------------------------------------------- */

nlohmann::json Session::Complete(const nlohmann::json& request, JobContext& context) {
  if (type_ != SessionType::kChat) {
    throw Error(FLM_ERROR_INVALID_STATE,
                std::string("complete() requires a chat session, but this session is '") + ToString(type_) + "'");
  }
  if (!request.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "the request must be a JSON object");
  }

  // The runtime's generator state is single-threaded. Serializing here turns a crash
  // into a short wait for an app that fires two sends in a row.
  std::lock_guard<std::mutex> request_lock(request_mutex_);

  const auto messages = request.find("messages");
  if (messages == request.end() || !messages->is_array() || messages->empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "the request needs a non-empty 'messages' array");
  }

  if (const auto tools = request.find("tools"); tools != request.end()) {
    SyncToolDefinitions(*tools);
  }

  const Runtime& runtime = Runtime::Instance();
  ItemArena arena;
  std::vector<std::string> strings;
  std::vector<std::vector<uint8_t>> buffers;
  // Reserve up front: MESSAGE items borrow pointers into these vectors, and a
  // reallocation would leave the runtime holding dangling char*.
  strings.reserve(messages->size() * 8 + 8);
  buffers.reserve(messages->size() * 4);

  flRequest* raw_request = nullptr;
  runtime.Check(runtime.inference_api().Request_Create(&raw_request), "create request");
  UpstreamHandle<flRequest, decltype(flInferenceApi::Request_Release)> owned_request(
      raw_request, runtime.inference_api().Request_Release);

  nlohmann::json replayed = nlohmann::json::array();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    replayed = std::move(pending_history_);
    pending_history_ = nlohmann::json::array();
  }
  for (const auto& message : replayed) {
    flItem* item = MakeMessageItem(arena, message, strings, buffers);
    runtime.Check(runtime.inference_api().Request_AddItem(owned_request.get(), item, /*take_ownership=*/false),
                  "add history message");
  }

  for (const auto& message : *messages) {
    flItem* item = MakeMessageItem(arena, message, strings, buffers);
    runtime.Check(runtime.inference_api().Request_AddItem(owned_request.get(), item, /*take_ownership=*/false),
                  "add message");
  }

  // Per-request generation overrides. These do not touch session options, so a one-off
  // temperature change does not leak into the next turn.
  {
    flKeyValuePairs* pairs = nullptr;
    runtime.api().CreateKeyValuePairs(&pairs);
    UpstreamHandle<flKeyValuePairs, decltype(flApi::KeyValuePairs_Release)> owned_pairs(
        pairs, runtime.api().KeyValuePairs_Release);
    bool any = false;
    for (const char* key : kGenerationOptionKeys) {
      const auto it = request.find(key);
      if (it == request.end() || it->is_null()) {
        continue;
      }
      runtime.api().AddKeyValuePair(owned_pairs.get(), key, OptionValueToString(*it).c_str());
      any = true;
    }
    if (any) {
      runtime.Check(runtime.inference_api().Request_SetOptions(owned_request.get(), owned_pairs.get()),
                    "set request options");
    }
  }

  context.ReportProgress(0.0f, "generating");
  nlohmann::json result = RunRequest(owned_request.get(), context);
  context.ReportProgress(100.0f, "generating");

  if (keep_history_) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& message : *messages) {
      history_.push_back(message);
    }
    nlohmann::json assistant{{"role", "assistant"}, {"content", result.value("text", std::string())}};
    if (result.contains("tool_calls")) {
      assistant["tool_calls"] = result["tool_calls"];
    }
    history_.push_back(std::move(assistant));
  }

  return result;
}

nlohmann::json Session::SubmitToolResults(const nlohmann::json& tool_results, JobContext& context) {
  if (type_ != SessionType::kChat) {
    throw Error(FLM_ERROR_INVALID_STATE, "tool results are only meaningful for a chat session");
  }
  if (!tool_results.is_array() || tool_results.empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "tool results must be a non-empty array");
  }

  std::lock_guard<std::mutex> request_lock(request_mutex_);
  const Runtime& runtime = Runtime::Instance();

  ItemArena arena;
  std::vector<std::string> strings;
  strings.reserve(tool_results.size() * 2);

  flRequest* raw_request = nullptr;
  runtime.Check(runtime.inference_api().Request_Create(&raw_request), "create request");
  UpstreamHandle<flRequest, decltype(flInferenceApi::Request_Release)> owned_request(
      raw_request, runtime.inference_api().Request_Release);

  for (const auto& entry : tool_results) {
    const std::string call_id = entry.value("call_id", std::string());
    if (call_id.empty()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "each tool result needs a 'call_id'");
    }
    // Accept a JSON value as well as a string; app code usually has a structure, and
    // making every caller dump it themselves is needless friction.
    const auto result_it = entry.find("result");
    std::string result_text;
    if (result_it == entry.end()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "each tool result needs a 'result'");
    }
    result_text = result_it->is_string() ? result_it->get<std::string>() : result_it->dump();

    strings.push_back(call_id);
    const std::string& stored_id = strings.back();
    strings.push_back(std::move(result_text));
    const std::string& stored_result = strings.back();

    flItem* item = arena.Create(FOUNDRY_LOCAL_ITEM_TOOL_RESULT);
    flToolResultData data{};
    data.version = FOUNDRY_LOCAL_API_VERSION;
    data.call_id = stored_id.c_str();
    data.result = stored_result.c_str();
    runtime.Check(runtime.item_api().SetToolResult(item, &data), "set tool result");
    runtime.Check(runtime.inference_api().Request_AddItem(owned_request.get(), item, /*take_ownership=*/false),
                  "add tool result");
  }

  context.ReportProgress(0.0f, "generating");
  nlohmann::json result = RunRequest(owned_request.get(), context);
  context.ReportProgress(100.0f, "generating");

  if (keep_history_) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& entry : tool_results) {
      history_.push_back(nlohmann::json{{"role", "tool"},
                                        {"tool_call_id", entry.value("call_id", std::string())},
                                        {"content", entry.contains("result") && entry["result"].is_string()
                                                        ? entry["result"].get<std::string>()
                                                        : entry.value("result", nlohmann::json::object()).dump()}});
    }
    history_.push_back(nlohmann::json{{"role", "assistant"}, {"content", result.value("text", std::string())}});
  }

  return result;
}

/* ------------------------------------------------------------------------- */
/* Audio                                                                      */
/* ------------------------------------------------------------------------- */

nlohmann::json Session::Transcribe(const nlohmann::json& request, JobContext& context) {
  if (type_ != SessionType::kAudio) {
    throw Error(FLM_ERROR_INVALID_STATE,
                "transcribe() requires a session created with {\"type\": \"audio\"}");
  }

  std::lock_guard<std::mutex> request_lock(request_mutex_);
  const Runtime& runtime = Runtime::Instance();

  ItemArena arena;
  std::vector<std::vector<uint8_t>> buffers;
  buffers.reserve(1);

  flRequest* raw_request = nullptr;
  runtime.Check(runtime.inference_api().Request_Create(&raw_request), "create request");
  UpstreamHandle<flRequest, decltype(flInferenceApi::Request_Release)> owned_request(
      raw_request, runtime.inference_api().Request_Release);

  const bool streaming = request.value("streaming", false);

  // The queue item lives in this frame's arena, so the pointer must be cleared on every
  // exit path — including an exception from RunRequest — or PushAudio would later write
  // into freed memory.
  struct AudioQueueGuard {
    Session* session;
    ~AudioQueueGuard() {
      std::lock_guard<std::mutex> lock(session->mutex_);
      session->audio_queue_ = nullptr;
      session->audio_queue_item_ = nullptr;
    }
  } audio_guard{this};

  if (streaming) {
    // Live capture: the request carries a queue the app fills through PushAudio, so the
    // runtime can start decoding before recording finishes.
    flItem* queue_item = arena.Create(FOUNDRY_LOCAL_ITEM_QUEUE);
    flItemQueue* queue = nullptr;
    runtime.Check(runtime.item_api().GetQueue(queue_item, &queue), "get audio queue");
    {
      std::lock_guard<std::mutex> lock(mutex_);
      audio_queue_ = queue;
      audio_queue_item_ = queue_item;
    }
    runtime.Check(runtime.inference_api().Request_AddItem(owned_request.get(), queue_item, /*take_ownership=*/false),
                  "add audio queue");
  } else {
    flItem* item = MakeAudioItem(arena, request, buffers);
    runtime.Check(runtime.inference_api().Request_AddItem(owned_request.get(), item, /*take_ownership=*/false),
                  "add audio");
  }

  {
    flKeyValuePairs* pairs = nullptr;
    runtime.api().CreateKeyValuePairs(&pairs);
    UpstreamHandle<flKeyValuePairs, decltype(flApi::KeyValuePairs_Release)> owned_pairs(
        pairs, runtime.api().KeyValuePairs_Release);
    bool any = false;
    if (const auto it = request.find("language"); it != request.end() && it->is_string()) {
      runtime.api().AddKeyValuePair(owned_pairs.get(), "language", it->get<std::string>().c_str());
      any = true;
    }
    if (request.value("translate", false)) {
      runtime.api().AddKeyValuePair(owned_pairs.get(), "task", "translate");
      any = true;
    }
    if (any) {
      runtime.Check(runtime.inference_api().Request_SetOptions(owned_request.get(), owned_pairs.get()),
                    "set transcription options");
    }
  }

  context.ReportProgress(0.0f, "transcribing");
  nlohmann::json result = RunRequest(owned_request.get(), context);
  context.ReportProgress(100.0f, "transcribing");

  if (!result.contains("segments")) {
    result["segments"] = nlohmann::json::array();
  }
  return result;
}

void Session::PushAudio(const void* pcm_data, size_t byte_count, int32_t sample_rate, int32_t channels, bool is_final) {
  const Runtime& runtime = Runtime::Instance();

  flItemQueue* queue = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queue = audio_queue_;
  }
  if (queue == nullptr) {
    throw Error(FLM_ERROR_INVALID_STATE,
                "no streaming transcription is active",
                {{"hint", "call transcribe with {\"streaming\": true} before pushing audio"}});
  }

  if (byte_count > 0 && pcm_data != nullptr) {
    flItem* item = nullptr;
    runtime.Check(runtime.item_api().Create(FOUNDRY_LOCAL_ITEM_AUDIO, &item), "create audio chunk");
    UpstreamHandle<flItem, decltype(flItemApi::Item_Release)> owned_item(item, runtime.item_api().Item_Release);

    // Copy the caller's buffer. It is almost always a reused capture buffer that the
    // audio thread overwrites on the next callback.
    auto* copy = new uint8_t[byte_count];
    std::memcpy(copy, pcm_data, byte_count);

    flAudioData data{};
    data.version = FOUNDRY_LOCAL_API_VERSION;
    data.data = copy;
    data.mutable_data = copy;
    data.data_size = byte_count;
    data.format = "pcm";
    data.sample_rate = sample_rate;
    data.channels = channels;
    data.deleter = [](const flAudioData* audio, void*) { delete[] static_cast<uint8_t*>(audio->mutable_data); };

    flStatus* status = runtime.item_api().SetAudio(item, &data);
    if (status != nullptr) {
      delete[] copy;  // The item never took ownership, so the deleter will not run.
      runtime.Check(status, "set audio chunk");
    }

    runtime.Check(runtime.item_api().ItemQueue_Push(queue, owned_item.get()), "queue audio chunk");
    owned_item.release();  // The queue owns it now.
  }

  if (is_final) {
    runtime.item_api().ItemQueue_MarkFinished(queue);
  }
}

/* ------------------------------------------------------------------------- */
/* Embeddings                                                                 */
/* ------------------------------------------------------------------------- */

nlohmann::json Session::Embed(const nlohmann::json& request, JobContext& context) {
  if (type_ != SessionType::kEmbedding) {
    throw Error(FLM_ERROR_INVALID_STATE, "embed() requires a session created with {\"type\": \"embedding\"}");
  }

  const auto inputs = request.find("inputs");
  if (inputs == request.end() || !inputs->is_array() || inputs->empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "the request needs a non-empty 'inputs' array");
  }

  std::lock_guard<std::mutex> request_lock(request_mutex_);
  const Runtime& runtime = Runtime::Instance();

  ItemArena arena;
  std::vector<std::string> strings;
  strings.reserve(inputs->size());

  flRequest* raw_request = nullptr;
  runtime.Check(runtime.inference_api().Request_Create(&raw_request), "create request");
  UpstreamHandle<flRequest, decltype(flInferenceApi::Request_Release)> owned_request(
      raw_request, runtime.inference_api().Request_Release);

  for (const auto& input : *inputs) {
    if (!input.is_string()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "each embedding input must be a string");
    }
    strings.push_back(input.get<std::string>());
    flItem* item = MakeTextItem(arena, strings.back(), FOUNDRY_LOCAL_TEXT_ITEM_TYPE_DEFAULT);
    runtime.Check(runtime.inference_api().Request_AddItem(owned_request.get(), item, /*take_ownership=*/false),
                  "add embedding input");
  }

  context.ReportProgress(0.0f, "embedding");
  nlohmann::json result = RunRequest(owned_request.get(), context);
  context.ReportProgress(100.0f, "embedding");

  result.erase("text");
  if (!result.contains("embeddings")) {
    result["embeddings"] = nlohmann::json::array();
  }
  return result;
}

/* ------------------------------------------------------------------------- */
/* History                                                                    */
/* ------------------------------------------------------------------------- */

size_t Session::GetTurnCount() const {
  const Runtime& runtime = Runtime::Instance();
  return runtime.inference_api().Session_GetTurnCount(upstream_);
}

void Session::UndoTurns(size_t count) {
  const Runtime& runtime = Runtime::Instance();
  runtime.Check(runtime.inference_api().Session_UndoTurns(upstream_, count), "undo turns");

  // Mirror the rewind. Each turn is a user message plus an assistant reply, and any tool
  // messages that came between them.
  std::lock_guard<std::mutex> lock(mutex_);
  for (size_t undone = 0; undone < count && !history_.empty();) {
    const std::string role = history_.back().value("role", std::string());
    history_.erase(history_.end() - 1);
    if (role == "user") {
      ++undone;
    }
  }
}

void Session::ClearHistory() {
  const Runtime& runtime = Runtime::Instance();
  const size_t turns = runtime.inference_api().Session_GetTurnCount(upstream_);
  if (turns > 0) {
    runtime.Check(runtime.inference_api().Session_UndoTurns(upstream_, turns), "clear history");
  }
  std::lock_guard<std::mutex> lock(mutex_);
  history_ = nlohmann::json::array();
  pending_history_ = nlohmann::json::array();
}

nlohmann::json Session::ExportHistory() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return nlohmann::json{{"version", 1}, {"type", ToString(type_)}, {"messages", history_}};
}

void Session::RestoreHistory(const nlohmann::json& history) {
  if (!history.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "history must be a JSON object from flm_session_export_history_json");
  }
  const int version = history.value("version", 0);
  if (version != 1) {
    throw Error(FLM_ERROR_UNSUPPORTED_VERSION,
                "unsupported history format version " + std::to_string(version));
  }
  const auto messages = history.find("messages");
  if (messages == history.end() || !messages->is_array()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "history is missing a 'messages' array");
  }

  if (GetTurnCount() > 0) {
    throw Error(FLM_ERROR_INVALID_STATE, "history can only be restored into a session with no turns");
  }

  std::lock_guard<std::mutex> lock(mutex_);
  history_ = *messages;
  // Replayed with the next request rather than now: the runtime has no API to inject
  // history directly, and prefixing the next prompt produces the same conversation state.
  pending_history_ = *messages;
}

}  // namespace flm
