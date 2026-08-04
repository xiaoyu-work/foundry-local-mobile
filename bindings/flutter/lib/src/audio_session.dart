// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings/native_library.dart';
import 'error_capture.dart';
import 'job_runner.dart';
import 'model.dart';
import 'models/chat.dart';
import 'models/delta.dart';
import 'native_strings.dart';
import 'session_base.dart';

/// Options for an audio session.
class AudioSessionOptions {
  const AudioSessionOptions({this.language});
  final String? language;
  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'audio',
        if (language != null) 'language': language,
      };
}

/// A batch or streaming speech-to-text session.
class AudioSession extends Session {
  AudioSession._(Model model, int handle) : super(model: model, handle: handle);

  factory AudioSession.create(Model model, AudioSessionOptions options) =>
      AudioSession._(model, Session.createHandle(model, options.toJson()));

  /// Transcribe a file or a base64-encoded blob in one shot.
  Future<TranscriptionResult> transcribeFile(
    String path, {
    String? language,
    bool translate = false,
  }) async {
    final request = <String, Object?>{
      'path': path,
      if (language != null) 'language': language,
      'translate': translate,
    };
    final result = await withCString<Future<Map<String, Object?>>>(
      jsonEncode(request),
      (ptr) => runSimpleJob(
        (completionPtr, userData, outJob) =>
            NativeLibrary.instance.bindings.flm_session_transcribe_async(
          handle,
          ptr,
          nullptr,
          completionPtr,
          userData,
          outJob,
        ),
      ),
    );
    return TranscriptionResult.fromJson(result);
  }

  /// Streaming transcription of live PCM audio.
  ///
  /// Call [pushAudio] to feed chunks; a final [pushAudio] with `isFinal: true`
  /// tells the model to emit the last segment and close.
  Stream<SpeechDelta> startStreaming({
    int sampleRate = 16000,
    int channels = 1,
    String? language,
  }) {
    final bindings = NativeLibrary.instance.bindings;
    final request = <String, Object?>{
      'streaming': true,
      'sample_rate': sampleRate,
      'channels': channels,
      if (language != null) 'language': language,
    };
    late StreamController<SpeechDelta> controller;
    JobHandles<SessionDelta>? handles;
    controller = StreamController<SpeechDelta>(
      onListen: () {
        withCString<void>(jsonEncode(request), (ptr) {
          handles = runStreamingJob(
            (deltaPtr, completionPtr, userData, outJob) =>
                bindings.flm_session_transcribe_async(
              handle,
              ptr,
              deltaPtr,
              completionPtr,
              userData,
              outJob,
            ),
          );
          handles!.stream.listen(
            (d) {
              if (d is SpeechDelta) controller.add(d);
            },
            onError: controller.addError,
            onDone: controller.close,
          );
          handles!.result.catchError((_) => <String, Object?>{});
        });
      },
      onCancel: () => handles?.cancel(),
    );
    return controller.stream;
  }

  /// Push a chunk of PCM audio into a live transcription session.
  void pushAudio(
    Uint8List pcm, {
    required int sampleRate,
    required int channels,
    bool isFinal = false,
  }) {
    final ptr = calloc<Uint8>(pcm.length);
    try {
      ptr.asTypedList(pcm.length).setAll(0, pcm);
      final status = NativeLibrary.instance.bindings.flm_session_push_audio(
        handle,
        ptr.cast<Void>(),
        pcm.length,
        sampleRate,
        channels,
        isFinal ? 1 : 0,
      );
      checkStatus(status, fallbackMessage: 'flm_session_push_audio failed');
    } finally {
      calloc.free(ptr);
    }
  }
}
