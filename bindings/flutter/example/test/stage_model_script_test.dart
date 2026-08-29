// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _runtimeFiles = <String>[
  'chat_template.jinja',
  'genai_config.json',
  'model.onnx',
  'model.onnx.data',
  'tokenizer.json',
  'tokenizer_config.json',
];

void main() {
  test('stages every required runtime file without copying model data',
      () async {
    final source = await Directory.systemTemp.createTemp('flm-model-source-');
    final staged = await Directory.systemTemp.createTemp('flm-model-staged-');
    addTearDown(() => source.delete(recursive: true));
    addTearDown(() => staged.delete(recursive: true));
    for (final name in _runtimeFiles) {
      await File('${source.path}/$name').writeAsString(name);
    }

    final result = await Process.run(
      'bash',
      ['scripts/stage_model.sh', source.path, staged.path],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final sourcePath = await source.resolveSymbolicLinks();
    for (final name in _runtimeFiles) {
      final link = Link('${staged.path}/$name');
      expect(await link.exists(), isTrue, reason: '$name was not staged');
      expect(await link.resolveSymbolicLinks(), '$sourcePath/$name');
    }
  });

  test('rejects a model directory missing a required runtime file', () async {
    final source = await Directory.systemTemp.createTemp('flm-model-source-');
    final staged = await Directory.systemTemp.createTemp('flm-model-staged-');
    addTearDown(() => source.delete(recursive: true));
    addTearDown(() => staged.delete(recursive: true));
    for (final name in _runtimeFiles.where((name) => name != 'model.onnx.data')) {
      await File('${source.path}/$name').writeAsString(name);
    }

    final result = await Process.run(
      'bash',
      ['scripts/stage_model.sh', source.path, staged.path],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('model.onnx.data'));
  });
}
