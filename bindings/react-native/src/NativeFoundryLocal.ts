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
 * Every `number` returned from a `*Create` / `loadModel` / `sessionCreate`
 * call is **this binding's own registry slot id**, not the
 * underlying `flm_handle` from the C ABI. The native side (Kotlin on Android,
 * Swift on iOS) keeps a `HandleRegistry` that mints small sequential ids
 * starting at 1; the id going across the bridge is that slot number and
 * nothing more. The slot `0` is reserved as the invalid-handle sentinel so
 * `nullable` returns can share the same `double` type in the codegen'd spec
 * without an out-of-band signal.
 *
 * **`flm_handle` values must never cross this bridge.** A core handle packs
 * a kind tag into its high bits and every valid one exceeds `2^56` — see
 * `core/include/foundry_local_mobile/flm_types.h`. JavaScript's `number` is
 * an IEEE-754 double and is exact only to `2^53`; at handle magnitude the
 * spacing between representable values is 16, so passing a raw handle
 * through silently rounds away the low four bits of the slot index. It does
 * not raise — it resolves to a different slot or to nothing at all,
 * depending on which ids happen to be live, and surfaces as the wrong model
 * loading rather than as an error. The registry indirection is deliberate
 * and load-bearing. Do not "simplify" it by returning `flm_handle` values
 * to JS from a new method, and do not accept `flm_handle`-shaped ids from
 * JS in a new one.
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

  /**
   * SDK version, runtime version and runtime availability. Routed through a
   * live manager because the Kotlin binding exposes them as instance-level
   * accessors, and the codegen'd JNI bridge sits inside the manager. The
   * TypeScript wrapper hides that detail: from JS, `foundry.version` reads
   * like a property.
   */
  managerVersion(managerId: number): string;
  /** ONNX Runtime GenAI version, or empty string when the runtime is absent. */
  managerRuntimeVersion(managerId: number): string;
  managerIsRuntimeAvailable(managerId: number): boolean;
  managerSetLogLevel(managerId: number, level: number): void;

  loadModel(
    managerId: number,
    modelPath: string,
    optionsJson: string | null,
  ): Promise<string>;

  // ---------------------------------------------------------------------------
  // Model
  // ---------------------------------------------------------------------------

  modelGetInfo(modelId: number): string;
  modelIsCached(modelId: number): boolean;
  modelIsLoaded(modelId: number): boolean;
  modelGetPath(modelId: number): string;
  modelLoad(
    modelId: number,
    optionsJson: string | null,
    subscriptionId: string,
  ): Promise<void>;
  modelUnload(modelId: number): Promise<void>;
  modelRelease(modelId: number): void;

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
