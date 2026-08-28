// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import NativeFoundryLocal from './NativeFoundryLocal';
import { FoundryLocalError } from './errors';
import { Model } from './Model';
import type {
  DeviceProfile,
  ExecutionProviderInfo,
  FlmDevice,
  FoundryLocalConfig,
  LogLevel,
  NetworkKind,
  ThermalState,
} from './types';

/**
 * Entry point for the Foundry Local Mobile SDK on React Native.
 *
 * Create one per app; instances share the underlying native manager by
 * reference. Every long operation returns a `Promise` or an async iterable —
 * nothing on this class blocks the JavaScript thread.
 */
export class FoundryLocal {
  private readonly handle: number;
  private closed = false;

  private constructor(handle: number) {
    this.handle = handle;
  }

  /** Create the SDK. */
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

  /** ONNX Runtime GenAI version, or `null` when the runtime is absent. */
  public get runtimeVersion(): string | null {
    this.checkOpen();
    const s = NativeFoundryLocal.managerRuntimeVersion(this.handle);
    return s === '' ? null : s;
  }

  /** `true` if the ONNX Runtime GenAI runtime is present and loadable. */
  public get isRuntimeAvailable(): boolean {
    this.checkOpen();
    return NativeFoundryLocal.managerIsRuntimeAvailable(this.handle);
  }

  /** Snapshot of the device profile used for model placement. */
  public get deviceProfile(): DeviceProfile {
    this.checkOpen();
    return decodeDeviceProfile(NativeFoundryLocal.managerGetDeviceProfile(this.handle));
  }

  /**
   * Load a model directly from a local directory path.
   *
   * @param path Absolute filesystem path to the model directory.
   * @param options Optional execution-provider configuration.
   */
  public async loadModel(
    path: string,
    options?: {
      executionProvider?: string;
      providerOptions?: Readonly<Record<string, string>>;
    },
  ): Promise<Model> {
    this.checkOpen();
    const optionsJson = encodeLoadModelOptions(options);
    let raw: string;
    try {
      raw = await NativeFoundryLocal.loadModel(this.handle, path, optionsJson);
    } catch (err) {
      throw FoundryLocalError.fromNative(err);
    }

    const handle = numberOr(tryJson(raw).model_handle, 0);
    if (handle === 0) {
      throw new FoundryLocalError(
        3,
        `No model handle returned for path '${path}'.`,
        raw,
        'invalidHandle',
      );
    }
    return Model.wrap(handle);
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
   * safe to call from any thread.
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

const LOG_LEVELS: Record<LogLevel, number> = {
  verbose: 0, debug: 1, info: 2, warning: 3, error: 4, fatal: 5, off: 6,
};

function encodeConfig(config: FoundryLocalConfig): Record<string, unknown> {
  const out: Record<string, unknown> = {
    app_name: config.appName,
    log_level: config.logLevel ?? 'warning',
    auto_unload_on_background: config.autoUnloadOnBackground ?? true,
    job_pool_threads: config.jobPoolThreads ?? 0,
  };
  if (config.appDataDir !== undefined) out.app_data_dir = config.appDataDir;
  return out;
}

function encodeLoadModelOptions(
  options: {
    executionProvider?: string;
    providerOptions?: Readonly<Record<string, string>>;
  } | undefined,
): string | null {
  if (!options) return null;
  const out: Record<string, unknown> = {};
  if (options.executionProvider !== undefined) {
    out.execution_provider = options.executionProvider;
  }
  if (options.providerOptions !== undefined && Object.keys(options.providerOptions).length > 0) {
    out.provider_options = options.providerOptions;
  }
  return Object.keys(out).length > 0 ? JSON.stringify(out) : null;
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
