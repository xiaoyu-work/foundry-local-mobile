// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'package:meta/meta.dart';

import '../bindings/bindings.dart' as raw;

/// A snapshot of the state of a long-running operation, copied out of the
/// borrowed `flm_progress` struct.
///
/// The core reports byte counters as `FLM_UNKNOWN_SIZE` (-1) when they are not
/// known yet; the getters ([completedBytes], [totalBytes], [bytesPerSecond],
/// [etaMillis]) surface those as `null` for ergonomic switch/if handling.
@immutable
class Progress {
  const Progress({
    required this.percent,
    required this.stage,
    required int completedBytesRaw,
    required int totalBytesRaw,
    required int bytesPerSecondRaw,
    required int etaMillisRaw,
    this.detail,
  })  : _completed = completedBytesRaw,
        _total = totalBytesRaw,
        _bps = bytesPerSecondRaw,
        _eta = etaMillisRaw;

  factory Progress.fromNative(raw.flm_progress p, String stage,
      {String? detail}) {
    return Progress(
      percent: p.percent,
      stage: stage,
      completedBytesRaw: p.completed_bytes,
      totalBytesRaw: p.total_bytes,
      bytesPerSecondRaw: p.bytes_per_second,
      etaMillisRaw: p.eta_ms,
      detail: detail,
    );
  }

  /// Progress in the closed interval `[0.0, 100.0]`.
  final double percent;

  /// [percent] normalised to `[0.0, 1.0]`, clamped both ends.
  ///
  /// Every progress UI writes the same divide-and-clamp against [percent]
  /// — `LinearProgressIndicator`'s `value`, `CircularProgressIndicator`'s
  /// `value`, and pretty much any custom bar all want a 0-to-1 double.
  /// Compute it once here rather than force every caller to open-code it
  /// and get the clamp wrong on the two edge samples the runtime does
  /// legitimately emit (percent < 0 when the total is not known yet and,
  /// very rarely, > 100 when a resume miscounts the last chunk).
  double get fraction {
    final v = percent / 100.0;
    if (v.isNaN) return 0.0;
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
  }

  /// Free-form stage name — `resolving`, `downloading`, `verifying`,
  /// `extracting`, `loading`, …
  final String stage;

  /// Item currently being processed (for example a variant id) when relevant.
  final String? detail;

  final int _completed;
  final int _total;
  final int _bps;
  final int _eta;

  int? get completedBytes => _completed == -1 ? null : _completed;
  int? get totalBytes => _total == -1 ? null : _total;
  int? get bytesPerSecond => _bps == -1 ? null : _bps;
  Duration? get eta => _eta == -1 ? null : Duration(milliseconds: _eta);
}
