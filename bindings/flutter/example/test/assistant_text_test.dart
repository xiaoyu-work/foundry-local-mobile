// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'package:flutter_test/flutter_test.dart';
import 'package:foundry_local_mobile_example/assistant_text.dart';

void main() {
  test('removes only blank lines before the first visible response text', () {
    final buffer = AssistantTextBuffer();

    buffer
      ..append('\n')
      ..append('\n    On-device answer')
      ..append('\n\nSecond paragraph');

    expect(buffer.text, '    On-device answer\n\nSecond paragraph');
  });
}
