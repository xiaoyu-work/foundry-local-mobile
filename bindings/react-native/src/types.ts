// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------

export type LogLevel =
  | 'verbose'
  | 'debug'
  | 'info'
  | 'warning'
  | 'error'
  | 'fatal'
  | 'off';

export interface FoundryLocalConfig {
  appName: string;
  /** Override the sandbox path (defaults to the app's private data dir). */
  appDataDir?: string;
  logLevel?: LogLevel;
  autoUnloadOnBackground?: boolean;
  /** 0 = derive from the number of CPU cores. */
  jobPoolThreads?: number;
}

// -----------------------------------------------------------------------------
// Device profile
// -----------------------------------------------------------------------------

export type FlmDevice = 'unknown' | 'cpu' | 'gpu' | 'npu';
export type NetworkKind = 'unknown' | 'unmetered' | 'metered' | 'offline';
export type ThermalState = 'nominal' | 'fair' | 'serious' | 'critical' | null;

export interface ExecutionProviderInfo {
  name: string;
  device: FlmDevice;
  available: boolean;
  priority: number;
}

export interface DeviceProfile {
  platform: string;
  osVersion: string;
  deviceModel: string;
  soc: string | null;
  abi: string;
  cpuCores: number;
  totalMemoryBytes: number;
  availableMemoryBytes: number;
  availableStorageBytes: number;
  hasNpu: boolean;
  hasGpu: boolean;
  executionProviders: readonly ExecutionProviderInfo[];
  thermalState: ThermalState;
  lowPowerMode: boolean;
  network: NetworkKind;
}

// -----------------------------------------------------------------------------
// Model metadata
// -----------------------------------------------------------------------------

export interface ModelInfo {
  id: string;
  alias?: string | null;
  name: string;
  displayName?: string | null;
  version?: number;
  publisher?: string | null;
  license?: string | null;
  task?: string | null;
  device: FlmDevice;
  executionProvider?: string | null;
  fileSizeBytes: number;
  contextLength: number;
  maxOutputTokens: number;
  supportsToolCalling: boolean;
  supportsReasoning: boolean;
  inputModalities: readonly string[];
  outputModalities: readonly string[];
  isCached: boolean;
  isLoaded: boolean;
  promptTemplates?: Readonly<Record<string, string>> | null;
}

// -----------------------------------------------------------------------------
// Session options
// -----------------------------------------------------------------------------

export interface ChatOptions {
  systemPrompt?: string;
  temperature?: number;
  topP?: number;
  topK?: number;
  maxOutputTokens?: number;
  seed?: number;
  /** Defaults to `true`. */
  keepHistory?: boolean;
}

export interface AudioOptions {
  language?: string;
  maxOutputTokens?: number;
}

export interface EmbeddingOptions {
  extra?: unknown;
}

// -----------------------------------------------------------------------------
// Chat request / response
// -----------------------------------------------------------------------------

export type ChatContentPart =
  | { type: 'text'; text: string }
  | { type: 'image'; path?: string; dataBase64?: string }
  | { type: 'audio'; path?: string; dataBase64?: string };

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string | readonly ChatContentPart[];
  /** Set on messages produced by a tool. */
  toolCallId?: string;
}

export interface Tool {
  name: string;
  description: string;
  /**
   * JSON Schema for the tool's parameters, as a raw JSON string. Passing a
   * string keeps the surface small and avoids re-serialising on every call.
   */
  parametersJson: string;
}

export interface ChatRequest {
  messages: readonly ChatMessage[];
  tools?: readonly Tool[];
  toolChoice?: string;
  temperature?: number;
  maxOutputTokens?: number;
}

/**
 * Terminal reason for a completion, exposed as string tags rather than a
 * numeric enum. `'unknown'` covers any value the runtime adds that this
 * binding does not model yet — collapsing unknown into `'none'` would be a
 * bug because `'none'` is a real running state.
 */
export type FinishReason =
  | 'none'
  | 'stop'
  | 'length'
  | 'tool_calls'
  | 'cancelled'
  | 'error'
  | 'unknown';

export interface ToolCall {
  callId: string;
  name: string;
  /**
   * The raw JSON payload the model produced, as a **string**. Not parsed:
   * a runaway model can emit something that does not match the declared
   * schema, and deciding what to do belongs to the app.
   */
  argumentsJson: string;
}

export interface UsageStats {
  promptTokens: number;
  completionTokens: number;
}

export interface CompleteResult {
  text: string;
  finishReason: FinishReason;
  /**
   * Tool calls the model wants executed, or `null` when the model made
   * none. `null` — not an empty array — preserves the ABI's absent-vs-empty
   * distinction.
   */
  toolCalls: readonly ToolCall[] | null;
  /** Token accounting, or `null` if the runtime did not report it. */
  usage: UsageStats | null;
  /** Raw JSON exposed for callers who need unmodelled fields. */
  rawJson: string;
}

export interface ToolResult {
  callId: string;
  /** Raw JSON string. Passed to the model as-is. */
  resultJson: string;
}

// -----------------------------------------------------------------------------
// Audio
// -----------------------------------------------------------------------------

export type TranscribeRequest =
  | {
      kind: 'file';
      path: string;
      language?: string;
      translate?: boolean;
    }
  | {
      kind: 'inMemory';
      dataBase64: string;
      format?: 'pcm' | 'wav' | 'ogg' | 'mp3' | 'flac';
      sampleRate?: number;
      channels?: number;
    }
  | {
      kind: 'streaming';
      language?: string;
    };

export interface TranscribeSegment {
  text: string;
  startTimeMs: number;
  endTimeMs: number;
  language: string | null;
}

export interface TranscribeResult {
  text: string;
  language: string | null;
  segments: readonly TranscribeSegment[];
}

// -----------------------------------------------------------------------------
// Embedding
// -----------------------------------------------------------------------------

export interface EmbeddingResult {
  embeddings: readonly (readonly number[])[];
  dimensions: number;
}

// -----------------------------------------------------------------------------
// Streaming primitives
// -----------------------------------------------------------------------------

/**
 * A single event from a streaming operation. The `kind` field discriminates
 * text, reasoning, tool calls, speech, usage, and terminal completion.
 *
 * Callers of `completeStreaming` iterate `Delta` objects and typically pluck
 * `text` for text-only rendering; other kinds are surfaced for apps that need
 * them.
 */
export type Delta =
  | { kind: 'text'; text: string }
  | { kind: 'reasoning'; text: string }
  | { kind: 'toolCall'; toolCall: ToolCall }
  | { kind: 'speechPartial'; text: string; startTimeMs: number; endTimeMs: number }
  | { kind: 'speechFinal'; text: string; startTimeMs: number; endTimeMs: number }
  | { kind: 'usage'; usage: UsageStats }
  | { kind: 'completed'; reason: FinishReason };

export interface Progress {
  percent: number;
  completedBytes: number;
  totalBytes: number;
  bytesPerSecond: number;
  etaMs: number;
  stage: string | null;
  detail: string | null;
}
