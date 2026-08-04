// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

// Unit tests for the pure-Dart pieces of the public API that do not touch
// FFI. Anything that reaches into the native library needs an on-device
// harness (see the example app); everything here can run under
// `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:foundry_local_mobile/foundry_local_mobile.dart';

void main() {
  group('Progress.fraction', () {
    Progress build(double percent) => Progress(
          percent: percent,
          stage: 'downloading',
          completedBytesRaw: -1,
          totalBytesRaw: -1,
          bytesPerSecondRaw: -1,
          etaMillisRaw: -1,
        );

    test('normalises percent to a 0..1 range', () {
      expect(build(0.0).fraction, 0.0);
      expect(build(50.0).fraction, closeTo(0.5, 1e-9));
      expect(build(100.0).fraction, 1.0);
    });

    test('clamps values outside the closed unit interval', () {
      // The runtime legitimately emits <0 when totals are unknown and,
      // in rare cases, >100 on a resume miscount. Both must clamp
      // rather than throw or bubble a NaN into the caller's UI.
      expect(build(-1.0).fraction, 0.0);
      expect(build(105.0).fraction, 1.0);
      expect(build(double.nan).fraction, 0.0);
    });
  });

  group('ModelSourceResult.requireModel', () {
    ModelSourceResult build({Model? model}) => ModelSourceResult(
          name: 'phi-4-mini',
          path: '/tmp/example/phi-4-mini',
          variantId: 'cpu-int4',
          bytesDownloaded: 42,
          bytesReused: 0,
          wasCached: false,
          model: model,
        );

    test('throws StateError naming name and path when model is null', () {
      final result = build();
      Object? caught;
      try {
        result.requireModel();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      final message = (caught! as StateError).message;
      expect(message, contains('phi-4-mini'));
      expect(message, contains('/tmp/example/phi-4-mini'));
      expect(message, contains('catalog-side bug'));
    });
  });
}
