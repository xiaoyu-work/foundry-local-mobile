// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import NativeFoundryLocal from './NativeFoundryLocal';
import { FoundryLocalError } from './errors';
import { nextSubscriptionId, wireProgress } from './stream';
import { AudioSession, ChatSession, EmbeddingSession } from './Session';
import type {
  AudioOptions,
  ChatOptions,
  DownloadEstimate,
  EmbeddingOptions,
  FlmDevice,
  ModelInfo,
  ModelVariant,
  PackageVariants,
  Progress,
  VariantConstraints,
} from './types';

/**
 * A handle for one catalog model — a flat model, an ONNX Runtime package, or
 * a specific package variant. Use {@link isPackage} to distinguish, or
 * upcast to {@link ModelPackage} when you know a package is expected.
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
   * Build the correct Model subclass for a native handle. Called by the
   * factory functions on `FoundryLocal` / `Catalog`; a handle from user
   * code should never end up here.
   *
   * @internal
   */
  public static wrap(handle: number): Model {
    if (handle === 0) {
      throw new FoundryLocalError(3, 'Invalid model handle (0)', null, 'invalidHandle');
    }
    return NativeFoundryLocal.modelIsPackage(handle) ? new ModelPackage(handle) : new Model(handle);
  }

  /** Freshly-loaded metadata for the model. */
  public get info(): ModelInfo {
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

  /** `true` if this handle refers to a model package. */
  public get isPackage(): boolean {
    this.checkOpen();
    return NativeFoundryLocal.modelIsPackage(this.nativeHandle);
  }

  /**
   * Load the model into memory.
   *
   * The model's files must already be on the device — obtain the model
   * with `FoundryLocal.addModelSource`. `load` never fetches on demand;
   * loading a model whose files are absent rejects with a
   * `notImplemented` `FoundryLocalError` that points at the source API.
   */
  public async load(options?: {
    executionProvider?: string;
    device?: FlmDevice;
    onProgress?: (p: Progress) => void;
  }): Promise<void> {
    this.checkOpen();
    const optionsJson = options && (options.executionProvider !== undefined || options.device !== undefined)
      ? JSON.stringify({
          ...(options.executionProvider !== undefined ? { execution_provider: options.executionProvider } : {}),
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

  /** Delete the model's files from the local cache. Unloads first if loaded. */
  public async delete(): Promise<void> {
    this.checkOpen();
    try { await NativeFoundryLocal.modelDelete(this.nativeHandle); }
    catch (err) { throw FoundryLocalError.fromNative(err); }
  }

  /** Cast to {@link ModelPackage} if this is a package handle, else `null`. */
  public asPackage(): ModelPackage | null {
    return this.isPackage ? new ModelPackage(this.nativeHandle) : null;
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

/**
 * A model package handle. Adds variant enumeration, imperative selection
 * and pre-download estimation on top of {@link Model}.
 *
 * Prefer expressing variant policy declaratively on the source — pass
 * `constraints` in the `ModelSource` and the SDK scores the manifest
 * against them before any weights transfer. The imperative methods on this
 * class are for apps that need to inspect the manifest, run a post-download
 * re-selection, or manage multiple variants in parallel.
 */
export class ModelPackage extends Model {
  /** Snapshot of the package's variants, scored against this device. */
  public get variants(): PackageVariants {
    this.checkOpen();
    return decodePackageVariants(NativeFoundryLocal.packageGetVariants(this.nativeHandle));
  }

  /** Pin the package to a specific variant. Subsequent loads act on it. */
  public selectVariant(variantId: string): void {
    this.checkOpen();
    NativeFoundryLocal.packageSelectVariant(this.nativeHandle, variantId);
  }

  /**
   * Let the SDK pick the best variant using the device profile, the
   * variants' compatibility scores and any {@link VariantConstraints}.
   * Returns the id of the winning variant.
   */
  public selectBestVariant(constraints?: VariantConstraints): string {
    this.checkOpen();
    return NativeFoundryLocal.packageSelectBestVariant(
      this.nativeHandle,
      constraints ? JSON.stringify(encodeVariantConstraints(constraints)) : null,
    );
  }

  /**
   * Obtain a standalone handle for one variant. Useful for apps that want
   * to manage several variants in parallel — for example an NPU variant
   * downloading in the background while a CPU variant serves requests.
   */
  public variant(variantId: string): Model {
    this.checkOpen();
    const handle = NativeFoundryLocal.packageGetVariant(this.nativeHandle, variantId);
    return Model.wrap(handle);
  }

  /**
   * Estimate the transfer for `variantIds` before committing. Passing
   * `undefined` uses the currently selected variant.
   */
  public estimateDownload(variantIds?: readonly string[]): DownloadEstimate {
    this.checkOpen();
    return decodeDownloadEstimate(
      NativeFoundryLocal.packageEstimateDownload(
        this.nativeHandle,
        variantIds ? JSON.stringify(variantIds) : null,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Decoders
// -----------------------------------------------------------------------------

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
    isPackage: Boolean(o.is_package),
    isCached: Boolean(o.is_cached),
    isLoaded: Boolean(o.is_loaded),
    promptTemplates: (o.prompt_templates as Record<string, string>) ?? null,
  };
}

function decodePackageVariants(raw: string): PackageVariants {
  const o = JSON.parse(raw) as Record<string, unknown>;
  const variants = Array.isArray(o.variants)
    ? (o.variants as Record<string, unknown>[]).map(decodeVariant)
    : [];
  return {
    packageId: String(o.package_id ?? ''),
    schemaVersion: String(o.schema_version ?? ''),
    selectedVariantId: (o.selected_variant_id as string) ?? null,
    sharedAssetsBytes: numberOr(o.shared_assets_bytes, 0),
    variants,
  };
}

function decodeVariant(o: Record<string, unknown>): ModelVariant {
  return {
    id: String(o.id ?? ''),
    component: String(o.component ?? 'model'),
    executionProvider: String(o.execution_provider ?? ''),
    device: normalizeDevice(o.device),
    compatibilityString: String(o.compatibility_string ?? ''),
    platform: String(o.platform ?? 'any'),
    downloadSizeBytes: numberOr(o.download_size_bytes, 0),
    diskSizeBytes: numberOr(o.disk_size_bytes, 0),
    sharedAssetRefs: Array.isArray(o.shared_asset_refs) ? (o.shared_asset_refs as string[]) : [],
    isCompatible: Boolean(o.is_compatible),
    compatibilityScore: numberOr(o.compatibility_score, 0),
    isCached: Boolean(o.is_cached),
    incompatibilityReason: (o.incompatibility_reason as string) ?? null,
  };
}

function decodeDownloadEstimate(raw: string): DownloadEstimate {
  const o = JSON.parse(raw) as Record<string, unknown>;
  return {
    downloadBytes: numberOr(o.download_bytes, 0),
    diskBytes: numberOr(o.disk_bytes, 0),
    alreadyCachedBytes: numberOr(o.already_cached_bytes, 0),
    availableStorageBytes: numberOr(o.available_storage_bytes, 0),
    fitsOnDevice: Boolean(o.fits_on_device),
  };
}

/** @internal */
export function encodeVariantConstraints(c: VariantConstraints): Record<string, unknown> {
  const out: Record<string, unknown> = {
    prefer_smallest: c.preferSmallest ?? false,
    require_cached: c.requireCached ?? false,
  };
  if (c.maxDownloadBytes !== undefined) out.max_download_bytes = c.maxDownloadBytes;
  if (c.allowedDevices && c.allowedDevices.length > 0) out.allowed_devices = c.allowedDevices;
  return out;
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
