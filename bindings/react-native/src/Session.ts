// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import NativeFoundryLocal from './NativeFoundryLocal';
import { FoundryLocalError } from './errors';
import { makeDeltaStream, nextSubscriptionId } from './stream';
import type {
  AudioOptions,
  ChatOptions,
  ChatRequest,
  CompleteResult,
  Delta,
  EmbeddingOptions,
  EmbeddingResult,
  FinishReason,
  ToolCall,
  ToolResult,
  TranscribeRequest,
  TranscribeResult,
  UsageStats,
} from './types';
import type { Model } from './Model';

const FINISH_REASONS: readonly FinishReason[] = [
  'none', 'stop', 'length', 'tool_calls', 'cancelled', 'error',
];

function parseFinishReason(s: string | undefined | null): FinishReason {
  if (s == null || s === '') return 'none';
  return FINISH_REASONS.includes(s as FinishReason) ? (s as FinishReason) : 'unknown';
}

function toNumber(value: unknown): number {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return 0;
}

/**
 * Common base for every session type. Owns a native handle and unregisters
 * it on `close()`. `Session` is disposable — a released session invalidates
 * every subsequent call.
 */
export abstract class Session {
  protected readonly handle: number;
  protected closed = false;

  protected constructor(handle: number) {
    this.handle = handle;
  }

  /** Number of completed turns in the conversation. */
  public get turnCount(): number {
    this.checkOpen();
    return NativeFoundryLocal.sessionGetTurnCount(this.handle);
  }

  public undoTurns(count: number): void {
    this.checkOpen();
    NativeFoundryLocal.sessionUndoTurns(this.handle, count);
  }

  public clearHistory(): void {
    this.checkOpen();
    NativeFoundryLocal.sessionClearHistory(this.handle);
  }

  /** JSON-encoded conversation history the app can persist and re-load. */
  public exportHistory(): string {
    this.checkOpen();
    return NativeFoundryLocal.sessionExportHistory(this.handle);
  }

  public restoreHistory(historyJson: string): void {
    this.checkOpen();
    NativeFoundryLocal.sessionRestoreHistory(this.handle, historyJson);
  }

  public close(): void {
    if (this.closed) return;
    this.closed = true;
    try { NativeFoundryLocal.sessionRelease(this.handle); }
    catch { /* releasing an already-freed session is a no-op */ }
  }

  protected checkOpen(): void {
    if (this.closed) {
      throw new FoundryLocalError(4, 'Session has been closed', null, 'invalidState');
    }
  }
}

// -----------------------------------------------------------------------------
// Chat
// -----------------------------------------------------------------------------

/**
 * A chat / completion session. Instances hold a KV cache and a small amount
 * of state on top of the loaded model.
 */
export class ChatSession extends Session {
  /** @internal */
  public static create(model: Model, options: ChatOptions): ChatSession {
    const handle = NativeFoundryLocal.sessionCreate(
      model.nativeHandle,
      JSON.stringify({ type: 'chat', ...encodeChatOptions(options) }),
    );
    return new ChatSession(handle);
  }

  private constructor(handle: number) {
    super(handle);
  }

  public updateOptions(options: ChatOptions): void {
    this.checkOpen();
    NativeFoundryLocal.sessionSetOptions(
      this.handle,
      JSON.stringify({ type: 'chat', ...encodeChatOptions(options) }),
    );
  }

  /**
   * Streaming completion. Iterate with `for await`. Breaking out of the
   * loop cancels the underlying job.
   *
   * The stream only yields text deltas by default. Use
   * {@link completeAllDeltas} when the caller needs tool-call events or
   * mid-generation usage frames.
   */
  public completeStreaming(prompt: string): AsyncIterable<{ text: string }>;
  public completeStreaming(request: ChatRequest): AsyncIterable<{ text: string }>;
  public completeStreaming(input: string | ChatRequest): AsyncIterable<{ text: string }> {
    const request = typeof input === 'string' ? userTurnRequest(input) : input;
    const iter = this.completeAllDeltas(request);
    return {
      [Symbol.asyncIterator](): AsyncIterator<{ text: string }> {
        const inner = iter[Symbol.asyncIterator]();
        return {
          async next(): Promise<IteratorResult<{ text: string }>> {
            for (;;) {
              const step = await inner.next();
              if (step.done) return { value: undefined as unknown as { text: string }, done: true };
              if (step.value.kind === 'text') return { value: { text: step.value.text }, done: false };
              // Skip non-text deltas; the caller opted out of them by using this overload.
            }
          },
          async return(): Promise<IteratorResult<{ text: string }>> {
            if (inner.return) await inner.return(undefined);
            return { value: undefined as unknown as { text: string }, done: true };
          },
        };
      },
    };
  }

  /**
   * Streaming completion that surfaces every delta kind — text, reasoning,
   * tool calls, mid-generation usage frames and the terminal completion
   * event.
   */
  public completeAllDeltas(request: ChatRequest): AsyncIterable<Delta> {
    this.checkOpen();
    const subscriptionId = nextSubscriptionId('chat');
    return makeDeltaStream({
      subscriptionId,
      start: () =>
        NativeFoundryLocal.sessionCompleteStreaming(
          this.handle,
          JSON.stringify(encodeChatRequest(request)),
          subscriptionId,
        ),
    });
  }

  /**
   * Non-streaming completion. Returns the entire assistant response along
   * with any tool calls the model requested and, when the runtime reports
   * them, token usage counters.
   */
  public async complete(prompt: string): Promise<CompleteResult>;
  public async complete(request: ChatRequest): Promise<CompleteResult>;
  public async complete(input: string | ChatRequest): Promise<CompleteResult> {
    this.checkOpen();
    const request = typeof input === 'string' ? userTurnRequest(input) : input;
    try {
      const raw = await NativeFoundryLocal.sessionComplete(
        this.handle,
        JSON.stringify(encodeChatRequest(request)),
      );
      return parseCompleteResult(raw);
    } catch (err) {
      throw FoundryLocalError.fromNative(err);
    }
  }

  /**
   * Continue a turn by delivering results for tools the model asked to
   * call. Yields the next round of deltas — including the final assistant
   * text or a further round of tool calls.
   */
  public submitToolResults(results: readonly ToolResult[]): AsyncIterable<Delta> {
    this.checkOpen();
    const subscriptionId = nextSubscriptionId('tool');
    const payload = JSON.stringify(results.map((r) => ({ call_id: r.callId, result: r.resultJson })));
    return makeDeltaStream({
      subscriptionId,
      start: () =>
        NativeFoundryLocal.sessionSubmitToolResultsStreaming(this.handle, payload, subscriptionId),
    });
  }
}

// -----------------------------------------------------------------------------
// Audio
// -----------------------------------------------------------------------------

/** Speech-to-text session. */
export class AudioSession extends Session {
  /** @internal */
  public static create(model: Model, options: AudioOptions): AudioSession {
    const handle = NativeFoundryLocal.sessionCreate(
      model.nativeHandle,
      JSON.stringify({ type: 'audio', ...encodeAudioOptions(options) }),
    );
    return new AudioSession(handle);
  }

  private constructor(handle: number) {
    super(handle);
  }

  /** One-shot transcription. */
  public async transcribe(request: TranscribeRequest): Promise<TranscribeResult> {
    this.checkOpen();
    try {
      const raw = await NativeFoundryLocal.sessionTranscribe(
        this.handle,
        JSON.stringify(encodeTranscribeRequest(request)),
      );
      return parseTranscribeResult(raw);
    } catch (err) {
      throw FoundryLocalError.fromNative(err);
    }
  }

  /**
   * Streaming transcription. Emits `speechPartial` while listening and
   * `speechFinal` for stabilised segments; the terminal `completed` delta
   * carries the finish reason.
   */
  public transcribeStreaming(request: TranscribeRequest): AsyncIterable<Delta> {
    this.checkOpen();
    const subscriptionId = nextSubscriptionId('asr');
    return makeDeltaStream({
      subscriptionId,
      start: () =>
        NativeFoundryLocal.sessionTranscribeStreaming(
          this.handle,
          JSON.stringify(encodeTranscribeRequest(request)),
          subscriptionId,
        ),
    });
  }

  /**
   * Push a chunk of PCM audio into a live transcription session. Only
   * meaningful after `transcribeStreaming({ kind: 'streaming' })`.
   *
   * `pcm` is a `Uint8Array` of little-endian 16-bit PCM samples. It is
   * base64-encoded once on the JS side to cross the bridge.
   */
  public pushAudio(
    pcm: Uint8Array,
    sampleRate: number,
    channels: number,
    isFinal = false,
  ): void {
    this.checkOpen();
    NativeFoundryLocal.sessionPushAudio(
      this.handle,
      uint8ToBase64(pcm),
      sampleRate,
      channels,
      isFinal,
    );
  }
}

// -----------------------------------------------------------------------------
// Embedding
// -----------------------------------------------------------------------------

export class EmbeddingSession extends Session {
  /** @internal */
  public static create(model: Model, _options: EmbeddingOptions): EmbeddingSession {
    const handle = NativeFoundryLocal.sessionCreate(
      model.nativeHandle,
      JSON.stringify({ type: 'embedding' }),
    );
    return new EmbeddingSession(handle);
  }

  private constructor(handle: number) {
    super(handle);
  }

  public async embed(inputs: readonly string[]): Promise<EmbeddingResult> {
    this.checkOpen();
    try {
      const raw = await NativeFoundryLocal.sessionEmbed(
        this.handle,
        JSON.stringify({ inputs }),
      );
      return parseEmbeddingResult(raw);
    } catch (err) {
      throw FoundryLocalError.fromNative(err);
    }
  }
}

// -----------------------------------------------------------------------------
// Encoding / decoding helpers
// -----------------------------------------------------------------------------

function encodeChatOptions(options: ChatOptions): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (options.systemPrompt !== undefined) out.system_prompt = options.systemPrompt;
  if (options.temperature !== undefined) out.temperature = options.temperature;
  if (options.topP !== undefined) out.top_p = options.topP;
  if (options.topK !== undefined) out.top_k = options.topK;
  if (options.maxOutputTokens !== undefined) out.max_output_tokens = options.maxOutputTokens;
  if (options.seed !== undefined) out.seed = options.seed;
  out.keep_history = options.keepHistory ?? true;
  return out;
}

function encodeAudioOptions(options: AudioOptions): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (options.language !== undefined) out.language = options.language;
  if (options.maxOutputTokens !== undefined) out.max_output_tokens = options.maxOutputTokens;
  return out;
}

function encodeChatRequest(request: ChatRequest): Record<string, unknown> {
  const out: Record<string, unknown> = {
    messages: request.messages.map((m) => {
      const encoded: Record<string, unknown> = { role: m.role };
      if (typeof m.content === 'string') {
        encoded.content = m.content;
      } else {
        encoded.content = m.content.map((part) => {
          const p: Record<string, unknown> = { type: part.type };
          if ('text' in part && part.text !== undefined) p.text = part.text;
          if ('path' in part && part.path !== undefined) p.path = part.path;
          if ('dataBase64' in part && part.dataBase64 !== undefined) p.data_base64 = part.dataBase64;
          return p;
        });
      }
      if (m.toolCallId !== undefined) encoded.tool_call_id = m.toolCallId;
      return encoded;
    }),
  };
  if (request.tools && request.tools.length > 0) {
    out.tools = request.tools.map((t) => ({
      name: t.name,
      description: t.description,
      // parametersJson is a JSON Schema document; embed it as an object so
      // the ABI sees a schema, not a stringified schema.
      parameters: JSON.parse(t.parametersJson),
    }));
  }
  if (request.toolChoice !== undefined) out.tool_choice = request.toolChoice;
  if (request.temperature !== undefined) out.temperature = request.temperature;
  if (request.maxOutputTokens !== undefined) out.max_output_tokens = request.maxOutputTokens;
  return out;
}

function encodeTranscribeRequest(request: TranscribeRequest): Record<string, unknown> {
  switch (request.kind) {
    case 'file':
      return {
        path: request.path,
        ...(request.language !== undefined ? { language: request.language } : {}),
        translate: request.translate ?? false,
      };
    case 'inMemory':
      return {
        data_base64: request.dataBase64,
        format: request.format ?? 'pcm',
        sample_rate: request.sampleRate ?? 16000,
        channels: request.channels ?? 1,
      };
    case 'streaming':
      return {
        streaming: true,
        ...(request.language !== undefined ? { language: request.language } : {}),
      };
  }
}

function parseCompleteResult(raw: string | null | undefined): CompleteResult {
  const rawJson = raw ?? '';
  if (!rawJson) {
    return { text: '', finishReason: 'none', toolCalls: null, usage: null, rawJson: '' };
  }
  let obj: Record<string, unknown>;
  try {
    obj = JSON.parse(rawJson) as Record<string, unknown>;
  } catch {
    return { text: '', finishReason: 'none', toolCalls: null, usage: null, rawJson };
  }

  const text = typeof obj.text === 'string' ? obj.text : '';
  const finishReason = parseFinishReason(
    typeof obj.finish_reason === 'string' ? (obj.finish_reason as string) : null,
  );

  // Absent vs empty: `null` when the core did not report tool_calls at all,
  // `[]` when it explicitly emitted an empty array. We keep the distinction.
  let toolCalls: readonly ToolCall[] | null = null;
  if (Array.isArray(obj.tool_calls)) {
    toolCalls = (obj.tool_calls as unknown[]).map((c) => {
      const call = c as { call_id?: unknown; name?: unknown; arguments?: unknown };
      return {
        callId: typeof call.call_id === 'string' ? call.call_id : '',
        name: typeof call.name === 'string' ? call.name : '',
        // Arguments stays a raw string; the model may emit something that
        // does not match the declared schema and it is the app's job to
        // decide what to do about that.
        argumentsJson: typeof call.arguments === 'string' ? call.arguments : '{}',
      };
    });
  }

  let usage: UsageStats | null = null;
  if (obj.usage && typeof obj.usage === 'object') {
    const u = obj.usage as { prompt_tokens?: unknown; completion_tokens?: unknown };
    usage = {
      promptTokens: toNumber(u.prompt_tokens),
      completionTokens: toNumber(u.completion_tokens),
    };
  }

  return { text, finishReason, toolCalls, usage, rawJson };
}

function parseTranscribeResult(raw: string | null | undefined): TranscribeResult {
  if (!raw) return { text: '', language: null, segments: [] };
  let obj: Record<string, unknown>;
  try { obj = JSON.parse(raw) as Record<string, unknown>; }
  catch { return { text: '', language: null, segments: [] }; }

  const segments = Array.isArray(obj.segments)
    ? (obj.segments as unknown[]).map((s) => {
        const seg = s as Record<string, unknown>;
        return {
          text: typeof seg.text === 'string' ? seg.text : '',
          startTimeMs: toNumber(seg.start_time_ms),
          endTimeMs: toNumber(seg.end_time_ms),
          language: typeof seg.language === 'string' ? seg.language : null,
        };
      })
    : [];

  return {
    text: typeof obj.text === 'string' ? obj.text : '',
    language: typeof obj.language === 'string' ? obj.language : null,
    segments,
  };
}

function parseEmbeddingResult(raw: string | null | undefined): EmbeddingResult {
  if (!raw) return { embeddings: [], dimensions: 0 };
  let obj: Record<string, unknown>;
  try { obj = JSON.parse(raw) as Record<string, unknown>; }
  catch { return { embeddings: [], dimensions: 0 }; }

  const dimensions = toNumber(obj.dimensions);
  const embeddings = Array.isArray(obj.embeddings)
    ? (obj.embeddings as unknown[]).map((row) =>
        Array.isArray(row) ? (row as unknown[]).map((n) => toNumber(n)) : [],
      )
    : [];
  return { embeddings, dimensions };
}

function userTurnRequest(prompt: string): ChatRequest {
  return { messages: [{ role: 'user', content: prompt }] };
}

// -----------------------------------------------------------------------------
// Small base64 helper for `pushAudio`. Kept local because RN environments
// vary in whether `Buffer`/`atob`/`btoa` is polyfilled.
// -----------------------------------------------------------------------------

const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function uint8ToBase64(bytes: Uint8Array): string {
  // Prefer the platform Buffer when Node.js is polyfilling it (Jest, Metro
  // dev server on some configurations); otherwise fall back to a manual
  // encoder so this file compiles standalone.
  const maybeBuffer = (globalThis as { Buffer?: { from: (b: Uint8Array) => { toString: (fmt: string) => string } } }).Buffer;
  if (maybeBuffer) return maybeBuffer.from(bytes).toString('base64');

  let out = '';
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const b0 = bytes[i]!, b1 = bytes[i + 1]!, b2 = bytes[i + 2]!;
    out += BASE64_ALPHABET[b0 >> 2];
    out += BASE64_ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)];
    out += BASE64_ALPHABET[((b1 & 0x0f) << 2) | (b2 >> 6)];
    out += BASE64_ALPHABET[b2 & 0x3f];
  }
  const rem = bytes.length - i;
  if (rem === 1) {
    const b0 = bytes[i]!;
    out += BASE64_ALPHABET[b0 >> 2];
    out += BASE64_ALPHABET[(b0 & 0x03) << 4];
    out += '==';
  } else if (rem === 2) {
    const b0 = bytes[i]!, b1 = bytes[i + 1]!;
    out += BASE64_ALPHABET[b0 >> 2];
    out += BASE64_ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)];
    out += BASE64_ALPHABET[(b1 & 0x0f) << 2];
    out += '=';
  }
  return out;
}
