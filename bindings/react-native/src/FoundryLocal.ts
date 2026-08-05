// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import NativeFoundryLocal from './NativeFoundryLocal';
import { FoundryLocalError } from './errors';
import { Catalog } from './Catalog';
import { Model, encodeVariantConstraints } from './Model';
import { nextSubscriptionId, wireProgress } from './stream';
import type {
  DeviceProfile,
  ExecutionProviderInfo,
  FlmDevice,
  FoundryLocalConfig,
  LogLevel,
  ModelSource,
  ModelSourceResult,
  NetworkKind,
  Progress,
  ThermalState,
} from './types';

/**
 * Entry point for the Foundry Local Mobile SDK on React Native.
 *
 * Create one per app; instances share the underlying native manager and
 * transport by reference. Every long operation returns a `Promise` or an
 * async iterable — nothing on this class blocks the JavaScript thread.
 *
 * ```ts
 * const foundry = await FoundryLocal.create({ appName: 'my-app' });
 *
 * const result = await foundry.addModelSource(
 *   { kind: 'remote', name: 'qwen2.5-0.5b',
 *     url: 'https://models.example.com/qwen2.5-0.5b/manifest.json' },
 *   (p) => console.log(`${p.percent}%`),
 * );
 *
 * const model = result.model ?? await foundry.catalog.getModel(result.name);
 * await model.load();
 *
 * const chat = model.createChatSession();
 * for await (const delta of chat.completeStreaming('What is the golden ratio?')) {
 *   process.stdout.write(delta.text);
 * }
 * ```
 *
 * The instance holds native resources. Call {@link close} when done.
 */
export class FoundryLocal {
  private readonly handle: number;
  private _catalog: Catalog | null = null;
  private closed = false;

  private constructor(handle: number) {
    this.handle = handle;
  }

  /**
   * Create the SDK.
   *
   * On Android this uses the default OkHttp + WorkManager transport shipped
   * with the underlying Kotlin binding, which survives the app being
   * backgrounded. On iOS a `URLSession` background transport is installed
   * automatically once the iOS native side is wired.
   */
  public static async create(config: FoundryLocalConfig): Promise<FoundryLocal> {
    try {
      const handle = await NativeFoundryLocal.managerCreate(
        JSON.stringify(encodeConfig(config)),
      );
      return new FoundryLocal(handle);
    } catch (err) {
      throw FoundryLocalError.fromNative(err);
    }
  }

  /** SDK version. */
  public get version(): string {
    this.checkOpen();
    return NativeFoundryLocal.managerVersion(this.handle);
  }

  /** Foundry Local runtime version, or `null` when the runtime is absent. */
  public get runtimeVersion(): string | null {
    this.checkOpen();
    const s = NativeFoundryLocal.managerRuntimeVersion(this.handle);
    return s === '' ? null : s;
  }

  /** `true` if the Foundry Local runtime is present and loadable. */
  public get isRuntimeAvailable(): boolean {
    this.checkOpen();
    return NativeFoundryLocal.managerIsRuntimeAvailable(this.handle);
  }

  /** The catalog owned by this manager. Borrowed; do not close directly. */
  public get catalog(): Catalog {
    this.checkOpen();
    if (this._catalog === null) {
      this._catalog = new Catalog(NativeFoundryLocal.managerGetCatalog(this.handle));
    }
    return this._catalog;
  }

  /** Snapshot of the device profile used for scoring variants. */
  public get deviceProfile(): DeviceProfile {
    this.checkOpen();
    return decodeDeviceProfile(NativeFoundryLocal.managerGetDeviceProfile(this.handle));
  }

  /**
   * Install a bundled or remote model as a first-class catalog entry.
   *
   * `addModelSource` is the only supply path on mobile. The result carries
   * the resolved `name`, `path` and — in the common case — a ready-to-use
   * `model`. `model` is `null` only in the unexpected case where the
   * download succeeded but the local scan did not find the files
   * afterwards; the caller can fall back to `catalog.getModel(result.name)`
   * or work from `result.path` directly.
   *
   * @param source Model source. Bundled or remote; see {@link ModelSource}.
   * @param onProgress Optional progress callback for download/verification.
   */
  public async addModelSource(
    source: ModelSource,
    onProgress?: (progress: Progress) => void,
  ): Promise<ModelSourceResult> {
    this.checkOpen();
    const subscriptionId = nextSubscriptionId('add');
    const dropProgress = wireProgress(subscriptionId, onProgress);
    try {
      const raw = await NativeFoundryLocal.addModelSource(
        this.handle,
        JSON.stringify(encodeSource(source)),
        subscriptionId,
      );
      return decodeModelSourceResult(raw, source.name);
    } catch (err) {
      throw FoundryLocalError.fromNative(err);
    } finally {
      dropProgress();
    }
  }

  /** Update settings that can change at runtime. */
  public updateSettings(config: FoundryLocalConfig): void {
    this.checkOpen();
    NativeFoundryLocal.managerUpdateSettings(
      this.handle,
      JSON.stringify(encodeConfig(config)),
    );
  }

  /** Change the SDK-wide log level. */
  public setLogLevel(level: LogLevel): void {
    this.checkOpen();
    NativeFoundryLocal.managerSetLogLevel(this.handle, LOG_LEVELS[level] ?? 3);
  }

  /**
   * Shut down the manager and release all native resources. Idempotent and
   * safe to call from any thread. After this returns, every derived object
   * (catalog, model, session) is invalidated.
   */
  public async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    try { await NativeFoundryLocal.managerShutdown(this.handle); } catch { /* best effort */ }
    try { NativeFoundryLocal.managerRelease(this.handle); } catch { /* best effort */ }
  }

  private checkOpen(): void {
    if (this.closed) {
      throw new FoundryLocalError(4, 'FoundryLocal has been closed', null, 'invalidState');
    }
  }
}

// -----------------------------------------------------------------------------
// Encoding / decoding helpers
// -----------------------------------------------------------------------------

const LOG_LEVELS: Record<LogLevel, number> = {
  verbose: 0, debug: 1, info: 2, warning: 3, error: 4, fatal: 5, off: 6,
};

function encodeConfig(config: FoundryLocalConfig): Record<string, unknown> {
  const out: Record<string, unknown> = {
    app_name: config.appName,
    log_level: config.logLevel ?? 'warning',
    offline: config.offline ?? false,
    max_concurrent_downloads: config.maxConcurrentDownloads ?? 2,
    download_on_metered_network: config.downloadOnMeteredNetwork ?? false,
    auto_unload_on_background: config.autoUnloadOnBackground ?? true,
    job_pool_threads: config.jobPoolThreads ?? 0,
  };
  if (config.appDataDir !== undefined) out.app_data_dir = config.appDataDir;
  if (config.modelCacheDir !== undefined) out.model_cache_dir = config.modelCacheDir;
  if (config.logsDir !== undefined) out.logs_dir = config.logsDir;
  if (config.catalogUrls !== undefined) out.catalog_urls = config.catalogUrls;
  if (config.catalogRegion !== undefined) out.catalog_region = config.catalogRegion;
  if (config.additionalOptions !== undefined) out.additional_options = config.additionalOptions;
  return out;
}

function encodeSource(source: ModelSource): Record<string, unknown> {
  const common: Record<string, unknown> = {
    name: source.name,
    resume: source.resume ?? true,
    verify_checksums: source.verifyChecksums ?? true,
  };
  if (source.constraints !== undefined) {
    common.constraints = encodeVariantConstraints(source.constraints);
  }
  if (source.kind === 'bundled') {
    return {
      kind: 'bundled',
      path: source.path,
      copy_into_cache: source.copyIntoCache ?? false,
      ...common,
    };
  }
  const remote: Record<string, unknown> = { kind: 'remote', url: source.url, ...common };
  if (source.headers && Object.keys(source.headers).length > 0) {
    remote.headers = source.headers;
  }
  return remote;
}

function decodeModelSourceResult(raw: string | null | undefined, fallbackName: string): ModelSourceResult {
  const obj = raw ? tryJson(raw) : {};
  const name = typeof obj.name === 'string' && obj.name !== '' ? obj.name : fallbackName;
  const path = typeof obj.path === 'string' ? obj.path : '';
  const variantId = typeof obj.variant_id === 'string' && obj.variant_id !== '' ? obj.variant_id : null;
  const bytesDownloaded = numberOr(obj.bytes_downloaded, 0);
  const bytesReused = numberOr(obj.bytes_reused, 0);
  const wasCached = Boolean(obj.was_cached);
  // model_handle is a uint64 slot id. It can legitimately be 0
  // (FLM_INVALID_HANDLE) — the download succeeded, no handle came back, and
  // the core says why. Never turn that into a rejection: surface both.
  const handle = numberOr(obj.model_handle, 0);
  const model = handle !== 0 ? Model.wrap(handle) : null;
  const reason = typeof obj.model_handle_unavailable === 'string' && obj.model_handle_unavailable !== ''
    ? obj.model_handle_unavailable
    : null;
  return {
    name, path, variantId, bytesDownloaded, bytesReused, wasCached, model,
    handleUnavailableReason: reason,
  };
}

function tryJson(raw: string): Record<string, unknown> {
  try { return JSON.parse(raw) as Record<string, unknown>; }
  catch { return {}; }
}

function numberOr(value: unknown, fallback: number): number {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return fallback;
}

function decodeDeviceProfile(raw: string): DeviceProfile {
  const o = tryJson(raw);
  const eps = Array.isArray(o.execution_providers)
    ? (o.execution_providers as Record<string, unknown>[]).map(decodeExecutionProvider)
    : [];
  const network = String(o.network ?? 'unknown').toLowerCase() as NetworkKind;
  const thermal = String(o.thermal_state ?? '').toLowerCase();
  const thermalState = (['nominal', 'fair', 'serious', 'critical'].includes(thermal)
    ? (thermal as Exclude<ThermalState, null>)
    : null);
  return {
    platform: String(o.platform ?? ''),
    osVersion: String(o.os_version ?? ''),
    deviceModel: String(o.device_model ?? ''),
    soc: (o.soc as string) ?? null,
    abi: String(o.abi ?? ''),
    cpuCores: numberOr(o.cpu_cores, 0),
    totalMemoryBytes: numberOr(o.total_memory_bytes, 0),
    availableMemoryBytes: numberOr(o.available_memory_bytes, 0),
    availableStorageBytes: numberOr(o.available_storage_bytes, 0),
    hasNpu: Boolean(o.has_npu),
    hasGpu: Boolean(o.has_gpu),
    executionProviders: eps,
    thermalState,
    lowPowerMode: Boolean(o.low_power_mode),
    network: ['unknown', 'unmetered', 'metered', 'offline'].includes(network) ? network : 'unknown',
  };
}

function decodeExecutionProvider(o: Record<string, unknown>): ExecutionProviderInfo {
  const device = String(o.device ?? '').toLowerCase() as FlmDevice;
  return {
    name: String(o.name ?? ''),
    device: device === 'cpu' || device === 'gpu' || device === 'npu' ? device : 'unknown',
    available: Boolean(o.available),
    priority: numberOr(o.priority, 0),
  };
}
