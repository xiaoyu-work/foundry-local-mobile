// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "session.h"

#include <algorithm>
#include <cstring>

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

/// Render a JSON value as a string for OGA generation params.
std::string OptionValueToString(const nlohmann::json& value) {
  if (value.is_string()) return value.get<std::string>();
  if (value.is_boolean()) return value.get<bool>() ? "true" : "false";
  return value.dump();
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

Session::~Session() = default;

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
                                 OgaTokenizer* tokenizer) {
  if (tokenizer == nullptr) {
    throw Error(FLM_ERROR_INVALID_STATE, "model tokenizer is not available");
  }

  // Include the full accumulated conversation history because each request creates a
  // fresh OGA generator. Normalize rich content to the text shape accepted by ordinary
  // chat templates; multimodal requests are rejected separately until that path is
  // implemented.
  nlohmann::json all_messages = nlohmann::json::array();
  auto append_message = [&all_messages](const nlohmann::json& message) {
    if (message.contains("content") && message["content"].is_array()) {
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
      all_messages.push_back(std::move(normalized));
      return;
    }
    all_messages.push_back(message);
  };

  std::string explicit_template;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& msg : history_) {
      append_message(msg);
    }
    if (const auto it = options_.find("chat_template");
        it != options_.end() && it->is_string()) {
      explicit_template = it->get<std::string>();
    }
  }
  for (const auto& msg : messages) {
    append_message(msg);
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
                                 Model::InferenceLease& lease, JobContext& context) {
  const Runtime& runtime = Runtime::Instance();
  OgaModel* oga_model = lease.oga_model();
  OgaTokenizer* tokenizer = lease.oga_tokenizer();

  // Encode prompt to tokens.
  OgaSequences* sequences_raw = nullptr;
  runtime.Check(OgaCreateSequences(&sequences_raw), "create sequences");
  OgaSequencesHandle sequences(sequences_raw);

  runtime.Check(OgaTokenizerEncode(tokenizer, prompt.c_str(), sequences.get()), "encode prompt");

  const size_t prompt_token_count = OgaSequencesGetSequenceCount(sequences.get(), 0);

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
  // Per-request options override session-level ones.
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

      // Map max_output_tokens to max_length = prompt_token_count + max_output_tokens.
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

  // Append prompt tokens.
  const int32_t* token_data = OgaSequencesGetSequenceData(sequences.get(), 0);
  runtime.Check(OgaGenerator_AppendTokens(generator.get(), token_data,
                                          prompt_token_count),
                "append prompt tokens");

  // Create tokenizer stream for incremental decoding.
  OgaTokenizerStream* stream_raw = nullptr;
  runtime.Check(OgaCreateTokenizerStream(tokenizer, &stream_raw), "create tokenizer stream");
  OgaTokenizerStreamHandle token_stream(stream_raw);

  // Generation loop.
  nlohmann::json aggregate = nlohmann::json::object();
  std::string full_text;
  int64_t completion_tokens = 0;
  flm_finish_reason finish = FLM_FINISH_NONE;
  bool cancelled = false;

  while (!OgaGenerator_IsDone(generator.get())) {
    if (context.IsCancelled() || OgaGenerator_IsSessionTerminated(generator.get())) {
      // Request OGA-level termination so the engine can clean up cooperatively.
      OgaResult* term_result = OgaGenerator_SetRuntimeOption(
          generator.get(), "terminate_session", "1");
      if (term_result != nullptr) {
        OgaDestroyResult(term_result);
      }
      cancelled = true;
      finish = FLM_FINISH_CANCELLED;
      break;
    }

    OgaResult* step_result = OgaGenerator_GenerateNextToken(generator.get());
    if (step_result != nullptr) {
      const char* err = OgaResultGetError(step_result);
      std::string err_msg = err ? err : "generation error";
      OgaDestroyResult(step_result);
      // If session was terminated (cooperative cancellation), treat as cancel.
      if (OgaGenerator_IsSessionTerminated(generator.get())) {
        cancelled = true;
        finish = FLM_FINISH_CANCELLED;
        break;
      }
      throw Error(FLM_ERROR_INTERNAL, "generate next token: " + err_msg);
    }

    completion_tokens++;

    // Get the newly generated token.
    const int32_t* next_tokens = nullptr;
    size_t next_count = 0;
    runtime.Check(OgaGenerator_GetNextTokens(generator.get(), &next_tokens, &next_count), "get next tokens");

    if (next_count > 0 && next_tokens != nullptr) {
      const char* decoded = nullptr;
      OgaResult* decode_result = OgaTokenizerStreamDecode(token_stream.get(), next_tokens[0], &decoded);
      runtime.Check(decode_result, "decode generated token");
      if (decoded != nullptr && decoded[0] != '\0') {
        const size_t len = std::strlen(decoded);
        full_text.append(decoded, len);

        // Emit streaming delta.
        flm_delta delta{};
        delta.version = FLM_API_VERSION;
        delta.kind = FLM_DELTA_TEXT;
        delta.text = decoded;
        delta.text_length = len;
        delta.finish_reason = FLM_FINISH_NONE;

        if (!context.EmitDelta(delta)) {
          // Consumer requested cancellation — signal OGA termination.
          OgaResult* term_result = OgaGenerator_SetRuntimeOption(
              generator.get(), "terminate_session", "1");
          if (term_result != nullptr) {
            OgaDestroyResult(term_result);
          }
          cancelled = true;
          finish = FLM_FINISH_CANCELLED;
          break;
        }
      }
    }
  }

  if (finish == FLM_FINISH_NONE) {
    // Check if we hit max length.
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

  aggregate["text"] = full_text;
  aggregate["finish_reason"] = FinishReasonName(finish);
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

  // Acquire inference lease — holds the OGA model/tokenizer alive for the entire operation.
  Model::InferenceLease lease = model_->AcquireInferenceLease();

  // Build the prompt using the chat template (includes full conversation history).
  const std::string prompt = BuildPrompt(*messages, current_tools, lease.oga_tokenizer());

  // Extract per-request generation options.
  nlohmann::json gen_options = nlohmann::json::object();
  for (const auto& mapping : kGenOptions) {
    const auto it = request.find(mapping.json_key);
    if (it != request.end() && !it->is_null()) {
      gen_options[mapping.json_key] = *it;
    }
  }

  context.ReportProgress(0.0f, "generating");
  nlohmann::json result = Generate(prompt, gen_options, lease, context);
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

  // Acquire inference lease.
  Model::InferenceLease lease = model_->AcquireInferenceLease();

  // Re-build prompt including full history and the tool result messages.
  const std::string prompt = BuildPrompt(tool_messages, current_tools, lease.oga_tokenizer());

  context.ReportProgress(0.0f, "generating");
  nlohmann::json result = Generate(prompt, nlohmann::json::object(), lease, context);
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
    history_.push_back(nlohmann::json{{"role", "assistant"}, {"content", result.value("text", std::string())}});
  }

  return result;
}

/* ------------------------------------------------------------------------- */
/* Audio                                                                      */
/* ------------------------------------------------------------------------- */

nlohmann::json Session::Transcribe(const nlohmann::json& /*request*/, JobContext& /*context*/) {
  throw Error(FLM_ERROR_NOT_IMPLEMENTED,
              "audio transcription is not yet implemented in the direct OGA backend");
}

void Session::PushAudio(const void* /*pcm_data*/, size_t /*byte_count*/, int32_t /*sample_rate*/,
                        int32_t /*channels*/, bool /*is_final*/) {
  throw Error(FLM_ERROR_NOT_IMPLEMENTED,
              "audio push is not yet implemented in the direct OGA backend");
}

/* ------------------------------------------------------------------------- */
/* Embeddings                                                                 */
/* ------------------------------------------------------------------------- */

nlohmann::json Session::Embed(const nlohmann::json& /*request*/, JobContext& /*context*/) {
  throw Error(FLM_ERROR_NOT_IMPLEMENTED,
              "embedding is not yet implemented in the direct OGA backend");
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