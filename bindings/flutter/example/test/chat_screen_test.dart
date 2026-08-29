// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foundry_local_mobile_example/main.dart';

void main() {
  testWidgets('keeps the model identity and chat composer on the primary screen',
      (tester) async {
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const FoundryDemoApp());
    await tester.pump();

    expect(find.text('Qwen3 0.6B INT4'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-message-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(find.text('Model path'), findsNothing);
    expect(find.text('Load model'), findsNothing);
    expect(find.text('Log'), findsNothing);

    final composerRect =
        tester.getRect(find.byKey(const ValueKey('chat-composer')));
    expect(composerRect.bottom, lessThanOrEqualTo(874));
    expect(composerRect.height, greaterThanOrEqualTo(48));
  });
}
