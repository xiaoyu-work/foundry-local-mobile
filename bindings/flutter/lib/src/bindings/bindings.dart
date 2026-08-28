// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

// GENERATED FILE — regenerate with `dart run ffigen --config ffigen.yaml`.
//
// This file is checked in so consumers do not need libclang installed to build the
// plugin. It is hand-maintained in exactly the shape ffigen would produce (see
// `ffigen.yaml`) so switching back to generated output is a single tool run away.
//
// The raw bindings are intentionally private to this package (`lib/src/`); the
// idiomatic Dart surface lives in `foundry_local_mobile.dart` and the classes it
// re-exports.

// ignore_for_file: type=lint, unused_import, unused_field, non_constant_identifier_names
// ignore_for_file: camel_case_types, constant_identifier_names

import 'dart:ffi' as ffi;

/// Raw FFI bindings for `flm_*` — the flat C ABI exposed by
/// `core/include/foundry_local_mobile/flm_api.h`.
///
/// The class is a thin resolver over a `DynamicLibrary`. There is exactly one
/// instance per process, held by [NativeLibrary]. All handles cross as `Uint64`
/// (Dart `int`) and every payload crosses as UTF-8 JSON (`Pointer<Utf8>`).
class FlmBindings {
  /// Holds the symbol lookup function used to resolve each entry point.
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
      _lookup;

  /// Bind against an already-opened `DynamicLibrary`.
  FlmBindings(ffi.DynamicLibrary dynamicLibrary) : _lookup = dynamicLibrary.lookup;

  /// Bind against a caller-supplied symbol lookup. Useful for statically linked
  /// builds (iOS) where the runtime library is the app executable itself.
  FlmBindings.fromLookup(
      ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
          lookup)
      : _lookup = lookup;

  // ---------------------------------------------------------------------------
  // Library-wide
  // ---------------------------------------------------------------------------

  ffi.Pointer<ffi.Char> flm_version_string() =>
      _flm_version_string();
  late final _flm_version_stringPtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Char> Function()>>(
          'flm_version_string');
  late final _flm_version_string =
      _flm_version_stringPtr.asFunction<ffi.Pointer<ffi.Char> Function()>(
          isLeaf: true);

  int flm_api_version() => _flm_api_version();
  late final _flm_api_versionPtr =
      _lookup<ffi.NativeFunction<ffi.Uint32 Function()>>('flm_api_version');
  late final _flm_api_version =
      _flm_api_versionPtr.asFunction<int Function()>(isLeaf: true);

  ffi.Pointer<ffi.Char> flm_runtime_version_string() =>
      _flm_runtime_version_string();
  late final _flm_runtime_version_stringPtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Char> Function()>>(
          'flm_runtime_version_string');
  late final _flm_runtime_version_string =
      _flm_runtime_version_stringPtr.asFunction<ffi.Pointer<ffi.Char> Function()>(
          isLeaf: true);

  void flm_string_free(ffi.Pointer<ffi.Char> str) => _flm_string_free(str);
  late final _flm_string_freePtr =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Char>)>>(
          'flm_string_free');
  late final _flm_string_free = _flm_string_freePtr
      .asFunction<void Function(ffi.Pointer<ffi.Char>)>(isLeaf: true);

  int flm_set_log_callback(
    flm_log_callback callback,
    ffi.Pointer<ffi.Void> user_data,
  ) =>
      _flm_set_log_callback(callback, user_data);
  late final _flm_set_log_callbackPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              flm_log_callback, ffi.Pointer<ffi.Void>)>>('flm_set_log_callback');
  late final _flm_set_log_callback = _flm_set_log_callbackPtr.asFunction<
      int Function(flm_log_callback, ffi.Pointer<ffi.Void>)>();

  int flm_set_log_level(int level) => _flm_set_log_level(level);
  late final _flm_set_log_levelPtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Int32)>>(
          'flm_set_log_level');
  late final _flm_set_log_level =
      _flm_set_log_levelPtr.asFunction<int Function(int)>(isLeaf: true);

  int flm_is_runtime_available() => _flm_is_runtime_available();
  late final _flm_is_runtime_availablePtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function()>>(
          'flm_is_runtime_available');
  late final _flm_is_runtime_available =
      _flm_is_runtime_availablePtr.asFunction<int Function()>(isLeaf: true);

  // ---------------------------------------------------------------------------
  // Errors
  // ---------------------------------------------------------------------------

  ffi.Pointer<ffi.Char> flm_last_error_message() => _flm_last_error_message();
  late final _flm_last_error_messagePtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Char> Function()>>(
          'flm_last_error_message');
  late final _flm_last_error_message = _flm_last_error_messagePtr
      .asFunction<ffi.Pointer<ffi.Char> Function()>(isLeaf: true);

  ffi.Pointer<ffi.Char> flm_last_error_detail_json() =>
      _flm_last_error_detail_json();
  late final _flm_last_error_detail_jsonPtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Char> Function()>>(
          'flm_last_error_detail_json');
  late final _flm_last_error_detail_json = _flm_last_error_detail_jsonPtr
      .asFunction<ffi.Pointer<ffi.Char> Function()>(isLeaf: true);

  void flm_clear_last_error() => _flm_clear_last_error();
  late final _flm_clear_last_errorPtr =
      _lookup<ffi.NativeFunction<ffi.Void Function()>>('flm_clear_last_error');
  late final _flm_clear_last_error =
      _flm_clear_last_errorPtr.asFunction<void Function()>(isLeaf: true);

  // ---------------------------------------------------------------------------
  // Manager
  // ---------------------------------------------------------------------------

  int flm_manager_create(
    ffi.Pointer<ffi.Char> config_json,
    ffi.Pointer<ffi.Uint64> out_manager,
  ) =>
      _flm_manager_create(config_json, out_manager);
  late final _flm_manager_createPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Uint64>)>>('flm_manager_create');
  late final _flm_manager_create = _flm_manager_createPtr.asFunction<
      int Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)>(isLeaf: true);

  int flm_manager_shutdown(int manager) => _flm_manager_shutdown(manager);
  late final _flm_manager_shutdownPtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Uint64)>>(
          'flm_manager_shutdown');
  late final _flm_manager_shutdown =
      _flm_manager_shutdownPtr.asFunction<int Function(int)>(isLeaf: true);

  int flm_manager_release(int manager) => _flm_manager_release(manager);
  late final _flm_manager_releasePtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Uint64)>>(
          'flm_manager_release');
  late final _flm_manager_release =
      _flm_manager_releasePtr.asFunction<int Function(int)>(isLeaf: true);

  int flm_manager_get_device_profile_json(
    int manager,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) =>
      _flm_manager_get_device_profile_json(manager, out_json);
  late final _flm_manager_get_device_profile_jsonPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64,
              ffi.Pointer<ffi.Pointer<ffi.Char>>)>>('flm_manager_get_device_profile_json');
  late final _flm_manager_get_device_profile_json =
      _flm_manager_get_device_profile_jsonPtr.asFunction<
          int Function(int, ffi.Pointer<ffi.Pointer<ffi.Char>>)>(isLeaf: true);

  int flm_manager_notify_lifecycle(int manager, int event) =>
      _flm_manager_notify_lifecycle(manager, event);
  late final _flm_manager_notify_lifecyclePtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64, ffi.Int32)>>('flm_manager_notify_lifecycle');
  late final _flm_manager_notify_lifecycle = _flm_manager_notify_lifecyclePtr
      .asFunction<int Function(int, int)>(isLeaf: true);

  int flm_manager_update_settings(
    int manager,
    ffi.Pointer<ffi.Char> settings_json,
  ) =>
      _flm_manager_update_settings(manager, settings_json);
  late final _flm_manager_update_settingsPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64,
              ffi.Pointer<ffi.Char>)>>('flm_manager_update_settings');
  late final _flm_manager_update_settings = _flm_manager_update_settingsPtr
      .asFunction<int Function(int, ffi.Pointer<ffi.Char>)>(isLeaf: true);

  // ---------------------------------------------------------------------------
  // Model loading
  // ---------------------------------------------------------------------------

  int flm_manager_load_model_async(
    int manager,
    ffi.Pointer<ffi.Char> model_path,
    ffi.Pointer<ffi.Char> options_json,
    flm_progress_callback on_progress,
    flm_completion_callback on_complete,
    ffi.Pointer<ffi.Void> user_data,
    ffi.Pointer<ffi.Uint64> out_job,
  ) =>
      _flm_manager_load_model_async(
          manager,
          model_path,
          options_json,
          on_progress,
          on_complete,
          user_data,
          out_job);
  late final _flm_manager_load_model_asyncPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64,
              ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Char>,
              flm_progress_callback,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>>('flm_manager_load_model_async');
  late final _flm_manager_load_model_async =
      _flm_manager_load_model_asyncPtr.asFunction<
          int Function(
              int,
              ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Char>,
              flm_progress_callback,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>(isLeaf: true);

  // ---------------------------------------------------------------------------
  // Model
  // ---------------------------------------------------------------------------

  int flm_model_release(int model) => _flm_model_release(model);
  late final _flm_model_releasePtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Uint64)>>(
          'flm_model_release');
  late final _flm_model_release =
      _flm_model_releasePtr.asFunction<int Function(int)>(isLeaf: true);

  int flm_model_get_info_json(
    int model,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) =>
      _flm_model_get_info_json(model, out_json);
  late final _flm_model_get_info_jsonPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64,
              ffi.Pointer<ffi.Pointer<ffi.Char>>)>>('flm_model_get_info_json');
  late final _flm_model_get_info_json = _flm_model_get_info_jsonPtr.asFunction<
      int Function(int, ffi.Pointer<ffi.Pointer<ffi.Char>>)>(isLeaf: true);

  int flm_model_is_cached(int model, ffi.Pointer<ffi.Int32> out_cached) =>
      _flm_model_is_cached(model, out_cached);
  late final _flm_model_is_cachedPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64, ffi.Pointer<ffi.Int32>)>>('flm_model_is_cached');
  late final _flm_model_is_cached = _flm_model_is_cachedPtr
      .asFunction<int Function(int, ffi.Pointer<ffi.Int32>)>(isLeaf: true);

  int flm_model_is_loaded(int model, ffi.Pointer<ffi.Int32> out_loaded) =>
      _flm_model_is_loaded(model, out_loaded);
  late final _flm_model_is_loadedPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64, ffi.Pointer<ffi.Int32>)>>('flm_model_is_loaded');
  late final _flm_model_is_loaded = _flm_model_is_loadedPtr
      .asFunction<int Function(int, ffi.Pointer<ffi.Int32>)>(isLeaf: true);

  int flm_model_get_path(
    int model,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_path,
  ) =>
      _flm_model_get_path(model, out_path);
  late final _flm_model_get_pathPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64,
              ffi.Pointer<ffi.Pointer<ffi.Char>>)>>('flm_model_get_path');
  late final _flm_model_get_path = _flm_model_get_pathPtr.asFunction<
      int Function(int, ffi.Pointer<ffi.Pointer<ffi.Char>>)>(isLeaf: true);

  int flm_model_load_async(
    int model,
    ffi.Pointer<ffi.Char> options_json,
    flm_progress_callback on_progress,
    flm_completion_callback on_complete,
    ffi.Pointer<ffi.Void> user_data,
    ffi.Pointer<ffi.Uint64> out_job,
  ) =>
      _flm_model_load_async(
          model, options_json, on_progress, on_complete, user_data, out_job);
  late final _flm_model_load_asyncPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64,
              ffi.Pointer<ffi.Char>,
              flm_progress_callback,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>>('flm_model_load_async');
  late final _flm_model_load_async = _flm_model_load_asyncPtr.asFunction<
      int Function(
          int,
          ffi.Pointer<ffi.Char>,
          flm_progress_callback,
          flm_completion_callback,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint64>)>(isLeaf: true);

  int flm_model_unload_async(
    int model,
    flm_completion_callback on_complete,
    ffi.Pointer<ffi.Void> user_data,
    ffi.Pointer<ffi.Uint64> out_job,
  ) =>
      _flm_model_unload_async(model, on_complete, user_data, out_job);
  late final _flm_model_unload_asyncPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>>('flm_model_unload_async');
  late final _flm_model_unload_async = _flm_model_unload_asyncPtr.asFunction<
      int Function(
          int,
          flm_completion_callback,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Uint64>)>(isLeaf: true);

  // ---------------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------------

  int flm_session_create(
    int model,
    ffi.Pointer<ffi.Char> options_json,
    ffi.Pointer<ffi.Uint64> out_session,
  ) =>
      _flm_session_create(model, options_json, out_session);
  late final _flm_session_createPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64, ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Uint64>)>>('flm_session_create');
  late final _flm_session_create = _flm_session_createPtr.asFunction<
      int Function(int, ffi.Pointer<ffi.Char>,
          ffi.Pointer<ffi.Uint64>)>(isLeaf: true);

  int flm_session_release(int session) => _flm_session_release(session);
  late final _flm_session_releasePtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Uint64)>>(
          'flm_session_release');
  late final _flm_session_release =
      _flm_session_releasePtr.asFunction<int Function(int)>(isLeaf: true);

  int flm_session_set_options(
    int session,
    ffi.Pointer<ffi.Char> options_json,
  ) =>
      _flm_session_set_options(session, options_json);
  late final _flm_session_set_optionsPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64,
              ffi.Pointer<ffi.Char>)>>('flm_session_set_options');
  late final _flm_session_set_options = _flm_session_set_optionsPtr
      .asFunction<int Function(int, ffi.Pointer<ffi.Char>)>(isLeaf: true);

  int flm_session_complete_async(
    int session,
    ffi.Pointer<ffi.Char> request_json,
    flm_delta_callback on_delta,
    flm_completion_callback on_complete,
    ffi.Pointer<ffi.Void> user_data,
    ffi.Pointer<ffi.Uint64> out_job,
  ) =>
      _flm_session_complete_async(
          session, request_json, on_delta, on_complete, user_data, out_job);
  late final _flm_session_complete_asyncPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64,
              ffi.Pointer<ffi.Char>,
              flm_delta_callback,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>>('flm_session_complete_async');
  late final _flm_session_complete_async =
      _flm_session_complete_asyncPtr.asFunction<
          int Function(
              int,
              ffi.Pointer<ffi.Char>,
              flm_delta_callback,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>(isLeaf: true);

  int flm_session_submit_tool_results_async(
    int session,
    ffi.Pointer<ffi.Char> tool_results_json,
    flm_delta_callback on_delta,
    flm_completion_callback on_complete,
    ffi.Pointer<ffi.Void> user_data,
    ffi.Pointer<ffi.Uint64> out_job,
  ) =>
      _flm_session_submit_tool_results_async(
          session,
          tool_results_json,
          on_delta,
          on_complete,
          user_data,
          out_job);
  late final _flm_session_submit_tool_results_asyncPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64,
              ffi.Pointer<ffi.Char>,
              flm_delta_callback,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>>(
      'flm_session_submit_tool_results_async');
  late final _flm_session_submit_tool_results_async =
      _flm_session_submit_tool_results_asyncPtr.asFunction<
          int Function(
              int,
              ffi.Pointer<ffi.Char>,
              flm_delta_callback,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>(isLeaf: true);

  int flm_session_transcribe_async(
    int session,
    ffi.Pointer<ffi.Char> request_json,
    flm_delta_callback on_delta,
    flm_completion_callback on_complete,
    ffi.Pointer<ffi.Void> user_data,
    ffi.Pointer<ffi.Uint64> out_job,
  ) =>
      _flm_session_transcribe_async(
          session, request_json, on_delta, on_complete, user_data, out_job);
  late final _flm_session_transcribe_asyncPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64,
              ffi.Pointer<ffi.Char>,
              flm_delta_callback,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>>('flm_session_transcribe_async');
  late final _flm_session_transcribe_async =
      _flm_session_transcribe_asyncPtr.asFunction<
          int Function(
              int,
              ffi.Pointer<ffi.Char>,
              flm_delta_callback,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>(isLeaf: true);

  int flm_session_push_audio(
    int session,
    ffi.Pointer<ffi.Void> pcm_data,
    int byte_count,
    int sample_rate,
    int channels,
    int is_final,
  ) =>
      _flm_session_push_audio(
          session, pcm_data, byte_count, sample_rate, channels, is_final);
  late final _flm_session_push_audioPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64,
              ffi.Pointer<ffi.Void>,
              ffi.Size,
              ffi.Int32,
              ffi.Int32,
              ffi.Int32)>>('flm_session_push_audio');
  late final _flm_session_push_audio = _flm_session_push_audioPtr.asFunction<
      int Function(int, ffi.Pointer<ffi.Void>, int, int, int, int)>(isLeaf: true);

  int flm_session_embed_async(
    int session,
    ffi.Pointer<ffi.Char> request_json,
    flm_completion_callback on_complete,
    ffi.Pointer<ffi.Void> user_data,
    ffi.Pointer<ffi.Uint64> out_job,
  ) =>
      _flm_session_embed_async(
          session, request_json, on_complete, user_data, out_job);
  late final _flm_session_embed_asyncPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64,
              ffi.Pointer<ffi.Char>,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>>('flm_session_embed_async');
  late final _flm_session_embed_async =
      _flm_session_embed_asyncPtr.asFunction<
          int Function(
              int,
              ffi.Pointer<ffi.Char>,
              flm_completion_callback,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint64>)>(isLeaf: true);

  int flm_session_get_turn_count(
    int session,
    ffi.Pointer<ffi.Size> out_count,
  ) =>
      _flm_session_get_turn_count(session, out_count);
  late final _flm_session_get_turn_countPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64,
              ffi.Pointer<ffi.Size>)>>('flm_session_get_turn_count');
  late final _flm_session_get_turn_count = _flm_session_get_turn_countPtr
      .asFunction<int Function(int, ffi.Pointer<ffi.Size>)>(isLeaf: true);

  int flm_session_undo_turns(int session, int count) =>
      _flm_session_undo_turns(session, count);
  late final _flm_session_undo_turnsPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64, ffi.Size)>>('flm_session_undo_turns');
  late final _flm_session_undo_turns = _flm_session_undo_turnsPtr
      .asFunction<int Function(int, int)>(isLeaf: true);

  int flm_session_clear_history(int session) =>
      _flm_session_clear_history(session);
  late final _flm_session_clear_historyPtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Uint64)>>(
          'flm_session_clear_history');
  late final _flm_session_clear_history =
      _flm_session_clear_historyPtr.asFunction<int Function(int)>(isLeaf: true);

  int flm_session_export_history_json(
    int session,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) =>
      _flm_session_export_history_json(session, out_json);
  late final _flm_session_export_history_jsonPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64,
              ffi.Pointer<ffi.Pointer<ffi.Char>>)>>('flm_session_export_history_json');
  late final _flm_session_export_history_json =
      _flm_session_export_history_jsonPtr.asFunction<
          int Function(int, ffi.Pointer<ffi.Pointer<ffi.Char>>)>(isLeaf: true);

  int flm_session_restore_history_json(
    int session,
    ffi.Pointer<ffi.Char> history_json,
  ) =>
      _flm_session_restore_history_json(session, history_json);
  late final _flm_session_restore_history_jsonPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64,
              ffi.Pointer<ffi.Char>)>>('flm_session_restore_history_json');
  late final _flm_session_restore_history_json =
      _flm_session_restore_history_jsonPtr
          .asFunction<int Function(int, ffi.Pointer<ffi.Char>)>(isLeaf: true);

  // ---------------------------------------------------------------------------
  // Jobs
  // ---------------------------------------------------------------------------

  int flm_job_get_state(int job, ffi.Pointer<ffi.Int32> out_state) =>
      _flm_job_get_state(job, out_state);
  late final _flm_job_get_statePtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(
              ffi.Uint64, ffi.Pointer<ffi.Int32>)>>('flm_job_get_state');
  late final _flm_job_get_state = _flm_job_get_statePtr
      .asFunction<int Function(int, ffi.Pointer<ffi.Int32>)>(isLeaf: true);

  int flm_job_cancel(int job) => _flm_job_cancel(job);
  late final _flm_job_cancelPtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Uint64)>>(
          'flm_job_cancel');
  late final _flm_job_cancel =
      _flm_job_cancelPtr.asFunction<int Function(int)>(isLeaf: true);

  int flm_job_take_result_json(
    int job,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) =>
      _flm_job_take_result_json(job, out_json);
  late final _flm_job_take_result_jsonPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64,
              ffi.Pointer<ffi.Pointer<ffi.Char>>)>>('flm_job_take_result_json');
  late final _flm_job_take_result_json = _flm_job_take_result_jsonPtr.asFunction<
      int Function(int, ffi.Pointer<ffi.Pointer<ffi.Char>>)>(isLeaf: true);

  int flm_job_release(int job) => _flm_job_release(job);
  late final _flm_job_releasePtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Uint64)>>(
          'flm_job_release');
  late final _flm_job_release =
      _flm_job_releasePtr.asFunction<int Function(int)>(isLeaf: true);

  int flm_job_wait(int job, int timeout_ms) => _flm_job_wait(job, timeout_ms);
  late final _flm_job_waitPtr = _lookup<
      ffi.NativeFunction<
          ffi.Int32 Function(ffi.Uint64, ffi.Int32)>>('flm_job_wait');
  late final _flm_job_wait =
      _flm_job_waitPtr.asFunction<int Function(int, int)>();
}

// -----------------------------------------------------------------------------
// Native structs (opaque to Dart other than a version field and native size)
// -----------------------------------------------------------------------------

/// C `flm_progress` — layout must match `flm_types.h`.
final class flm_progress extends ffi.Struct {
  @ffi.Uint32()
  external int version;

  @ffi.Float()
  external double percent;

  @ffi.Int64()
  external int completed_bytes;

  @ffi.Int64()
  external int total_bytes;

  @ffi.Int64()
  external int bytes_per_second;

  @ffi.Int64()
  external int eta_ms;

  external ffi.Pointer<ffi.Char> stage;

  external ffi.Pointer<ffi.Char> detail;
}

/// C `flm_delta`.
final class flm_delta extends ffi.Struct {
  @ffi.Uint32()
  external int version;

  @ffi.Int32()
  external int kind;

  external ffi.Pointer<ffi.Char> text;

  @ffi.Size()
  external int text_length;

  external ffi.Pointer<ffi.Char> tool_call_id;

  external ffi.Pointer<ffi.Char> tool_name;

  external ffi.Pointer<ffi.Char> tool_arguments_json;

  @ffi.Int64()
  external int start_time_ms;

  @ffi.Int64()
  external int end_time_ms;

  @ffi.Int64()
  external int prompt_tokens;

  @ffi.Int64()
  external int completion_tokens;

  @ffi.Int32()
  external int finish_reason;
}

// -----------------------------------------------------------------------------
// Native callback typedefs
// -----------------------------------------------------------------------------

typedef flm_progress_callback_native = ffi.Int32 Function(
    ffi.Uint64 job, ffi.Pointer<flm_progress> progress, ffi.Pointer<ffi.Void> user_data);
typedef flm_progress_callback = ffi.Pointer<ffi.NativeFunction<flm_progress_callback_native>>;

typedef flm_delta_callback_native = ffi.Int32 Function(
    ffi.Uint64 job, ffi.Pointer<flm_delta> delta, ffi.Pointer<ffi.Void> user_data);
typedef flm_delta_callback = ffi.Pointer<ffi.NativeFunction<flm_delta_callback_native>>;

typedef flm_completion_callback_native = ffi.Void Function(
    ffi.Uint64 job,
    ffi.Int32 status,
    ffi.Pointer<ffi.Char> error_json,
    ffi.Pointer<ffi.Void> user_data);
typedef flm_completion_callback = ffi.Pointer<ffi.NativeFunction<flm_completion_callback_native>>;

typedef flm_log_callback_native = ffi.Void Function(
    ffi.Int32 level,
    ffi.Pointer<ffi.Char> tag,
    ffi.Pointer<ffi.Char> message,
    ffi.Pointer<ffi.Void> user_data);
typedef flm_log_callback = ffi.Pointer<ffi.NativeFunction<flm_log_callback_native>>;

// -----------------------------------------------------------------------------
// Constants
// -----------------------------------------------------------------------------

/// Sentinel written into `flm_progress` counters when a byte count is not known.
const int FLM_UNKNOWN_SIZE = -1;

/// Sentinel handle. `0` is never a valid handle.
const int FLM_INVALID_HANDLE = 0;

/// ABI version this file was generated against. Matches `FLM_API_VERSION` in the header.
const int FLM_API_VERSION = 2;

// -----------------------------------------------------------------------------
// Enum mirrors
// -----------------------------------------------------------------------------

// Kept as plain `int` constants (matching ffigen's `as-int` config). The idiomatic
// Dart layer wraps these in real enums; nothing outside `lib/src/` should depend on
// the numeric values.

abstract class FlmStatus {
  static const int ok = 0;
  static const int internal = 1;
  static const int invalidArgument = 2;
  static const int invalidHandle = 3;
  static const int invalidState = 4;
  static const int notFound = 5;
  static const int notImplemented = 6;
  static const int cancelled = 7;
  static const int network = 8;
  static const int storage = 9;
  static const int outOfMemory = 10;
  static const int incompatible = 11;
  static const int timeout = 12;
  static const int unsupportedVersion = 13;
  static const int memoryPressure = 14;
  static const int shutdown = 15;
}

abstract class FlmLogLevel {
  static const int verbose = 0;
  static const int debug = 1;
  static const int info = 2;
  static const int warning = 3;
  static const int error = 4;
  static const int fatal = 5;
  static const int off = 6;
}

abstract class FlmDeviceKind {
  static const int unknown = 0;
  static const int cpu = 1;
  static const int gpu = 2;
  static const int npu = 3;
}

abstract class FlmJobState {
  static const int pending = 0;
  static const int running = 1;
  static const int succeeded = 2;
  static const int failed = 3;
  static const int cancelled = 4;
}

abstract class FlmDeltaKind {
  static const int text = 0;
  static const int reasoning = 1;
  static const int toolCall = 2;
  static const int speechPartial = 3;
  static const int speechFinal = 4;
  static const int usage = 5;
  static const int completed = 6;
}

abstract class FlmFinishReason {
  static const int none = 0;
  static const int stop = 1;
  static const int length = 2;
  static const int toolCalls = 3;
  static const int cancelled = 4;
  static const int error = 5;
}

abstract class FlmLifecycleEvent {
  static const int foreground = 0;
  static const int background = 1;
  static const int memoryWarning = 2;
  static const int memoryCritical = 3;
  static const int lowPower = 4;
  static const int thermalThrottling = 5;
  static const int networkMetered = 6;
  static const int networkUnmetered = 7;
}
