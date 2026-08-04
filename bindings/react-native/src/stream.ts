// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import { NativeEventEmitter, NativeModules } from 'react-native';
import NativeFoundryLocal from './NativeFoundryLocal';
import { FoundryLocalError } from './errors';
import type { Delta, Progress } from './types';

// -----------------------------------------------------------------------------
// Subscription plumbing
// -----------------------------------------------------------------------------

const emitter = new NativeEventEmitter(
  // The TurboModule instance itself is the emitter target on the New
  // Architecture. NativeModules.RNFoundryLocal is the legacy fallback that
  // NativeEventEmitter tolerates when the module lookup is by name.
  (NativeFoundryLocal as unknown) as { addListener: (name: string) => void; removeListeners: (n: number) => void }
    ?? NativeModules.RNFoundryLocal,
);

const EVENT_DELTA = 'FoundryLocal:delta';
const EVENT_PROGRESS = 'FoundryLocal:progress';
const EVENT_END = 'FoundryLocal:end';
const EVENT_ERROR = 'FoundryLocal:error';

let nextId = 0;
export function nextSubscriptionId(prefix: string): string {
  nextId += 1;
  return `${prefix}-${Date.now().toString(36)}-${nextId.toString(36)}`;
}

interface DeltaEvent { subscriptionId: string; delta: Delta }
interface ProgressEvent { subscriptionId: string; progress: Progress }
interface EndEvent { subscriptionId: string; resultJson?: string | null }
interface ErrorEvent {
  subscriptionId: string;
  status: number;
  message: string;
  detail?: string | null;
}

// -----------------------------------------------------------------------------
// Progress callback plumbing
// -----------------------------------------------------------------------------

/**
 * Wire a progress callback to a subscription id for the lifetime of the
 * outer promise. The returned function must be invoked on both success and
 * failure to clean up the two event listeners; the caller enforces that.
 */
export function wireProgress(
  subscriptionId: string,
  onProgress: ((p: Progress) => void) | undefined,
): () => void {
  if (!onProgress) return () => {};
  const sub = emitter.addListener(EVENT_PROGRESS, (event: ProgressEvent) => {
    if (event.subscriptionId === subscriptionId) {
      try { onProgress(event.progress); } catch { /* callback must not fail the stream */ }
    }
  });
  return () => sub.remove();
}

// -----------------------------------------------------------------------------
// Async iterator over deltas
// -----------------------------------------------------------------------------

interface StreamOptions {
  subscriptionId: string;
  /** Optional progress hook — for downloads embedded in a streaming call. */
  onProgress?: (p: Progress) => void;
  /**
   * Starts the native operation. Must resolve when the native side has
   * accepted the request; the actual data flows through the event emitter.
   */
  start: () => Promise<unknown>;
}

/**
 * Bridge a stream of native `delta` events into an `AsyncIterable<Delta>`.
 *
 * Backpressure: events are queued until the consumer pulls them. A slow
 * consumer will grow the queue rather than dropping deltas — the native side
 * is producing at model-generation rates (tens of tokens/second), so this is
 * a bounded, small backlog even in the worst case.
 *
 * Cancellation:
 * - Breaking out of `for await` invokes `return()`, which calls
 *   `cancelSubscription` and drains listeners. The native side is guaranteed
 *   to fire a terminal `end` or `error` event, so no listener leaks.
 * - An error event throws from the pending `next()` call, closing the
 *   iterator naturally.
 */
export function makeDeltaStream(opts: StreamOptions): AsyncIterable<Delta> {
  const queue: Delta[] = [];
  const waiters: {
    resolve: (v: IteratorResult<Delta>) => void;
    reject: (err: unknown) => void;
  }[] = [];
  let ended = false;
  let error: FoundryLocalError | null = null;

  const removeProgress = wireProgress(opts.subscriptionId, opts.onProgress);

  const deltaSub = emitter.addListener(EVENT_DELTA, (ev: DeltaEvent) => {
    if (ev.subscriptionId !== opts.subscriptionId) return;
    if (waiters.length > 0) {
      const w = waiters.shift()!;
      w.resolve({ value: ev.delta, done: false });
    } else {
      queue.push(ev.delta);
    }
  });

  const endSub = emitter.addListener(EVENT_END, (ev: EndEvent) => {
    if (ev.subscriptionId !== opts.subscriptionId) return;
    ended = true;
    while (waiters.length > 0) {
      const w = waiters.shift()!;
      w.resolve({ value: undefined as unknown as Delta, done: true });
    }
    cleanup();
  });

  const errorSub = emitter.addListener(EVENT_ERROR, (ev: ErrorEvent) => {
    if (ev.subscriptionId !== opts.subscriptionId) return;
    ended = true;
    error = new FoundryLocalError(ev.status, ev.message, ev.detail ?? null);
    while (waiters.length > 0) {
      const w = waiters.shift()!;
      w.reject(error);
    }
    cleanup();
  });

  let cleanedUp = false;
  const cleanup = () => {
    if (cleanedUp) return;
    cleanedUp = true;
    deltaSub.remove();
    endSub.remove();
    errorSub.remove();
    removeProgress();
  };

  const started = opts.start().catch((err) => {
    ended = true;
    error = FoundryLocalError.fromNative(err);
    while (waiters.length > 0) {
      const w = waiters.shift()!;
      w.reject(error);
    }
    cleanup();
  });

  return {
    [Symbol.asyncIterator](): AsyncIterator<Delta> {
      return {
        async next(): Promise<IteratorResult<Delta>> {
          if (error) throw error;
          if (queue.length > 0) {
            return { value: queue.shift()!, done: false };
          }
          if (ended) {
            return { value: undefined as unknown as Delta, done: true };
          }
          return new Promise<IteratorResult<Delta>>((resolve, reject) => {
            waiters.push({ resolve, reject });
          });
        },
        async return(): Promise<IteratorResult<Delta>> {
          if (!ended) {
            try { NativeFoundryLocal.cancelSubscription(opts.subscriptionId); }
            catch { /* module unloaded; nothing to cancel */ }
          }
          // Wait for `start` to settle so we do not race the native side
          // freeing the subscription.
          await started.catch(() => {});
          cleanup();
          return { value: undefined as unknown as Delta, done: true };
        },
        async throw(err: unknown): Promise<IteratorResult<Delta>> {
          if (!ended) {
            try { NativeFoundryLocal.cancelSubscription(opts.subscriptionId); }
            catch { /* ignore */ }
          }
          cleanup();
          throw err;
        },
      };
    },
  };
}
