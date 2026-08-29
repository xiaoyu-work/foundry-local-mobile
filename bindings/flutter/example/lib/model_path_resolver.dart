// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'package:flutter/services.dart';

class ModelPathResolver {
  const ModelPathResolver({
    MethodChannel channel = const MethodChannel(channelName),
  }) : _channel = channel;

  static const channelName =
      'com.microsoft.ai.foundry.local.mobile.example/model-assets';

  final MethodChannel _channel;

  Future<String> resolve() async {
    final path =
        (await _channel.invokeMethod<String>('getBundledModelDirectory'))
            ?.trim();
    if (path == null || path.isEmpty || !path.startsWith('/')) {
      throw StateError(
        'iOS did not return an absolute model directory for the bundled model.',
      );
    }
    return path;
  }
}
