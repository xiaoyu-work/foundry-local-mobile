// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

/**
 * Codegen'd spec for the native module. Everything else in the binding is a
 * thin TypeScript wrapper around this interface.
 *
 * ## Handles
 *
 * All native handles are opaque `number`s — slot ids into a handle table on
 * the native side, not raw pointers. They are always in the safe integer
 * range (`< 2^53`) so passing them through JavaScript's `number` type does
 * not lose precision.
 *
 * ## JSON payloads
 *
 * The wire format for anything richer than a primitive is a UTF-8 JSON
 * string. The TypeScript layer parses/produces those strings; the native
 * layer forwards them to the C ABI verbatim. This mirrors the Android and
 * iOS bindings and keeps the codegen'd spec small.
 *
 * ## Streaming
 *
 * Long-running operations take a caller-generated `subscriptionId` (a string)
 * and emit events through `NativeEventEmitter` under those names:
 *
 *   - `FoundryLocal:delta`    — `{ subscriptionId, delta }`
 *   - `FoundryLocal:progress` — `{ subscriptionId, progress }`
 *   - `FoundryLocal:end`      — `{ subscriptionId, resultJson? }`
 *   - `FoundryLocal:error`    — `{ subscriptionId, status, message, detail }`
 *
 * `cancelSubscription` maps 1:1 to `flm_job_cancel`. A cancelled stream
 * always terminates with an `end` or `error` event, so the TypeScript async
 * iterator cleanup path is always driven by a real event, not a timeout.
 */
export interface Spec extends TurboModule {
  // ---------------------------------------------------------------------------
  // Manager
  // ---------------------------------------------------------------------------

  /** Creates a manager. Returns its slot id. `configJson` is the FoundryLocalConfig serialised. */
  managerCreate(configJson: string): Promise<number>;
  managerShutdown(managerId: number): Promise<void>;
  managerRelease(managerId: number): void;
  managerUpdateSettings(managerId: number, configJson: string): void;
  managerGetDeviceProfile(managerId: number): string;
  managerGetCatalog(managerId: number): number;

  /**
   * SDK version, runtime version and runtime availability. Routed through a
   * live manager because the Kotlin binding exposes them as instance-level
   * accessors, and the codegen'd JNI bridge sits inside the manager. The
   * TypeScript wrapper hides that detail: from JS, `foundry.version` reads
   * like a property.
   */
  managerVersion(managerId: number): string;
  /** Foundry Local runtime version, or empty string when the runtime is absent. */
  managerRuntimeVersion(managerId: number): string;
  managerIsRuntimeAvailable(managerId: number): boolean;
  managerSetLogLevel(managerId: number, level: number): void;

  // ---------------------------------------------------------------------------
  // Add model source (streaming + result)
  // ---------------------------------------------------------------------------

  /**
   * Fetch/install a model source. `sourceJson` is a serialised `ModelSource`.
   * Progress events flow to `subscriptionId`. Resolves with the completion
   * JSON `{ name, path, variant_id, bytes_downloaded, bytes_reused,
   * was_cached, model_handle }` — the TypeScript wrapper decodes it.
   */
  addModelSource(
    managerId: number,
    sourceJson: string,
    subscriptionId: string,
  ): Promise<string>;

  // ---------------------------------------------------------------------------
  // Catalog
  // ---------------------------------------------------------------------------

  catalogListModels(catalogId: number, filterJson: string | null): Promise<string>;
  catalogListCachedModels(catalogId: number): string;
  catalogGetModel(catalogId: number, alias: string): Promise<number>;
  catalogGetModelById(catalogId: number, modelId: string): Promise<number>;
  catalogGetCacheSizeBytes(catalogId: number): number;

  // ---------------------------------------------------------------------------
  // Model
  // ---------------------------------------------------------------------------

  modelGetInfo(modelId: number): string;
  modelIsPackage(modelId: number): boolean;
  modelIsCached(modelId: number): boolean;
  modelIsLoaded(modelId: number): boolean;
  modelGetPath(modelId: number): string;
  modelLoad(
    modelId: number,
    optionsJson: string | null,
    subscriptionId: string,
  ): Promise<void>;
  modelUnload(modelId: number): Promise<void>;
  modelDelete(modelId: number): Promise<void>;
  modelRelease(modelId: number): void;

  // ---------------------------------------------------------------------------
  // Package
  // ---------------------------------------------------------------------------

  packageGetVariants(modelId: number): string;
  packageSelectVariant(modelId: number, variantId: string): void;
  /** Returns the id of the selected variant. */
  packageSelectBestVariant(modelId: number, constraintsJson: string | null): string;
  packageGetVariant(modelId: number, variantId: string): number;
  packageEstimateDownload(
    modelId: number,
    variantIdsJson: string | null,
  ): string;

  // ---------------------------------------------------------------------------
  // Sessions (chat / audio / embedding)
  // ---------------------------------------------------------------------------

  sessionCreate(modelId: number, optionsJson: string): number;
  sessionRelease(sessionId: number): void;
  sessionSetOptions(sessionId: number, optionsJson: string): void;
  sessionExportHistory(sessionId: number): string;
  sessionRestoreHistory(sessionId: number, historyJson: string): void;
  sessionClearHistory(sessionId: number): void;
  sessionUndoTurns(sessionId: number, count: number): void;
  sessionGetTurnCount(sessionId: number): number;

  sessionComplete(sessionId: number, requestJson: string): Promise<string>;
  sessionCompleteStreaming(
    sessionId: number,
    requestJson: string,
    subscriptionId: string,
  ): Promise<void>;

  sessionSubmitToolResultsStreaming(
    sessionId: number,
    resultsJson: string,
    subscriptionId: string,
  ): Promise<void>;

  sessionTranscribe(sessionId: number, requestJson: string): Promise<string>;
  sessionTranscribeStreaming(
    sessionId: number,
    requestJson: string,
    subscriptionId: string,
  ): Promise<void>;
  sessionPushAudio(
    sessionId: number,
    pcmBase64: string,
    sampleRate: number,
    channels: number,
    isFinal: boolean,
  ): void;

  sessionEmbed(sessionId: number, requestJson: string): Promise<string>;

  // ---------------------------------------------------------------------------
  // Subscription lifecycle
  // ---------------------------------------------------------------------------

  /** Cancel a streaming or long-running subscription. Maps to `flm_job_cancel`. */
  cancelSubscription(subscriptionId: string): void;

  // NativeEventEmitter requires these on every module that emits events.
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('RNFoundryLocal');
