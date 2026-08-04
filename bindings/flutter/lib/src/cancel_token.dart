// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';

/// Cancels an in-flight `Future`-returning ABI call.
///
/// The ABI's cancellation primitive is `flm_job_cancel(handle)`, but any call
/// that hides its job handle behind a plain `Future` (e.g. [FoundryLocal.
/// addModelSource], [Model.load]) has no natural place to expose it. A
/// `CancelToken` is the caller-supplied out-of-band handle: pass it to the
/// call, then invoke [cancel] later — the plugin wires it to
/// `flm_job_cancel` internally.
///
/// The future resolves with a [CancelledException] (mapped from
/// `FLM_ERROR_CANCELLED`) once the core acknowledges the cancel; the
/// cancellation itself is asynchronous, so a running download may still fire
/// one or two more progress events before it stops.
///
/// A single token can be reused across sequential calls, but a token that has
/// already been cancelled will cancel subsequent calls immediately.
class CancelToken {
  final Completer<void> _cancelledCompleter = Completer<void>();

  /// Whether [cancel] has been invoked.
  bool get isCancelled => _cancelledCompleter.isCompleted;

  /// Completes when [cancel] is invoked. Used internally by the job runner
  /// to schedule a `flm_job_cancel` on the associated handle; app code does
  /// not usually need to await this directly.
  Future<void> get whenCancelled => _cancelledCompleter.future;

  /// Request cancellation. Idempotent — calling more than once is a no-op.
  void cancel() {
    if (_cancelledCompleter.isCompleted) return;
    _cancelledCompleter.complete();
  }
}
