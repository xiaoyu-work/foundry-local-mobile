// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import NativeFoundryLocal from './NativeFoundryLocal';
import { FoundryLocalError } from './errors';
import { Model } from './Model';
import type { CatalogFilter, ModelInfo } from './types';

/**
 * The catalog of models known to the SDK — models the app has registered
 * through `FoundryLocal.addModelSource` plus anything the local scan finds
 * on disk.
 *
 * **The catalog is for inspection, not acquisition.** Use
 * `FoundryLocal.addModelSource` to supply a model. Downloading from the
 * catalog is not a supported flow on mobile: the Foundry Local service
 * publishes desktop builds (CUDA, DirectML, OpenVINO, x64) that a phone
 * cannot execute.
 *
 * Borrowed from `FoundryLocal.catalog`; do not close directly.
 */
export class Catalog {
  /** @internal */
  public readonly nativeHandle: number;

  /** @internal */
  public constructor(handle: number) {
    this.nativeHandle = handle;
  }

  /** List catalog models, optionally filtered. */
  public async listModels(filter?: CatalogFilter): Promise<readonly ModelInfo[]> {
    try {
      const raw = await NativeFoundryLocal.catalogListModels(
        this.nativeHandle,
        filter ? JSON.stringify(encodeFilter(filter)) : null,
      );
      return decodeModelList(raw);
    } catch (err) {
      throw FoundryLocalError.fromNative(err);
    }
  }

  /**
   * Models present in the local cache. Synchronous and safe to call at
   * startup before any network is available.
   */
  public listCachedModels(): readonly ModelInfo[] {
    return decodeModelList(NativeFoundryLocal.catalogListCachedModels(this.nativeHandle));
  }

  /** Resolve a catalog model by its short alias (e.g. `"qwen2.5-0.5b"`). */
  public async getModel(alias: string): Promise<Model> {
    try {
      const handle = await NativeFoundryLocal.catalogGetModel(this.nativeHandle, alias);
      return Model.wrap(handle);
    } catch (err) {
      throw FoundryLocalError.fromNative(err);
    }
  }

  /**
   * Resolve a specific variant by its fully qualified model id. Bypasses
   * automatic variant selection and is normally called only when the app
   * wants to pin a variant across upgrades.
   */
  public async getModelById(modelId: string): Promise<Model> {
    try {
      const handle = await NativeFoundryLocal.catalogGetModelById(this.nativeHandle, modelId);
      return Model.wrap(handle);
    } catch (err) {
      throw FoundryLocalError.fromNative(err);
    }
  }

  /** Bytes currently consumed by the model cache. */
  public get cacheSizeBytes(): number {
    return NativeFoundryLocal.catalogGetCacheSizeBytes(this.nativeHandle);
  }
}

function encodeFilter(filter: CatalogFilter): Record<string, unknown> {
  const out: Record<string, unknown> = {
    cached_only: filter.cachedOnly ?? false,
    loaded_only: filter.loadedOnly ?? false,
    compatible_only: filter.compatibleOnly ?? true,
  };
  if (filter.task !== undefined) out.task = filter.task;
  if (filter.maxSizeBytes !== undefined) out.max_size_bytes = filter.maxSizeBytes;
  return out;
}

function decodeModelList(raw: string): readonly ModelInfo[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as { models?: unknown };
    return Array.isArray(parsed.models)
      ? (parsed.models as Record<string, unknown>[]).map(decodeModelInfo)
      : [];
  } catch {
    return [];
  }
}

function decodeModelInfo(o: Record<string, unknown>): ModelInfo {
  const device = String(o.device ?? '').toLowerCase();
  return {
    id: String(o.id ?? ''),
    alias: (o.alias as string) ?? null,
    name: String(o.name ?? ''),
    displayName: (o.display_name as string) ?? null,
    version: typeof o.version === 'number' ? o.version : 0,
    publisher: (o.publisher as string) ?? null,
    license: (o.license as string) ?? null,
    task: (o.task as string) ?? null,
    device: device === 'cpu' || device === 'gpu' || device === 'npu' ? (device as ModelInfo['device']) : 'unknown',
    executionProvider: (o.execution_provider as string) ?? null,
    fileSizeBytes: typeof o.file_size_bytes === 'number' ? o.file_size_bytes : -1,
    contextLength: typeof o.context_length === 'number' ? o.context_length : 0,
    maxOutputTokens: typeof o.max_output_tokens === 'number' ? o.max_output_tokens : 0,
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
