// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foundry_local_mobile_example/model_path_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'com.microsoft.ai.foundry.local.mobile.example/model-assets',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('returns the absolute bundled model directory from iOS', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getBundledModelDirectory');
      return '/private/var/containers/Bundle/Application/model';
    });

    final path = await const ModelPathResolver(channel: channel).resolve();

    expect(path, '/private/var/containers/Bundle/Application/model');
  });

  test('rejects a missing bundled model directory', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);

    await expectLater(
      const ModelPathResolver(channel: channel).resolve(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('absolute model directory'),
        ),
      ),
    );
  });

  test('rejects a relative bundled model directory', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 'assets/model');

    await expectLater(
      const ModelPathResolver(channel: channel).resolve(),
      throwsA(isA<StateError>()),
    );
  });
}
