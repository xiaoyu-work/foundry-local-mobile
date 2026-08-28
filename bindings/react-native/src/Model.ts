// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import NativeFoundryLocal from './NativeFoundryLocal';
import { FoundryLocalError } from './errors';
import { nextSubscriptionId, wireProgress } from './stream';
import { AudioSession, ChatSession, EmbeddingSession } from './Session';
import type {
  AudioOptions,
  ChatOptions,
  EmbeddingOptions,
  FlmDevice,
  ModelInfo,
  Progress,
} from './types';

/**
 * A handle for one model.
 *
 * Models are disposable. `close()` releases the handle but leaves the
 * on-disk files intact.
 */
export class Model {
  /** @internal */
  public readonly nativeHandle: number;
  protected closed = false;

  /** @internal */
  public constructor(handle: number) {
    this.nativeHandle = handle;
  }

  /**
   * @internal
   */
  public static wrap(handle: number): Model {
    if (handle === 0) {
      throw new FoundryLocalError(3, 'Invalid model handle (0)', null, 'invalidHandle');
    }
    return new Model(handle);
  }

  /** Freshly-loaded metadata for the model. */
  public getInfo(): ModelInfo {
    this.checkOpen();
    return decodeModelInfo(NativeFoundryLocal.modelGetInfo(this.nativeHandle));
  }

  /** Whether the model's files are fully present in the local cache. */
  public get isCached(): boolean {
    this.checkOpen();
    return NativeFoundryLocal.modelIsCached(this.nativeHandle);
  }

  /** Whether the model is currently loaded into memory. */
  public get isLoaded(): boolean {
    this.checkOpen();
    return NativeFoundryLocal.modelIsLoaded(this.nativeHandle);
  }

  /** Absolute on-disk path, or `null` when the model is not cached. */
  public get path(): string | null {
    this.checkOpen();
    const p = NativeFoundryLocal.modelGetPath(this.nativeHandle);
    return p === '' ? null : p;
  }

  /**
   * Load the model into memory.
   *
   * The model's files must already be on the device. `load` never fetches on
   * demand; it only maps an existing model into memory.
   */
  public async load(options?: {
    executionProvider?: string;
    providerOptions?: Readonly<Record<string, string>>;
    device?: FlmDevice;
    onProgress?: (p: Progress) => void;
  }): Promise<void> {
    this.checkOpen();
    const optionsJson = options && (options.executionProvider !== undefined || options.providerOptions !== undefined || options.device !== undefined)
      ? JSON.stringify({
          ...(options.executionProvider !== undefined ? { execution_provider: options.executionProvider } : {}),
          ...(options.providerOptions !== undefined && Object.keys(options.providerOptions).length > 0
            ? { provider_options: options.providerOptions } : {}),
          ...(options.device !== undefined ? { device: options.device } : {}),
        })
      : null;
    const subscriptionId = nextSubscriptionId('load');
    const dropProgress = wireProgress(subscriptionId, options?.onProgress);
    try {
      await NativeFoundryLocal.modelLoad(this.nativeHandle, optionsJson, subscriptionId);
    } catch (err) {
      throw FoundryLocalError.fromNative(err);
    } finally {
      dropProgress();
    }
  }

  /** Unload the model, releasing its memory. Active sessions are stopped first. */
  public async unload(): Promise<void> {
    this.checkOpen();
    try { await NativeFoundryLocal.modelUnload(this.nativeHandle); }
    catch (err) { throw FoundryLocalError.fromNative(err); }
  }

  public createChatSession(options: ChatOptions = {}): ChatSession {
    this.checkOpen();
    return ChatSession.create(this, options);
  }

  public createAudioSession(options: AudioOptions = {}): AudioSession {
    this.checkOpen();
    return AudioSession.create(this, options);
  }

  public createEmbeddingSession(options: EmbeddingOptions = {}): EmbeddingSession {
    this.checkOpen();
    return EmbeddingSession.create(this, options);
  }

  public close(): void {
    if (this.closed) return;
    this.closed = true;
    try { NativeFoundryLocal.modelRelease(this.nativeHandle); }
    catch { /* releasing an already-freed handle is a no-op */ }
  }

  protected checkOpen(): void {
    if (this.closed) {
      throw new FoundryLocalError(4, 'Model has been closed', null, 'invalidState');
    }
  }
}

function decodeModelInfo(raw: string): ModelInfo {
  const o = JSON.parse(raw) as Record<string, unknown>;
  return {
    id: String(o.id ?? ''),
    alias: (o.alias as string) ?? null,
    name: String(o.name ?? ''),
    displayName: (o.display_name as string) ?? null,
    version: typeof o.version === 'number' ? o.version : 0,
    publisher: (o.publisher as string) ?? null,
    license: (o.license as string) ?? null,
    task: (o.task as string) ?? null,
    device: normalizeDevice(o.device),
    executionProvider: (o.execution_provider as string) ?? null,
    fileSizeBytes: numberOr(o.file_size_bytes, -1),
    contextLength: numberOr(o.context_length, 0),
    maxOutputTokens: numberOr(o.max_output_tokens, 0),
    supportsToolCalling: Boolean(o.supports_tool_calling),
    supportsReasoning: Boolean(o.supports_reasoning),
    inputModalities: Array.isArray(o.input_modalities) ? (o.input_modalities as string[]) : [],
    outputModalities: Array.isArray(o.output_modalities) ? (o.output_modalities as string[]) : [],
    isCached: Boolean(o.is_cached),
    isLoaded: Boolean(o.is_loaded),
    promptTemplates: (o.prompt_templates as Record<string, string>) ?? null,
  };
}

function normalizeDevice(value: unknown): FlmDevice {
  const s = String(value ?? '').toLowerCase();
  return s === 'cpu' || s === 'gpu' || s === 'npu' ? (s as FlmDevice) : 'unknown';
}

function numberOr(value: unknown, fallback: number): number {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return fallback;
}
