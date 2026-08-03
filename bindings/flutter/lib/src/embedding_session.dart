// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:convert';

import 'bindings/native_library.dart';
import 'job_runner.dart';
import 'model.dart';
import 'models/chat.dart';
import 'native_strings.dart';
import 'session_base.dart';

/// A text-embedding session.
class EmbeddingSession extends Session {
  EmbeddingSession._(Model model, int handle)
      : super(model: model, handle: handle);

  factory EmbeddingSession.create(Model model) {
    final options = <String, Object?>{'type': 'embedding'};
    return EmbeddingSession._(model, Session.createHandle(model, options));
  }

  /// Compute embeddings for a batch of inputs.
  Future<EmbeddingResult> embed(List<String> inputs) async {
    final payload = jsonEncode(<String, Object?>{'inputs': inputs});
    final result = await withCString<Future<Map<String, Object?>>>(
      payload,
      (ptr) => runSimpleJob(
        (completionPtr, userData, outJob) =>
            NativeLibrary.instance.bindings.flm_session_embed_async(
          handle,
          ptr,
          completionPtr,
          userData,
          outJob,
        ),
      ),
    );
    return EmbeddingResult.fromJson(result);
  }
}
