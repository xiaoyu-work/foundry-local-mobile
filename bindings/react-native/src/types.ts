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
  /** Override the model cache path (defaults to `<appDataDir>/models`). */
  modelCacheDir?: string;
  logsDir?: string;
  logLevel?: LogLevel;
  /** Catalog service URLs. Omit to use the Foundry Local defaults. */
  catalogUrls?: readonly string[];
  catalogRegion?: string;
  /** Serve only from the local cache; never touch the catalog service. */
  offline?: boolean;
  maxConcurrentDownloads?: number;
  downloadOnMeteredNetwork?: boolean;
  autoUnloadOnBackground?: boolean;
  /** 0 = derive from the number of CPU cores. */
  jobPoolThreads?: number;
  additionalOptions?: Readonly<Record<string, string>>;
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
// Model / package metadata
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
  isPackage: boolean;
  isCached: boolean;
  isLoaded: boolean;
  promptTemplates?: Readonly<Record<string, string>> | null;
}

export interface ModelVariant {
  id: string;
  component: string;
  executionProvider: string;
  device: FlmDevice;
  compatibilityString: string;
  platform: string;
  downloadSizeBytes: number;
  diskSizeBytes: number;
  sharedAssetRefs: readonly string[];
  isCompatible: boolean;
  compatibilityScore: number;
  isCached: boolean;
  /** `null` when the variant is compatible. */
  incompatibilityReason: string | null;
}

export interface PackageVariants {
  packageId: string;
  schemaVersion: string;
  selectedVariantId: string | null;
  sharedAssetsBytes: number;
  variants: readonly ModelVariant[];
}

export interface DownloadEstimate {
  downloadBytes: number;
  diskBytes: number;
  alreadyCachedBytes: number;
  availableStorageBytes: number;
  fitsOnDevice: boolean;
}

/**
 * Declarative variant selection policy. Applied against the manifest before
 * any bytes transfer, so a phone never pays for a variant it cannot run.
 *
 * These four keys are the entire vocabulary the core honours. Anything else
 * is silently ignored — do not invent additional constraints, and do not
 * assume "and" semantics beyond what is documented here.
 */
export interface VariantConstraints {
  /** Skip variants whose selected files exceed this many bytes. */
  maxDownloadBytes?: number;
  /** Restrict placement. Omit or empty to mean "any device". */
  allowedDevices?: readonly FlmDevice[];
  /** Break ties on download size rather than the compatibility score. */
  preferSmallest?: boolean;
  /** Only consider variants whose files are already on disk. */
  requireCached?: boolean;
}

// -----------------------------------------------------------------------------
// Model source (discriminated union)
// -----------------------------------------------------------------------------

interface ModelSourceCommon {
  /**
   * Name the model is registered under, and the thing that decides whether it
   * can run. The runtime picks a session implementation from the model's task,
   * and it learns tasks from the Foundry Local catalog. Name the source after
   * the catalog model it actually is — say
   * `qwen2.5-0.5b-instruct-generic-cpu:4` rather than `my-model` — and the task
   * comes with it. A name the catalog has never seen still downloads, installs
   * and loads, but creating a session on it will fail.
   */
  name: string;
  /**
   * Whether a partial download already on disk should be resumed. Defaults
   * to `true`. Set `false` to force a fresh fetch.
   */
  resume?: boolean;
  /**
   * Whether each file's SHA-256 is verified after download. Defaults to
   * `true`.
   */
  verifyChecksums?: boolean;
  /**
   * Variant policy applied when the source resolves to an ONNX Runtime
   * model package. Ignored for a flat model.
   */
  constraints?: VariantConstraints;
}

export interface BundledModelSource extends ModelSourceCommon {
  kind: 'bundled';
  /** Absolute filesystem path to the model directory already on the device. */
  path: string;
  /**
   * Copy the model into the SDK's cache instead of linking to `path`. The
   * default links, so the app keeps owning those files and must keep them
   * where they are; copy when it cannot promise that. For a package only the
   * selected variant is copied.
   */
  copyIntoCache?: boolean;
}

export interface RemoteModelSource extends ModelSourceCommon {
  kind: 'remote';
  /** URL to a package manifest or flat file index. */
  url: string;
  /** Sent verbatim on every request the transport makes for this source. */
  headers?: Readonly<Record<string, string>>;
}

/**
 * How a model is supplied. See `docs/model-sources.md`.
 *
 * The `kind` field discriminates the two shapes. `addModelSource` is the only
 * acquisition path on mobile — the catalog is for listing and inspecting
 * what is already on the device, not for downloading.
 */
export type ModelSource = BundledModelSource | RemoteModelSource;

// -----------------------------------------------------------------------------
// Catalog
// -----------------------------------------------------------------------------

export interface CatalogFilter {
  task?: string;
  cachedOnly?: boolean;
  loadedOnly?: boolean;
  maxSizeBytes?: number;
  /** Defaults to `true` — exclude models with no runnable variant. */
  compatibleOnly?: boolean;
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

// -----------------------------------------------------------------------------
// addModelSource result
// -----------------------------------------------------------------------------

/**
 * Outcome of a successful {@link FoundryLocal.addModelSource}. The model's
 * files are on disk at {@link ModelSourceResult.path} regardless of whether
 * {@link ModelSourceResult.model} is populated.
 *
 * `model` is the ready-to-use handle the core minted inside the same job. It
 * is `null` in the unexpected case where the download succeeded but the
 * catalog's local scan did not pick the files up. The download itself
 * succeeded either way; the null case is not an error. Fall back to
 * `foundry.catalog.getModel(result.name)` if you specifically need a handle,
 * or work from `result.path` directly.
 */
export interface ModelSourceResult {
  name: string;
  path: string;
  variantId: string | null;
  bytesDownloaded: number;
  bytesReused: number;
  wasCached: boolean;
  model: import('./Model').Model | null;
}
