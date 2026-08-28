// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "session.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <unordered_set>

#include "encoding.h"

namespace flm {
namespace {

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

/// Known generation option keys that map to OGA search params.
struct GenOptionMapping {
  const char* json_key;
  const char* oga_key;
  bool is_number;
};

constexpr GenOptionMapping kGenOptions[] = {
    {"temperature", "temperature", true},
    {"top_p", "top_p", true},
    {"top_k", "top_k", true},
    {"max_output_tokens", "max_length", true},
    {"seed", "random_seed", true},
    {"do_sample", "do_sample", false},
};

struct LanguageIdMapping {
  std::string_view tag;
  int id;
};

// NVIDIA Nemotron Speech prompt IDs, matching the canonical mapping used by
// the pinned OGA streaming-ASR example.
constexpr LanguageIdMapping kNemotronLanguageIds[] = {
    {"en", 0},
    {"en-us", 0},
    {"en-gb", 1},
    {"es-es", 2},
    {"es", 3},
    {"es-us", 3},
    {"zh-cn", 4},
    {"hi", 6},
    {"hi-in", 6},
    {"ar", 7},
    {"ar-ar", 7},
    {"fr", 8},
    {"fr-fr", 8},
    {"de", 9},
    {"de-de", 9},
    {"ja", 10},
    {"ja-jp", 10},
    {"ru", 11},
    {"ru-ru", 11},
    {"pt-br", 12},
    {"pt", 13},
    {"pt-pt", 13},
    {"ko", 14},
    {"ko-kr", 14},
    {"it", 15},
    {"it-it", 15},
    {"nl", 16},
    {"nl-nl", 16},
    {"pl", 17},
    {"pl-pl", 17},
    {"tr", 18},
    {"tr-tr", 18},
    {"uk", 19},
    {"uk-ua", 19},
    {"ro", 20},
    {"ro-ro", 20},
    {"el", 21},
    {"el-gr", 21},
    {"cs", 22},
    {"cs-cz", 22},
    {"hu", 23},
    {"hu-hu", 23},
    {"sv", 24},
    {"sv-se", 24},
    {"da", 25},
    {"da-dk", 25},
    {"fi", 26},
    {"fi-fi", 26},
    {"sk", 28},
    {"sk-sk", 28},
    {"hr", 29},
    {"hr-hr", 29},
    {"bg", 30},
    {"bg-bg", 30},
    {"lt", 31},
    {"lt-lt", 31},
    {"th", 32},
    {"th-th", 32},
    {"vi", 33},
    {"vi-vn", 33},
    {"et", 60},
    {"et-ee", 60},
    {"lv", 61},
    {"lv-lv", 61},
    {"sl", 62},
    {"sl-si", 62},
    {"he", 64},
    {"he-il", 64},
    {"fr-ca", 100},
    {"auto", 101},
    {"mt", 102},
    {"mt-mt", 102},
    {"nb", 103},
    {"nb-no", 103},
    {"nn", 104},
    {"nn-no", 104},
};

int ResolveNemotronLanguageId(std::string_view language) {
  std::string normalized;
  normalized.reserve(language.size());
  for (const char ch : language) {
    const unsigned char value = static_cast<unsigned char>(ch);
    normalized.push_back(ch == '_' ? '-' : static_cast<char>(std::tolower(value)));
  }

  for (const auto& mapping : kNemotronLanguageIds) {
    if (mapping.tag == normalized) return mapping.id;
  }

  throw Error(FLM_ERROR_INVALID_ARGUMENT,
              "unsupported streaming transcription language '" + std::string(language) +
                  "'; provide a supported BCP-47 tag such as 'en', 'en-US', "
                  "'zh-CN', or 'auto'");
}

/* ------------------------------------------------------------------------- */
/* Multimodal content helpers                                                 */
/* ------------------------------------------------------------------------- */

struct MediaItem {
  enum Type { kImage, kAudio };
  Type type;
  std::vector<uint8_t> data;
};

/// Return true if any message in the array contains an image or audio content part.
bool HasMediaContent(const nlohmann::json& messages) {
  for (const auto& msg : messages) {
    if (!msg.contains("content") || !msg["content"].is_array()) continue;
    for (const auto& part : msg["content"]) {
      if (!part.is_object()) continue;
      const std::string t = part.value("type", "");
      if (t == "image" || t == "image_url" || t == "audio" || t == "input_audio") return true;
    }
  }
  return false;
}

/// Validate that no message in `earlier` has media; only the last in `latest` may.
void ValidateMediaPlacement(const nlohmann::json& earlier, const nlohmann::json& latest) {
  auto has_media = [](const nlohmann::json& msg) {
    if (!msg.contains("content") || !msg["content"].is_array()) return false;
    for (const auto& part : msg["content"]) {
      if (!part.is_object()) continue;
      const std::string t = part.value("type", "");
      if (t == "image" || t == "image_url" || t == "audio" || t == "input_audio") return true;
    }
    return false;
  };

  for (const auto& msg : earlier) {
    if (has_media(msg)) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT,
                  "media content is only allowed in the latest user message, "
                  "but conversation history contains media in an earlier message");
    }
  }
  for (size_t i = 0; i + 1 < latest.size(); ++i) {
    if (has_media(latest[i])) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT,
                  "media content is only allowed in the latest user message");
    }
  }
  if (latest.empty() || latest.back().value("role", std::string()) != "user") {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "media content must belong to the latest user message");
  }
}

/// Extract media buffers from a single message's content array.
std::vector<MediaItem> ExtractMedia(const nlohmann::json& message) {
  std::vector<MediaItem> items;
  if (!message.contains("content") || !message["content"].is_array()) return items;

  for (const auto& part : message["content"]) {
    if (!part.is_object()) continue;
    const std::string type = part.value("type", "");

    if (type == "image" || type == "image_url") {
      MediaItem item{};
      item.type = MediaItem::kImage;

      if (type == "image_url" && part.contains("image_url") && part["image_url"].is_object()) {
        const std::string url = part["image_url"].value("url", std::string());
        if (url.empty()) throw Error(FLM_ERROR_INVALID_ARGUMENT, "image_url has an empty url");
        if (url.size() > 5 && url.substr(0, 5) == "data:") {
          const size_t comma = url.find(',');
          if (comma == std::string::npos || url.substr(0, comma).find(";base64") == std::string::npos) {
            throw Error(FLM_ERROR_INVALID_ARGUMENT,
                        "image data URL must contain a base64 payload");
          }
          item.data = Base64Decode(url.substr(comma + 1));
        } else if (url.rfind("file://", 0) == 0) {
          item.data = ReadFileBytes(url.substr(7));
        } else if (url.find("://") != std::string::npos) {
          throw Error(FLM_ERROR_INVALID_ARGUMENT,
                      "remote image URLs are not supported; provide a local path or data URL");
        } else {
          item.data = ReadFileBytes(url);
        }
      } else if (part.contains("path") && part["path"].is_string()) {
        const std::string p = part["path"].get<std::string>();
        if (p.empty()) throw Error(FLM_ERROR_INVALID_ARGUMENT, "image path must not be empty");
        item.data = ReadFileBytes(p);
      } else if (part.contains("data_base64") && part["data_base64"].is_string()) {
        item.data = Base64Decode(part["data_base64"].get<std::string>());
      } else {
        throw Error(FLM_ERROR_INVALID_ARGUMENT,
                    "image part needs 'path', 'data_base64', or 'image_url'");
      }
      if (item.data.empty()) throw Error(FLM_ERROR_INVALID_ARGUMENT, "image data decoded to zero bytes");
      items.push_back(std::move(item));

    } else if (type == "audio" || type == "input_audio") {
      MediaItem item{};
      item.type = MediaItem::kAudio;

      if (part.contains("path") && part["path"].is_string()) {
        const std::string p = part["path"].get<std::string>();
        if (p.empty()) throw Error(FLM_ERROR_INVALID_ARGUMENT, "audio path must not be empty");
        item.data = ReadFileBytes(p);
      } else if (part.contains("data_base64") && part["data_base64"].is_string()) {
        item.data = Base64Decode(part["data_base64"].get<std::string>());
      } else if (part.contains("input_audio") && part["input_audio"].is_object()) {
        const auto& ia = part["input_audio"];
        if (ia.contains("data") && ia["data"].is_string()) {
          item.data = Base64Decode(ia["data"].get<std::string>());
        } else {
          throw Error(FLM_ERROR_INVALID_ARGUMENT, "input_audio object needs a 'data' field");
        }
      } else {
        throw Error(FLM_ERROR_INVALID_ARGUMENT,
                    "audio part needs 'path' or 'data_base64'");
      }
      if (item.data.empty()) throw Error(FLM_ERROR_INVALID_ARGUMENT, "audio data decoded to zero bytes");
      items.push_back(std::move(item));
    }
  }
  return items;
}

/* ------------------------------------------------------------------------- */
/* Tool definition normalization                                              */
/* ------------------------------------------------------------------------- */

/// Normalize SDK-shaped tool definitions ({name, description, parameters_json})
/// into the OpenAI function-calling shape expected by OGA chat templates.
nlohmann::json NormalizeToolsForTemplate(const nlohmann::json& tools) {
  if (!tools.is_array()) return nlohmann::json::array();

  nlohmann::json normalized = nlohmann::json::array();
  for (const auto& tool : tools) {
    if (!tool.is_object()) continue;

    // Already in OpenAI format.
    if (tool.value("type", "") == "function" && tool.contains("function")) {
      normalized.push_back(tool);
      continue;
    }

    const std::string name = tool.value("name", std::string());
    if (name.empty()) continue;

    nlohmann::json fn = {{"name", name}};
    if (tool.contains("description")) fn["description"] = tool["description"];

    if (tool.contains("parameters_json") && tool["parameters_json"].is_string()) {
      try {
        fn["parameters"] = nlohmann::json::parse(tool["parameters_json"].get<std::string>());
      } catch (const nlohmann::json::exception& error) {
        throw Error(FLM_ERROR_INVALID_ARGUMENT,
                    "tool '" + name + "' has invalid parameters_json: " + error.what());
      }
    } else if (tool.contains("parameters")) {
      fn["parameters"] = tool["parameters"];
    }

    normalized.push_back(nlohmann::json{{"type", "function"}, {"function", fn}});
  }
  return normalized;
}

/* ------------------------------------------------------------------------- */
/* Tool-call / reasoning streaming state machine                              */
/* ------------------------------------------------------------------------- */

enum class StreamState {
  kText,       // Normal visible text.
  kReasoning,  // Between BOR and EOR.
  kToolCall,   // Between BOT and EOT — accumulate, do not emit as text.
};

/// Try to parse `buffer` as either a single tool-call object or an array of them.
/// Each object must have "name" and "arguments" or "parameters".
/// Emits FLM_DELTA_TOOL_CALL for every parsed call, appends to the aggregate vector,
/// and returns true if anything was parsed. On malformed JSON returns false.
bool ParseAndEmitToolCalls(const std::string& buffer,
                           std::vector<nlohmann::json>& tool_calls,
                           uint64_t& counter,
                           JobContext& context) {
  nlohmann::json parsed;
  try {
    parsed = nlohmann::json::parse(buffer);
  } catch (...) {
    return false;
  }

  bool emitted = false;
  auto process_one = [&](const nlohmann::json& call) {
    if (!call.is_object()) return;
    const std::string name = call.value("name", std::string());
    if (name.empty()) return;

    std::string arguments;
    if (call.contains("arguments")) {
      arguments = call["arguments"].is_string() ? call["arguments"].get<std::string>() : call["arguments"].dump();
    } else if (call.contains("parameters")) {
      arguments = call["parameters"].is_string() ? call["parameters"].get<std::string>() : call["parameters"].dump();
    }

    const std::string call_id = "call_" + std::to_string(counter++);

    tool_calls.push_back(nlohmann::json{
        {"call_id", call_id},
        {"name", name},
        {"arguments", arguments}});

    flm_delta delta{};
    delta.version = FLM_API_VERSION;
    delta.kind = FLM_DELTA_TOOL_CALL;
    delta.tool_call_id = call_id.c_str();
    delta.tool_name = name.c_str();
    delta.tool_arguments_json = arguments.c_str();
    delta.finish_reason = FLM_FINISH_NONE;
    context.EmitDelta(delta);
    emitted = true;
  };

  if (parsed.is_array()) {
    for (const auto& item : parsed) process_one(item);
  } else {
    process_one(parsed);
  }
  return emitted;
}

float Float16ToFloat32(uint16_t value) noexcept {
  const uint32_t sign = static_cast<uint32_t>(value & 0x8000U) << 16U;
  const uint32_t exponent = (value >> 10U) & 0x1FU;
  uint32_t mantissa = value & 0x03FFU;
  uint32_t bits = 0;

  if (exponent == 0) {
    if (mantissa == 0) {
      bits = sign;
    } else {
      int32_t unbiased_exponent = -14;
      while ((mantissa & 0x0400U) == 0) {
        mantissa <<= 1U;
        --unbiased_exponent;
      }
      mantissa &= 0x03FFU;
      bits = sign |
             (static_cast<uint32_t>(unbiased_exponent + 127) << 23U) |
             (mantissa << 13U);
    }
  } else if (exponent == 0x1FU) {
    bits = sign | 0x7F800000U | (mantissa << 13U);
  } else {
    bits = sign | ((exponent + 112U) << 23U) | (mantissa << 13U);
  }

  float result = 0.0F;
  std::memcpy(&result, &bits, sizeof(result));
  return result;
}

float BFloat16ToFloat32(uint16_t value) noexcept {
  const uint32_t bits = static_cast<uint32_t>(value) << 16U;
  float result = 0.0F;
  std::memcpy(&result, &bits, sizeof(result));
  return result;
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

  // Store session-level options for generation.
  if (options.is_object()) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& [key, value] : options.items()) {
      options_[key] = value;
    }
  }

  // System prompt becomes the first history entry.
  if (const auto it = options.find("system_prompt"); it != options.end() && it->is_string()) {
    const std::string prompt = it->get<std::string>();
    if (!prompt.empty()) {
      history_.push_back(nlohmann::json{{"role", "system"}, {"content", prompt}});
    }
  }
}

Session::~Session() {
  ShutdownAudioQueue();
}

void Session::ShutdownAudioQueue() noexcept {
  audio_shutdown_.store(true, std::memory_order_release);
  audio_cv_.notify_all();
}

void Session::SetOptions(const nlohmann::json& options) {
  if (!options.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "session options must be a JSON object");
  }
  if (options.contains("type")) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "a session's type is fixed at creation; create a new session instead");
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (const auto it = options.find("keep_history"); it != options.end() && it->is_boolean()) {
    keep_history_ = it->get<bool>();
  }
  for (const auto& [key, value] : options.items()) {
    options_[key] = value;
  }
}

/* ------------------------------------------------------------------------- */
/* Prompt construction                                                        */
/* ------------------------------------------------------------------------- */

std::string Session::BuildPrompt(const nlohmann::json& messages, const nlohmann::json& tools,
                                 OgaTokenizer* tokenizer, bool preserve_media) {
  if (tokenizer == nullptr) {
    throw Error(FLM_ERROR_INVALID_STATE, "model tokenizer is not available");
  }

  // Include the full accumulated conversation history because each request creates a
  // fresh OGA generator.
  nlohmann::json all_messages = nlohmann::json::array();

  // Flatten a content array to a plain text string (text-only path and history).
  auto flatten_to_text = [](const nlohmann::json& message) -> nlohmann::json {
    nlohmann::json normalized = message;
    std::string text;
    for (const auto& part : message["content"]) {
      if (part.is_string()) {
        text += part.get<std::string>();
      } else if (part.is_object() && part.value("type", "") == "text") {
        text += part.value("text", std::string());
      }
    }
    normalized["content"] = std::move(text);
    return normalized;
  };

  // Keep content arrays but strip data payloads, retaining only type-only markers
  // so the chat template can insert the correct multimodal placeholders.
  auto strip_media_data = [](const nlohmann::json& message) -> nlohmann::json {
    nlohmann::json normalized = message;
    nlohmann::json parts = nlohmann::json::array();
    for (const auto& part : message["content"]) {
      if (part.is_string()) {
        parts.push_back(nlohmann::json{{"type", "text"}, {"text", part.get<std::string>()}});
      } else if (!part.is_object()) {
        continue;
      } else {
        const std::string t = part.value("type", "");
        if (t == "text") {
          parts.push_back(part);
        } else if (t == "image" || t == "image_url") {
          parts.push_back(nlohmann::json{{"type", "image"}});
        } else if (t == "audio" || t == "input_audio") {
          parts.push_back(nlohmann::json{{"type", "audio"}});
        }
      }
    }
    normalized["content"] = std::move(parts);
    return normalized;
  };

  auto append_message = [&](const nlohmann::json& message, bool may_have_media) {
    if (message.contains("content") && message["content"].is_array()) {
      if (may_have_media && preserve_media) {
        all_messages.push_back(strip_media_data(message));
      } else {
        all_messages.push_back(flatten_to_text(message));
      }
      return;
    }
    all_messages.push_back(message);
  };

  std::string explicit_template;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& msg : history_) {
      append_message(msg, /*may_have_media=*/false);
    }
    if (const auto it = options_.find("chat_template");
        it != options_.end() && it->is_string()) {
      explicit_template = it->get<std::string>();
    }
  }
  for (size_t i = 0; i < messages.size(); ++i) {
    // Only the last incoming message may carry media.
    const bool is_last = (i + 1 == messages.size());
    append_message(messages[i], is_last);
  }

  const std::string messages_str = all_messages.dump();
  const std::string tools_str = tools.is_array() && !tools.empty() ? tools.dump() : std::string();

  const char* out_string = nullptr;
  OgaResult* template_result = OgaTokenizerApplyChatTemplate(
      tokenizer,
      explicit_template.empty() ? nullptr : explicit_template.c_str(),
      messages_str.c_str(),
      tools_str.empty() ? nullptr : tools_str.c_str(),
      true,
      &out_string);

  if (template_result != nullptr) {
    const char* error = OgaResultGetError(template_result);
    const std::string message = error != nullptr ? error : "";
    OgaDestroyResult(template_result);
    if (!explicit_template.empty() || message.find("Empty chat template") == std::string::npos) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "apply chat template: " + message);
    }
    if (preserve_media) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT,
                  "multimodal chat requires a chat template in the model tokenizer configuration");
    }

    // Base completion models often omit a chat template. Keep path-based loading useful
    // for them with a deterministic plain-text fallback instead of requiring catalog
    // metadata or a model-specific alias.
    std::string fallback;
    for (const auto& item : all_messages) {
      fallback += item.value("role", std::string("user"));
      fallback += ": ";
      fallback += item.value("content", std::string());
      fallback += '\n';
    }
    fallback += "assistant: ";
    return fallback;
  }

  std::string result;
  if (out_string != nullptr) {
    result = out_string;
    OgaDestroyString(out_string);
  }
  return result;
}

/* ------------------------------------------------------------------------- */
/* Token generation loop                                                      */
/* ------------------------------------------------------------------------- */

nlohmann::json Session::Generate(const std::string& prompt, const nlohmann::json& gen_options,
                                 const nlohmann::json& tool_defs,
                                 Model::InferenceLease& lease, JobContext& context,
                                 OgaNamedTensors* mm_inputs,
                                 OgaMultiModalProcessor* mm_processor) {
  const Runtime& runtime = Runtime::Instance();
  OgaModel* oga_model = lease.oga_model();
  OgaTokenizer* tokenizer = lease.oga_tokenizer();

  // --- Determine prompt token count early (needed for max_length). ---
  size_t prompt_token_count = 0;
  OgaSequencesHandle sequences;

  if (mm_inputs != nullptr) {
    // Multimodal path: derive from input_ids tensor shape when available.
    OgaTensor* ids_tensor_raw = nullptr;
    OgaResult* ids_result = OgaNamedTensorsGet(mm_inputs, "input_ids", &ids_tensor_raw);
    if (ids_result == nullptr && ids_tensor_raw != nullptr) {
      OgaTensorHandle ids_tensor(ids_tensor_raw);
      size_t rank = 0;
      runtime.Check(OgaTensorGetShapeRank(ids_tensor.get(), &rank), "read input_ids rank");
      if (rank >= 1) {
        std::vector<int64_t> shape(rank);
        runtime.Check(OgaTensorGetShape(ids_tensor.get(), shape.data(), rank), "read input_ids shape");
        prompt_token_count = static_cast<size_t>(shape.back());
      }
    } else {
      if (ids_result) OgaDestroyResult(ids_result);
    }
  } else {
    // Text-only path: encode prompt.
    OgaSequences* seq_raw = nullptr;
    runtime.Check(OgaCreateSequences(&seq_raw), "create sequences");
    sequences = OgaSequencesHandle(seq_raw);
    runtime.Check(OgaTokenizerEncode(tokenizer, prompt.c_str(), sequences.get()), "encode prompt");
    prompt_token_count = OgaSequencesGetSequenceCount(sequences.get(), 0);
  }

  // Create generator params.
  OgaGeneratorParams* params_raw = nullptr;
  runtime.Check(OgaCreateGeneratorParams(oga_model, &params_raw), "create generator params");
  OgaGeneratorParamsHandle params(params_raw);

  // Apply generation options.
  nlohmann::json merged_options;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    merged_options = options_;
  }
  for (const auto& [key, value] : gen_options.items()) {
    merged_options[key] = value;
  }

  for (const auto& mapping : kGenOptions) {
    const auto it = merged_options.find(mapping.json_key);
    if (it == merged_options.end() || it->is_null()) continue;

    if (mapping.is_number) {
      double val = 0;
      if (it->is_number()) val = it->get<double>();
      else if (it->is_string()) {
        try { val = std::stod(it->get<std::string>()); } catch (...) { continue; }
      } else continue;

      const char* oga_key = mapping.oga_key;
      if (std::strcmp(mapping.json_key, "max_output_tokens") == 0) {
        val = static_cast<double>(prompt_token_count) + val;
        oga_key = "max_length";
      }
      runtime.Check(OgaGeneratorParamsSetSearchNumber(params.get(), oga_key, val),
                    std::string("set search number '") + oga_key + "'");
    } else {
      bool val = false;
      if (it->is_boolean()) val = it->get<bool>();
      else if (it->is_string()) val = it->get<std::string>() == "true";
      else continue;
      runtime.Check(OgaGeneratorParamsSetSearchBool(params.get(), mapping.oga_key, val),
                    std::string("set search bool '") + mapping.oga_key + "'");
    }
  }

  // Create generator.
  OgaGenerator* gen_raw = nullptr;
  runtime.Check(OgaCreateGenerator(oga_model, params.get(), &gen_raw), "create generator");
  OgaGeneratorHandle generator(gen_raw);

  // Seed the generator — multimodal vs text-only.
  if (mm_inputs != nullptr) {
    runtime.Check(OgaGenerator_SetInputs(generator.get(), mm_inputs), "set multimodal inputs");
    // Refine prompt_token_count from the generator if the tensor probe missed.
    if (prompt_token_count == 0) {
      prompt_token_count = OgaGenerator_TokenCount(generator.get());
    }
  } else {
    const int32_t* token_data = OgaSequencesGetSequenceData(sequences.get(), 0);
    runtime.Check(OgaGenerator_AppendTokens(generator.get(), token_data, prompt_token_count),
                  "append prompt tokens");
  }

  // Create tokenizer stream for incremental decoding.
  OgaTokenizerStream* stream_raw = nullptr;
  if (mm_processor != nullptr) {
    runtime.Check(OgaCreateTokenizerStreamFromProcessor(mm_processor, &stream_raw),
                  "create tokenizer stream from processor");
  } else {
    runtime.Check(OgaCreateTokenizerStream(tokenizer, &stream_raw), "create tokenizer stream");
  }
  OgaTokenizerStreamHandle token_stream(stream_raw);

  // --- Probe special token IDs for tool-call / reasoning parsing. ---
  const bool has_tools = tool_defs.is_array() && !tool_defs.empty();
  int32_t bot_id = -1, eot_id = -1, bor_id = -1, eor_id = -1;
  {
    auto probe = [&](auto fn, int32_t& out) {
      OgaResult* r = fn(tokenizer, &out);
      if (r) { OgaDestroyResult(r); out = -1; }
    };
    probe(OgaTokenizerGetBotTokenId, bot_id);
    probe(OgaTokenizerGetEotTokenId, eot_id);
    probe(OgaTokenizerGetBorTokenId, bor_id);
    probe(OgaTokenizerGetEorTokenId, eor_id);
  }

  // --- Streaming state ---
  StreamState state = StreamState::kText;
  StreamState pre_tool_state = StreamState::kText;
  std::string tool_buffer;
  std::vector<nlohmann::json> tool_calls_aggregate;
  std::string full_text;
  std::string full_reasoning;
  int64_t completion_tokens = 0;
  flm_finish_reason finish = FLM_FINISH_NONE;
  bool cancelled = false;

  auto request_cancel = [&]() {
    OgaResult* term = OgaGenerator_SetRuntimeOption(generator.get(), "terminate_session", "1");
    if (term) OgaDestroyResult(term);
    cancelled = true;
    finish = FLM_FINISH_CANCELLED;
  };

  auto consume_marker = [&](int32_t token_id) {
    const char* ignored = nullptr;
    runtime.Check(OgaTokenizerStreamDecode(token_stream.get(), token_id, &ignored),
                  "decode special token");
  };

  // --- Generation loop ---
  while (!OgaGenerator_IsDone(generator.get())) {
    if (context.IsCancelled() || OgaGenerator_IsSessionTerminated(generator.get())) {
      request_cancel();
      break;
    }

    OgaResult* step_result = OgaGenerator_GenerateNextToken(generator.get());
    if (step_result != nullptr) {
      const char* err = OgaResultGetError(step_result);
      std::string err_msg = err ? err : "generation error";
      OgaDestroyResult(step_result);
      if (OgaGenerator_IsSessionTerminated(generator.get())) {
        cancelled = true;
        finish = FLM_FINISH_CANCELLED;
        break;
      }
      throw Error(FLM_ERROR_INTERNAL, "generate next token: " + err_msg);
    }

    completion_tokens++;

    const int32_t* next_tokens = nullptr;
    size_t next_count = 0;
    runtime.Check(OgaGenerator_GetNextTokens(generator.get(), &next_tokens, &next_count), "get next tokens");

    if (next_count == 0 || next_tokens == nullptr) continue;
    const int32_t token_id = next_tokens[0];

    // --- State transitions on special tokens ---
    if (token_id == bor_id && bor_id >= 0 && state == StreamState::kText) {
      state = StreamState::kReasoning;
      consume_marker(token_id);
      continue;
    }
    if (token_id == eor_id && eor_id >= 0 && state == StreamState::kReasoning) {
      state = StreamState::kText;
      consume_marker(token_id);
      continue;
    }
    if (has_tools && token_id == bot_id && bot_id >= 0 &&
        (state == StreamState::kText || state == StreamState::kReasoning)) {
      pre_tool_state = state;
      state = StreamState::kToolCall;
      tool_buffer.clear();
      consume_marker(token_id);
      continue;
    }
    if (has_tools && token_id == eot_id && eot_id >= 0 && state == StreamState::kToolCall) {
      if (!ParseAndEmitToolCalls(tool_buffer, tool_calls_aggregate,
                                 next_tool_call_id_, context)) {
        full_text.append(tool_buffer);
        flm_delta delta{};
        delta.version = FLM_API_VERSION;
        delta.kind = FLM_DELTA_TEXT;
        delta.text = tool_buffer.c_str();
        delta.text_length = tool_buffer.size();
        delta.finish_reason = FLM_FINISH_NONE;
        if (!context.EmitDelta(delta)) {
          request_cancel();
        }
      }
      tool_buffer.clear();
      state = pre_tool_state;
      consume_marker(token_id);
      if (cancelled) break;
      continue;
    }

    // --- Decode the token ---
    const char* decoded = nullptr;
    OgaResult* decode_result = OgaTokenizerStreamDecode(token_stream.get(), token_id, &decoded);
    runtime.Check(decode_result, "decode generated token");

    if (decoded == nullptr || decoded[0] == '\0') continue;
    const size_t len = std::strlen(decoded);

    switch (state) {
      case StreamState::kText: {
        full_text.append(decoded, len);
        flm_delta delta{};
        delta.version = FLM_API_VERSION;
        delta.kind = FLM_DELTA_TEXT;
        delta.text = decoded;
        delta.text_length = len;
        delta.finish_reason = FLM_FINISH_NONE;
        if (!context.EmitDelta(delta)) {
          request_cancel();
        }
        break;
      }
      case StreamState::kReasoning: {
        full_reasoning.append(decoded, len);
        flm_delta delta{};
        delta.version = FLM_API_VERSION;
        delta.kind = FLM_DELTA_REASONING;
        delta.text = decoded;
        delta.text_length = len;
        delta.finish_reason = FLM_FINISH_NONE;
        if (!context.EmitDelta(delta)) {
          request_cancel();
        }
        break;
      }
      case StreamState::kToolCall:
        tool_buffer.append(decoded, len);
        break;
    }

    if (cancelled) break;
  }

  // --- Flush unterminated buffers as visible text rather than losing output. ---
  if (!cancelled && state == StreamState::kToolCall && !tool_buffer.empty()) {
    full_text.append(tool_buffer);
    flm_delta delta{};
    delta.version = FLM_API_VERSION;
    delta.kind = FLM_DELTA_TEXT;
    delta.text = tool_buffer.c_str();
    delta.text_length = tool_buffer.size();
    delta.finish_reason = FLM_FINISH_NONE;
    context.EmitDelta(delta);
    tool_buffer.clear();
  }

  // --- Determine finish reason ---
  if (finish == FLM_FINISH_NONE) {
    if (!tool_calls_aggregate.empty()) {
      finish = FLM_FINISH_TOOL_CALLS;
    } else {
      double max_len = 0;
      OgaResult* max_len_result = OgaGeneratorParamsGetSearchNumber(params.get(), "max_length", &max_len);
      if (max_len_result == nullptr) {
        if (max_len > 0 && static_cast<double>(prompt_token_count + completion_tokens) >= max_len) {
          finish = FLM_FINISH_LENGTH;
        } else {
          finish = FLM_FINISH_STOP;
        }
      } else {
        OgaDestroyResult(max_len_result);
        finish = FLM_FINISH_STOP;
      }
    }
  }

  nlohmann::json aggregate = nlohmann::json::object();
  aggregate["text"] = full_text;
  aggregate["finish_reason"] = FinishReasonName(finish);
  if (!tool_calls_aggregate.empty()) {
    aggregate["tool_calls"] = tool_calls_aggregate;
  }
  aggregate["usage"] = nlohmann::json{
      {"prompt_tokens", static_cast<int64_t>(prompt_token_count)},
      {"completion_tokens", completion_tokens},
      {"total_tokens", static_cast<int64_t>(prompt_token_count) + completion_tokens}};

  // Emit completion delta.
  flm_delta done{};
  done.version = FLM_API_VERSION;
  done.kind = FLM_DELTA_COMPLETED;
  done.finish_reason = finish;
  done.prompt_tokens = static_cast<int64_t>(prompt_token_count);
  done.completion_tokens = completion_tokens;
  context.EmitDelta(done);

  if (cancelled) {
    context.ThrowIfCancelled();
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

  std::lock_guard<std::mutex> request_lock(request_mutex_);

  const auto messages = request.find("messages");
  if (messages == request.end() || !messages->is_array() || messages->empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "the request needs a non-empty 'messages' array");
  }

  // Update tool definitions if provided.
  if (const auto tools = request.find("tools"); tools != request.end() && tools->is_array()) {
    std::lock_guard<std::mutex> lock(mutex_);
    tool_definitions_ = *tools;
  }

  nlohmann::json current_tools;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    current_tools = tool_definitions_;
  }

  // Normalize tool definitions to the OpenAI function shape for the chat template.
  const nlohmann::json template_tools = NormalizeToolsForTemplate(current_tools);

  // Acquire inference lease — holds the OGA model/tokenizer alive for the entire operation.
  Model::InferenceLease lease = model_->AcquireInferenceLease();
  auto runtime_lease = Runtime::Instance().AcquireOperationLease();
  const Runtime& runtime = Runtime::Instance();

  // Extract per-request generation options.
  nlohmann::json gen_options = nlohmann::json::object();
  for (const auto& mapping : kGenOptions) {
    const auto it = request.find(mapping.json_key);
    if (it != request.end() && !it->is_null()) {
      gen_options[mapping.json_key] = *it;
    }
  }

  // --- Detect multimodal content ---
  const bool multimodal = HasMediaContent(*messages);
  OgaNamedTensorsHandle mm_tensors;
  OgaMultiModalProcessorHandle mm_processor;
  OgaImagesHandle mm_images;
  OgaAudiosHandle mm_audios;
  // Owned buffers for media data must outlive the OGA objects.
  std::vector<MediaItem> media_items;

  std::string prompt;

  if (multimodal) {
    // Validate that only the latest user message carries media.
    nlohmann::json history_copy;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      history_copy = history_;
    }
    ValidateMediaPlacement(history_copy, *messages);

    // Extract media buffers from the last message.
    media_items = ExtractMedia(messages->back());
    if (media_items.empty()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT,
                  "multimodal content detected but no valid media extracted");
    }

    // Build prompt preserving media type markers for the chat template.
    prompt = BuildPrompt(*messages, template_tools, lease.oga_tokenizer(), /*preserve_media=*/true);

    // Separate images and audios, load via OGA.
    std::vector<const void*> image_ptrs;
    std::vector<size_t> image_sizes;
    std::vector<const void*> audio_ptrs;
    std::vector<size_t> audio_sizes;

    for (const auto& item : media_items) {
      if (item.type == MediaItem::kImage) {
        image_ptrs.push_back(item.data.data());
        image_sizes.push_back(item.data.size());
      } else {
        audio_ptrs.push_back(item.data.data());
        audio_sizes.push_back(item.data.size());
      }
    }

    if (!image_ptrs.empty()) {
      OgaImages* imgs_raw = nullptr;
      runtime.Check(OgaLoadImagesFromBuffers(image_ptrs.data(), image_sizes.data(),
                                             image_ptrs.size(), &imgs_raw),
                    "load images from buffers");
      mm_images = OgaImagesHandle(imgs_raw);
    }
    if (!audio_ptrs.empty()) {
      OgaAudios* auds_raw = nullptr;
      runtime.Check(OgaLoadAudiosFromBuffers(audio_ptrs.data(), audio_sizes.data(),
                                             audio_ptrs.size(), &auds_raw),
                    "load audios from buffers");
      mm_audios = OgaAudiosHandle(auds_raw);
    }

    context.ThrowIfCancelled();

    // Create multimodal processor and process prompt + media.
    OgaMultiModalProcessor* proc_raw = nullptr;
    runtime.Check(OgaCreateMultiModalProcessor(lease.oga_model(), &proc_raw),
                  "create multimodal processor");
    mm_processor = OgaMultiModalProcessorHandle(proc_raw);

    OgaNamedTensors* tensors_raw = nullptr;
    runtime.Check(OgaProcessorProcessImagesAndAudios(mm_processor.get(), prompt.c_str(),
                                                     mm_images.get(), mm_audios.get(),
                                                     &tensors_raw),
                  "process multimodal inputs");
    mm_tensors = OgaNamedTensorsHandle(tensors_raw);
  } else {
    // Text-only prompt.
    prompt = BuildPrompt(*messages, template_tools, lease.oga_tokenizer());
  }

  context.ReportProgress(0.0f, "generating");
  nlohmann::json result = Generate(prompt, gen_options, template_tools, lease, context,
                                   mm_tensors.get(), mm_processor.get());
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

  // Build tool result messages for the conversation.
  nlohmann::json tool_messages = nlohmann::json::array();
  for (const auto& entry : tool_results) {
    const std::string call_id = entry.value("call_id", std::string());
    if (call_id.empty()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "each tool result needs a 'call_id'");
    }
    const auto result_it = entry.find("result");
    if (result_it == entry.end()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "each tool result needs a 'result'");
    }
    std::string result_text = result_it->is_string() ? result_it->get<std::string>() : result_it->dump();
    tool_messages.push_back(nlohmann::json{
        {"role", "tool"}, {"tool_call_id", call_id}, {"content", result_text}});
  }

  nlohmann::json current_tools;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    current_tools = tool_definitions_;
  }
  const nlohmann::json template_tools = NormalizeToolsForTemplate(current_tools);

  // Acquire inference lease.
  Model::InferenceLease lease = model_->AcquireInferenceLease();
  auto runtime_lease = Runtime::Instance().AcquireOperationLease();

  // Re-build prompt including full history and the tool result messages.
  const std::string prompt = BuildPrompt(tool_messages, template_tools, lease.oga_tokenizer());

  context.ReportProgress(0.0f, "generating");
  nlohmann::json result = Generate(prompt, nlohmann::json::object(), template_tools, lease, context);
  context.ReportProgress(100.0f, "generating");

  if (keep_history_) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& entry : tool_results) {
      history_.push_back(nlohmann::json{
          {"role", "tool"},
          {"tool_call_id", entry.value("call_id", std::string())},
          {"content", entry.contains("result") && entry["result"].is_string()
                          ? entry["result"].get<std::string>()
                          : entry.value("result", nlohmann::json::object()).dump()}});
    }
    nlohmann::json assistant{{"role", "assistant"}, {"content", result.value("text", std::string())}};
    if (result.contains("tool_calls")) {
      assistant["tool_calls"] = result["tool_calls"];
    }
    history_.push_back(std::move(assistant));
  }

  return result;
}

/* ------------------------------------------------------------------------- */
/* Audio                                                                      */
/* ------------------------------------------------------------------------- */

namespace {

/// Supported Whisper language codes (ISO-639-1 and a few extended).
const std::unordered_set<std::string>& WhisperLanguages() {
  static const std::unordered_set<std::string> kLangs = {
      "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar",
      "sv", "it", "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu",
      "ta", "no", "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa",
      "lv", "bn", "sr", "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy", "ne", "mn",
      "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc",
      "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn",
      "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su"};
  return kLangs;
}

/// Emit a speech delta and return false if the consumer requested cancellation.
bool EmitSpeechDelta(JobContext& context, const char* text, size_t length) {
  flm_delta delta{};
  delta.version = FLM_API_VERSION;
  delta.kind = FLM_DELTA_SPEECH_FINAL;
  delta.text = text;
  delta.text_length = length;
  delta.finish_reason = FLM_FINISH_NONE;
  return context.EmitDelta(delta);
}

}  // namespace

std::string Session::BuildWhisperPrompt(const std::string& language, bool translate) {
  const auto& langs = WhisperLanguages();
  const std::string& lang = (!language.empty() && langs.count(language)) ? language : "en";
  const char* task = translate ? "translate" : "transcribe";
  return "<|startoftranscript|><|" + lang + "|><|" + task + "|><|notimestamps|>";
}

std::vector<float> Session::ConvertS16LEToFloat(const uint8_t* pcm_bytes, size_t byte_count) {
  const size_t sample_count = byte_count / 2;
  std::vector<float> samples(sample_count);
  for (size_t i = 0; i < sample_count; ++i) {
    int16_t sample;
    std::memcpy(&sample, pcm_bytes + i * 2, sizeof(int16_t));
    samples[i] = static_cast<float>(sample) / 32768.0f;
  }
  return samples;
}

nlohmann::json Session::Transcribe(const nlohmann::json& request, JobContext& context) {
  if (type_ != SessionType::kAudio) {
    throw Error(FLM_ERROR_INVALID_STATE,
                std::string("transcribe() requires an audio session, but this session is '") + ToString(type_) + "'");
  }
  if (!request.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "the transcription request must be a JSON object");
  }

  const bool streaming = request.value("streaming", false);
  if (streaming) {
    return TranscribeStreaming(request, context);
  }
  return TranscribeBatch(request, context);
}

nlohmann::json Session::TranscribeBatch(const nlohmann::json& request, JobContext& context) {
  std::lock_guard<std::mutex> request_lock(request_mutex_);
  const Runtime& runtime = Runtime::Instance();

  // --- Parse inputs ---
  const bool has_path = request.contains("path") && request["path"].is_string();
  const bool has_data = request.contains("data_base64") && request["data_base64"].is_string();
  if (!has_path && !has_data) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "transcription request needs 'path' (file path) or 'data_base64' (encoded audio bytes)");
  }

  const std::string language = request.value("language", std::string());
  const bool translate = request.value("translate", false);
  Model::InferenceLease lease = model_->AcquireInferenceLease();
  auto runtime_lease = Runtime::Instance().AcquireOperationLease();

  // --- Load audio ---
  OgaAudiosHandle audios;

  if (has_path) {
    const std::string path = request["path"].get<std::string>();
    if (path.empty()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "audio path must not be empty");
    }
    OgaAudios* audios_raw = nullptr;
    runtime.Check(OgaLoadAudio(path.c_str(), &audios_raw), "load audio file");
    audios.reset();
    audios = OgaAudiosHandle(audios_raw);
  } else {
    // data_base64 path — decode and load from buffer.
    const std::string format = request.value("format", std::string());

    // OgaLoadAudiosFromBuffers expects an encoded audio container (wav, mp3, flac, etc.).
    // Raw PCM cannot be loaded this way; reject it explicitly.
    if (format == "pcm" || format == "raw") {
      throw Error(FLM_ERROR_INVALID_ARGUMENT,
                  "raw PCM buffers are not supported for batch transcription; "
                  "use 'streaming: true' with flm_session_push_audio for raw PCM, "
                  "or provide an encoded container (wav, mp3, flac, ogg)");
    }

    std::vector<uint8_t> audio_bytes = Base64Decode(request["data_base64"].get<std::string>());
    if (audio_bytes.empty()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "data_base64 decoded to zero bytes");
    }

    const void* buffers[] = {audio_bytes.data()};
    const size_t sizes[] = {audio_bytes.size()};
    OgaAudios* audios_raw = nullptr;
    runtime.Check(OgaLoadAudiosFromBuffers(buffers, sizes, 1, &audios_raw),
                  "load audio from buffer");
    audios = OgaAudiosHandle(audios_raw);
  }

  context.ThrowIfCancelled();

  // --- Create multimodal processor ---
  OgaMultiModalProcessor* processor_raw = nullptr;
  runtime.Check(OgaCreateMultiModalProcessor(lease.oga_model(), &processor_raw),
                "create multimodal processor for audio");
  OgaMultiModalProcessorHandle processor(processor_raw);

  // --- Build Whisper prompt ---
  const std::string prompt = BuildWhisperPrompt(language, translate);

  // Use the multi-prompt overload (batch size 1) to work around the OGA bug where
  // single-prompt sets Payload::prompt but WhisperProcessor reads Payload::prompts.
  std::vector<const char*> prompts_vec = {prompt.c_str()};
  OgaStringArray* prompts_sa_raw = nullptr;
  runtime.Check(OgaCreateStringArrayFromStrings(prompts_vec.data(), prompts_vec.size(), &prompts_sa_raw),
                "create prompt string array");
  OgaStringArrayHandle prompts_sa(prompts_sa_raw);

  // --- Process audio + prompt into model inputs ---
  OgaNamedTensors* inputs_raw = nullptr;
  runtime.Check(OgaProcessorProcessAudiosAndPrompts(processor.get(), prompts_sa.get(), audios.get(), &inputs_raw),
                "process audio through multimodal processor");
  OgaNamedTensorsHandle inputs(inputs_raw);

  context.ThrowIfCancelled();

  // --- Create generator ---
  OgaGeneratorParams* params_raw = nullptr;
  runtime.Check(OgaCreateGeneratorParams(lease.oga_model(), &params_raw), "create audio generator params");
  OgaGeneratorParamsHandle params(params_raw);

  runtime.Check(OgaGeneratorParamsSetSearchNumber(params.get(), "batch_size", 1),
                "set audio batch_size");
  runtime.Check(OgaGeneratorParamsSetSearchNumber(params.get(), "max_length", 448),
                "set audio max_length");
  runtime.Check(OgaGeneratorParamsSetSearchBool(params.get(), "do_sample", false),
                "set audio do_sample");

  // Apply optional temperature.
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (const auto it = options_.find("temperature"); it != options_.end() && it->is_number()) {
      runtime.Check(OgaGeneratorParamsSetSearchNumber(params.get(), "temperature", it->get<double>()),
                    "set audio temperature");
    }
  }
  if (const auto it = request.find("temperature"); it != request.end() && it->is_number()) {
    runtime.Check(OgaGeneratorParamsSetSearchNumber(params.get(), "temperature", it->get<double>()),
                  "set audio temperature (request)");
  }

  OgaGenerator* gen_raw = nullptr;
  runtime.Check(OgaCreateGenerator(lease.oga_model(), params.get(), &gen_raw), "create audio generator");
  OgaGeneratorHandle generator(gen_raw);

  runtime.Check(OgaGenerator_SetInputs(generator.get(), inputs.get()), "set audio model inputs");

  OgaTokenizerStream* stream_raw = nullptr;
  runtime.Check(OgaCreateTokenizerStreamFromProcessor(processor.get(), &stream_raw),
                "create audio tokenizer stream");
  OgaTokenizerStreamHandle token_stream(stream_raw);

  context.ThrowIfCancelled();
  context.ReportProgress(0.0f, "transcribing");

  // --- Generation loop ---
  std::string full_text;
  int64_t completion_tokens = 0;
  bool cancelled = false;

  while (!OgaGenerator_IsDone(generator.get())) {
    if (context.IsCancelled() || OgaGenerator_IsSessionTerminated(generator.get())) {
      OgaResult* term = OgaGenerator_SetRuntimeOption(generator.get(), "terminate_session", "1");
      if (term) OgaDestroyResult(term);
      cancelled = true;
      break;
    }

    OgaResult* step = OgaGenerator_GenerateNextToken(generator.get());
    if (step != nullptr) {
      const char* err = OgaResultGetError(step);
      std::string err_msg = err ? err : "generation error";
      OgaDestroyResult(step);
      if (OgaGenerator_IsSessionTerminated(generator.get())) {
        cancelled = true;
        break;
      }
      throw Error(FLM_ERROR_INTERNAL, "audio generate next token: " + err_msg);
    }

    completion_tokens++;

    // Get just the latest token for streaming.
    const int32_t* next_tokens = nullptr;
    size_t next_count = 0;
    runtime.Check(OgaGenerator_GetNextTokens(generator.get(), &next_tokens, &next_count),
                  "get audio next tokens");

    if (next_count > 0 && next_tokens != nullptr) {
      // Stateful decoding preserves byte-level token sequences across callbacks.
      const char* decoded = nullptr;
      OgaResult* decode_result =
          OgaTokenizerStreamDecode(token_stream.get(), next_tokens[0], &decoded);
      if (decode_result == nullptr && decoded != nullptr && decoded[0] != '\0') {
        const size_t len = std::strlen(decoded);
        full_text.append(decoded, len);
        if (!EmitSpeechDelta(context, decoded, len)) {
          OgaResult* term = OgaGenerator_SetRuntimeOption(generator.get(), "terminate_session", "1");
          if (term) OgaDestroyResult(term);
          cancelled = true;
          break;
        }
      } else {
        if (decode_result) OgaDestroyResult(decode_result);
      }
    }
  }

  // Decode the full sequence for the final result text.
  if (!cancelled && !full_text.empty()) {
    // full_text already contains the streamed text; use it directly.
  } else if (!cancelled) {
    const int32_t num_tokens = static_cast<int32_t>(OgaGenerator_GetSequenceCount(generator.get(), 0));
    const int32_t* tokens = OgaGenerator_GetSequenceData(generator.get(), 0);
    if (num_tokens > 0 && tokens != nullptr) {
      const char* full_decoded = nullptr;
      OgaResult* dec = OgaProcessorDecode(processor.get(), tokens, static_cast<size_t>(num_tokens), &full_decoded);
      if (dec == nullptr && full_decoded) {
        full_text = full_decoded;
        OgaDestroyString(full_decoded);
      } else {
        if (dec) OgaDestroyResult(dec);
        if (full_decoded) OgaDestroyString(full_decoded);
      }
    }
  }

  const flm_finish_reason finish = cancelled ? FLM_FINISH_CANCELLED : FLM_FINISH_STOP;

  // Emit completion delta.
  flm_delta done{};
  done.version = FLM_API_VERSION;
  done.kind = FLM_DELTA_COMPLETED;
  done.finish_reason = finish;
  done.prompt_tokens = 0;
  done.completion_tokens = completion_tokens;
  context.EmitDelta(done);

  context.ReportProgress(100.0f, "transcribing");

  if (cancelled) {
    context.ThrowIfCancelled();
  }

  return nlohmann::json{
      {"text", full_text},
      {"language", language.empty() ? nlohmann::json(nullptr) : nlohmann::json(language)},
      {"segments", nlohmann::json::array()},
      {"finish_reason", FinishReasonName(finish)},
      {"usage", {{"prompt_tokens", 0}, {"completion_tokens", completion_tokens},
                 {"total_tokens", completion_tokens}}}};
}

nlohmann::json Session::TranscribeStreaming(const nlohmann::json& request, JobContext& context) {
  std::lock_guard<std::mutex> request_lock(request_mutex_);
  const Runtime& runtime = Runtime::Instance();

  Model::InferenceLease lease = model_->AcquireInferenceLease();
  auto runtime_lease = Runtime::Instance().AcquireOperationLease();

  // Reset the audio queue state for a new streaming session.
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    audio_queue_.clear();
    audio_shutdown_.store(false, std::memory_order_release);
  }

  // Create OGA streaming processor.
  OgaStreamingProcessor* sp_raw = nullptr;
  runtime.Check(OgaCreateStreamingProcessor(lease.oga_model(), &sp_raw),
                "create streaming processor");
  OgaStreamingProcessorHandle streaming_processor(sp_raw);

  // Create generator.
  OgaGeneratorParams* params_raw = nullptr;
  runtime.Check(OgaCreateGeneratorParams(lease.oga_model(), &params_raw),
                "create streaming audio generator params");
  OgaGeneratorParamsHandle params(params_raw);

  // Apply temperature from session/request.
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (const auto it = options_.find("temperature"); it != options_.end() && it->is_number()) {
      runtime.Check(OgaGeneratorParamsSetSearchNumber(params.get(), "temperature", it->get<double>()),
                    "set streaming audio temperature");
    }
  }
  if (const auto it = request.find("temperature"); it != request.end() && it->is_number()) {
    runtime.Check(OgaGeneratorParamsSetSearchNumber(params.get(), "temperature", it->get<double>()),
                  "set streaming audio temperature (request)");
  }

  OgaGenerator* gen_raw = nullptr;
  runtime.Check(OgaCreateGenerator(lease.oga_model(), params.get(), &gen_raw),
                "create streaming audio generator");
  OgaGeneratorHandle generator(gen_raw);

  // Nemotron accepts a numeric prompt ID rather than a BCP-47 tag.
  const std::string language = request.value("language", std::string());
  if (!language.empty()) {
    const std::string language_id = std::to_string(ResolveNemotronLanguageId(language));
    runtime.Check(
        OgaGenerator_SetRuntimeOption(generator.get(), "lang_id", language_id.c_str()),
        "set streaming transcription language");
  }

  // Create tokenizer stream for incremental decoding.
  OgaTokenizerStream* ts_raw = nullptr;
  runtime.Check(OgaCreateTokenizerStream(lease.oga_tokenizer(), &ts_raw),
                "create streaming audio tokenizer stream");
  OgaTokenizerStreamHandle token_stream(ts_raw);

  context.ReportProgress(0.0f, "streaming transcription");

  std::string full_text;
  int64_t completion_tokens = 0;
  bool cancelled = false;

  // Lambda: decode all available tokens from the generator after SetInputs.
  auto decode_tokens = [&]() {
    while (!OgaGenerator_IsDone(generator.get()) &&
           !OgaGenerator_IsSessionTerminated(generator.get()) &&
           !context.IsCancelled() &&
           !audio_shutdown_.load(std::memory_order_acquire)) {
      OgaResult* step = OgaGenerator_GenerateNextToken(generator.get());
      if (step != nullptr) {
        const char* err = OgaResultGetError(step);
        std::string err_msg = err ? err : "generation error";
        OgaDestroyResult(step);
        if (OgaGenerator_IsSessionTerminated(generator.get())) {
          cancelled = true;
          return;
        }
        throw Error(FLM_ERROR_INTERNAL, "streaming audio token generation: " + err_msg);
      }

      const int32_t* next_tokens = nullptr;
      size_t next_count = 0;
      runtime.Check(OgaGenerator_GetNextTokens(generator.get(), &next_tokens, &next_count),
                    "get streaming audio next tokens");

      if (next_count > 0 && next_tokens != nullptr) {
        const char* decoded = nullptr;
        OgaResult* dec = OgaTokenizerStreamDecode(token_stream.get(), next_tokens[0], &decoded);
        runtime.Check(dec, "decode streaming audio token");
        if (decoded != nullptr && decoded[0] != '\0') {
          completion_tokens++;
          const size_t len = std::strlen(decoded);
          full_text.append(decoded, len);
          if (!EmitSpeechDelta(context, decoded, len)) {
            cancelled = true;
            return;
          }
        }
      }
    }
  };

  // Lambda: feed float samples to the streaming processor and decode if ready.
  auto process_chunk = [&](const std::vector<float>& samples) {
    OgaNamedTensors* tensors_raw = nullptr;
    runtime.Check(OgaStreamingProcessorProcess(streaming_processor.get(), samples.data(),
                                               samples.size(), &tensors_raw),
                  "streaming processor process chunk");
    if (tensors_raw != nullptr) {
      OgaNamedTensorsHandle tensors(tensors_raw);
      runtime.Check(OgaGenerator_SetInputs(generator.get(), tensors.get()),
                    "set streaming audio inputs");
      decode_tokens();
    }
  };

  // Read from the audio queue until final or cancelled.
  while (!cancelled && !audio_shutdown_.load(std::memory_order_acquire)) {
    if (context.IsCancelled()) {
      cancelled = true;
      break;
    }

    AudioChunk chunk;
    bool got_chunk = false;
    {
      std::unique_lock<std::mutex> lock(audio_mutex_);
      // Wait up to 100ms for data to avoid blocking indefinitely.
      audio_cv_.wait_for(lock, std::chrono::milliseconds(100), [this] {
        return !audio_queue_.empty() || audio_shutdown_.load(std::memory_order_acquire);
      });
      if (!audio_queue_.empty()) {
        chunk = std::move(audio_queue_.front());
        audio_queue_.pop_front();
        got_chunk = true;
      }
    }

    if (audio_shutdown_.load(std::memory_order_acquire)) {
      cancelled = true;
      break;
    }

    if (!got_chunk) {
      continue;
    }

    // Process the audio chunk data.
    if (!chunk.data.empty()) {
      auto float_samples = ConvertS16LEToFloat(chunk.data.data(), chunk.data.size());
      process_chunk(float_samples);
    }

    if (cancelled) break;

    // Final chunk → flush remaining audio.
    if (chunk.is_final) {
      OgaNamedTensors* flush_raw = nullptr;
      runtime.Check(OgaStreamingProcessorFlush(streaming_processor.get(), &flush_raw),
                    "streaming processor flush");
      if (flush_raw != nullptr) {
        OgaNamedTensorsHandle flush_tensors(flush_raw);
        runtime.Check(OgaGenerator_SetInputs(generator.get(), flush_tensors.get()),
                      "set streaming audio flush inputs");
        decode_tokens();
      }
      break;
    }
  }

  if (cancelled || context.IsCancelled()) {
    OgaResult* term = OgaGenerator_SetRuntimeOption(generator.get(), "terminate_session", "1");
    if (term) OgaDestroyResult(term);
  }

  const flm_finish_reason finish = cancelled ? FLM_FINISH_CANCELLED : FLM_FINISH_STOP;

  flm_delta done{};
  done.version = FLM_API_VERSION;
  done.kind = FLM_DELTA_COMPLETED;
  done.finish_reason = finish;
  done.prompt_tokens = 0;
  done.completion_tokens = completion_tokens;
  context.EmitDelta(done);

  context.ReportProgress(100.0f, "streaming transcription");

  if (cancelled) {
    context.ThrowIfCancelled();
  }

  return nlohmann::json{
      {"text", full_text},
      {"language", language.empty() ? nlohmann::json(nullptr) : nlohmann::json(language)},
      {"segments", nlohmann::json::array()},
      {"finish_reason", FinishReasonName(finish)},
      {"usage", {{"prompt_tokens", 0}, {"completion_tokens", completion_tokens},
                 {"total_tokens", completion_tokens}}}};
}

void Session::PushAudio(const void* pcm_data, size_t byte_count, int32_t sample_rate,
                        int32_t channels, bool is_final) {
  if (type_ != SessionType::kAudio) {
    throw Error(FLM_ERROR_INVALID_STATE,
                "push_audio requires an audio session");
  }
  // Validate: only mono 16-kHz signed-16 little-endian PCM is supported.
  if (sample_rate != 0 && sample_rate != 16000) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "push_audio requires 16000 Hz sample rate, got " + std::to_string(sample_rate));
  }
  if (channels != 0 && channels != 1) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "push_audio requires mono (1 channel), got " + std::to_string(channels));
  }
  if (!is_final && (pcm_data == nullptr || byte_count == 0)) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "push_audio requires non-null pcm_data with byte_count > 0 (unless is_final)");
  }
  if (byte_count % 2 != 0) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT,
                "push_audio byte_count must be even (16-bit samples), got " + std::to_string(byte_count));
  }

  AudioChunk chunk;
  if (pcm_data != nullptr && byte_count > 0) {
    const auto* bytes = static_cast<const uint8_t*>(pcm_data);
    chunk.data.assign(bytes, bytes + byte_count);
  }
  chunk.is_final = is_final;

  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    audio_queue_.push_back(std::move(chunk));
  }
  audio_cv_.notify_one();
}

/* ------------------------------------------------------------------------- */
/* Embeddings                                                                 */
/* ------------------------------------------------------------------------- */

nlohmann::json Session::Embed(const nlohmann::json& request, JobContext& context) {
  if (type_ != SessionType::kEmbedding) {
    throw Error(FLM_ERROR_INVALID_STATE,
                "embed() requires a session created with {\"type\":\"embedding\"}");
  }
  if (!request.is_object()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "the embedding request must be a JSON object");
  }
  const auto inputs = request.find("inputs");
  if (inputs == request.end() || !inputs->is_array() || inputs->empty()) {
    throw Error(FLM_ERROR_INVALID_ARGUMENT, "the embedding request needs a non-empty 'inputs' array");
  }

  std::lock_guard<std::mutex> request_lock(request_mutex_);
  Model::InferenceLease lease = model_->AcquireInferenceLease();
  auto runtime_lease = Runtime::Instance().AcquireOperationLease();
  const Runtime& runtime = Runtime::Instance();

  std::string output_name = "hidden_states";
  bool normalize = true;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    output_name = options_.value("output_name", output_name);
    normalize = options_.value("normalize", normalize);
  }
  output_name = request.value("output_name", output_name);
  normalize = request.value("normalize", normalize);

  nlohmann::json embeddings = nlohmann::json::array();
  size_t dimensions = 0;

  for (size_t input_index = 0; input_index < inputs->size(); ++input_index) {
    context.ThrowIfCancelled();
    const auto& input = (*inputs)[input_index];
    if (!input.is_string()) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "each embedding input must be a string",
                  {{"index", input_index}});
    }

    OgaSequences* sequences_raw = nullptr;
    runtime.Check(OgaCreateSequences(&sequences_raw), "create embedding sequences");
    OgaSequencesHandle sequences(sequences_raw);
    runtime.Check(OgaTokenizerEncode(lease.oga_tokenizer(), input.get_ref<const std::string&>().c_str(),
                                     sequences.get()),
                  "encode embedding input");

    const int32_t* eos_ids = nullptr;
    size_t eos_count = 0;
    runtime.Check(OgaTokenizerGetEosTokenIds(lease.oga_tokenizer(), &eos_ids, &eos_count),
                  "get embedding EOS token");
    if (eos_count > 0 && eos_ids != nullptr) {
      runtime.Check(OgaAppendTokenToSequence(eos_ids[0], sequences.get(), 0),
                    "append embedding EOS token");
    }

    const size_t token_count = OgaSequencesGetSequenceCount(sequences.get(), 0);
    if (token_count == 0) {
      throw Error(FLM_ERROR_INVALID_ARGUMENT, "embedding input tokenized to an empty sequence",
                  {{"index", input_index}});
    }

    OgaGeneratorParams* params_raw = nullptr;
    runtime.Check(OgaCreateGeneratorParams(lease.oga_model(), &params_raw),
                  "create embedding generator params");
    OgaGeneratorParamsHandle params(params_raw);
    runtime.Check(OgaGeneratorParamsSetSearchNumber(params.get(), "batch_size", 1.0),
                  "set embedding batch size");
    runtime.Check(OgaGeneratorParamsSetSearchNumber(
                      params.get(), "max_length", static_cast<double>(token_count + 1)),
                  "set embedding maximum length");

    OgaGenerator* generator_raw = nullptr;
    runtime.Check(OgaCreateGenerator(lease.oga_model(), params.get(), &generator_raw),
                  "create embedding generator");
    OgaGeneratorHandle generator(generator_raw);
    runtime.Check(OgaGenerator_AppendTokenSequences(generator.get(), sequences.get()),
                  "append embedding tokens");
    runtime.Check(OgaGenerator_GenerateNextToken(generator.get()),
                  "run embedding model");

    OgaTensor* tensor_raw = nullptr;
    runtime.Check(OgaGenerator_GetOutput(generator.get(), output_name.c_str(), &tensor_raw),
                  "read embedding output '" + output_name + "'");
    OgaTensorHandle tensor(tensor_raw);

    size_t rank = 0;
    runtime.Check(OgaTensorGetShapeRank(tensor.get(), &rank), "read embedding tensor rank");
    if (rank == 0) {
      throw Error(FLM_ERROR_INTERNAL, "embedding output is a scalar",
                  {{"output_name", output_name}});
    }
    std::vector<int64_t> shape(rank);
    runtime.Check(OgaTensorGetShape(tensor.get(), shape.data(), shape.size()),
                  "read embedding tensor shape");

    size_t element_count = 1;
    for (const int64_t dimension : shape) {
      if (dimension <= 0 ||
          static_cast<uint64_t>(dimension) >
              static_cast<uint64_t>(std::numeric_limits<size_t>::max() / element_count)) {
        throw Error(FLM_ERROR_INTERNAL, "embedding output has an invalid shape",
                    {{"output_name", output_name}, {"shape", shape}});
      }
      element_count *= static_cast<size_t>(dimension);
    }
    const size_t vector_size = static_cast<size_t>(shape.back());
    if (vector_size == 0 || element_count < vector_size) {
      throw Error(FLM_ERROR_INTERNAL, "embedding output has no vector dimension",
                  {{"output_name", output_name}, {"shape", shape}});
    }

    OgaElementType element_type = OgaElementType_undefined;
    runtime.Check(OgaTensorGetType(tensor.get(), &element_type), "read embedding tensor type");
    void* raw_data = nullptr;
    runtime.Check(OgaTensorGetData(tensor.get(), &raw_data), "read embedding tensor data");
    if (raw_data == nullptr) {
      throw Error(FLM_ERROR_INTERNAL, "embedding output has no data",
                  {{"output_name", output_name}});
    }

    const size_t offset = element_count - vector_size;
    std::vector<float> values(vector_size);
    switch (element_type) {
      case OgaElementType_float32: {
        const auto* data = static_cast<const float*>(raw_data);
        std::copy(data + offset, data + offset + vector_size, values.begin());
        break;
      }
      case OgaElementType_float16: {
        const auto* data = static_cast<const uint16_t*>(raw_data);
        for (size_t i = 0; i < vector_size; ++i) {
          values[i] = Float16ToFloat32(data[offset + i]);
        }
        break;
      }
      case OgaElementType_bfloat16: {
        const auto* data = static_cast<const uint16_t*>(raw_data);
        for (size_t i = 0; i < vector_size; ++i) {
          values[i] = BFloat16ToFloat32(data[offset + i]);
        }
        break;
      }
      case OgaElementType_float64: {
        const auto* data = static_cast<const double*>(raw_data);
        for (size_t i = 0; i < vector_size; ++i) {
          values[i] = static_cast<float>(data[offset + i]);
        }
        break;
      }
      default:
        throw Error(FLM_ERROR_NOT_IMPLEMENTED,
                    "embedding output uses an unsupported tensor type",
                    {{"output_name", output_name}, {"element_type", static_cast<int>(element_type)}});
    }

    if (normalize) {
      double norm_squared = 0.0;
      for (const float value : values) {
        norm_squared += static_cast<double>(value) * static_cast<double>(value);
      }
      if (norm_squared > 0.0) {
        const float inverse_norm = static_cast<float>(1.0 / std::sqrt(norm_squared));
        for (float& value : values) {
          value *= inverse_norm;
        }
      }
    }

    if (dimensions == 0) {
      dimensions = vector_size;
    } else if (dimensions != vector_size) {
      throw Error(FLM_ERROR_INTERNAL, "embedding dimensions changed between inputs",
                  {{"expected", dimensions}, {"actual", vector_size}, {"index", input_index}});
    }
    embeddings.push_back(std::move(values));
    context.ReportProgress(
        static_cast<float>(input_index + 1) / static_cast<float>(inputs->size()) * 100.0F,
        "embedding");
  }

  return nlohmann::json{{"embeddings", std::move(embeddings)},
                        {"dimensions", dimensions}};
}

/* ------------------------------------------------------------------------- */
/* History                                                                    */
/* ------------------------------------------------------------------------- */

size_t Session::GetTurnCount() const {
  std::lock_guard<std::mutex> lock(mutex_);
  // Count user messages as turns (each user message + its reply = one turn).
  size_t count = 0;
  for (const auto& msg : history_) {
    if (msg.value("role", "") == "user") {
      count++;
    }
  }
  return count;
}

void Session::UndoTurns(size_t count) {
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
  std::lock_guard<std::mutex> lock(mutex_);
  history_ = nlohmann::json::array();
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

  std::lock_guard<std::mutex> lock(mutex_);
  // Check turn count inline to avoid recursive mutex lock from GetTurnCount().
  size_t user_count = 0;
  for (const auto& msg : history_) {
    if (msg.value("role", "") == "user") {
      user_count++;
    }
  }
  if (user_count > 0) {
    throw Error(FLM_ERROR_INVALID_STATE, "history can only be restored into a session with no turns");
  }

  history_ = *messages;
}

}  // namespace flm