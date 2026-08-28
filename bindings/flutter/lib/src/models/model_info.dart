// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'package:meta/meta.dart';

import 'device_profile.dart';

/// The size sentinel used across every progress struct when a byte count is
/// not known yet. Mirrors `FLM_UNKNOWN_SIZE`.
const int flmUnknownSize = -1;

/// Metadata about a model handle.
///
/// Populated from `flm_model_get_info_json`. The raw JSON payload is kept in
/// [raw] so future ABI additions are visible without a Dart change.
@immutable
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.alias,
    required this.name,
    required this.displayName,
    required this.version,
    required this.publisher,
    required this.license,
    required this.task,
    required this.device,
    required this.executionProvider,
    required this.fileSizeBytes,
    required this.contextLength,
    required this.maxOutputTokens,
    required this.supportsToolCalling,
    required this.supportsReasoning,
    required this.inputModalities,
    required this.outputModalities,
    required this.isPackage,
    required this.isCached,
    required this.isLoaded,
    required this.promptTemplates,
    this.raw = const <String, Object?>{},
  });

  final String id;
  final String alias;
  final String name;
  final String displayName;
  final int version;
  final String publisher;
  final String license;
  final String task;
  final FlmDevice device;
  final String executionProvider;
  final int fileSizeBytes;
  final int contextLength;
  final int maxOutputTokens;
  final bool supportsToolCalling;
  final bool supportsReasoning;
  final List<String> inputModalities;
  final List<String> outputModalities;
  final bool isPackage;
  final bool isCached;
  final bool isLoaded;
  final Map<String, String> promptTemplates;
  final Map<String, Object?> raw;

  factory ModelInfo.fromJson(Map<String, Object?> json) {
    return ModelInfo(
      id: json['id'] as String? ?? '',
      alias: json['alias'] as String? ?? '',
      name: json['name'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      publisher: json['publisher'] as String? ?? '',
      license: json['license'] as String? ?? '',
      task: json['task'] as String? ?? '',
      device: FlmDevice.fromJson(json['device']),
      executionProvider: json['execution_provider'] as String? ?? '',
      fileSizeBytes: (json['file_size_bytes'] as num?)?.toInt() ?? 0,
      contextLength: (json['context_length'] as num?)?.toInt() ?? 0,
      maxOutputTokens: (json['max_output_tokens'] as num?)?.toInt() ?? 0,
      supportsToolCalling: json['supports_tool_calling'] as bool? ?? false,
      supportsReasoning: json['supports_reasoning'] as bool? ?? false,
      inputModalities:
          (json['input_modalities'] as List?)?.cast<String>() ??
              const <String>[],
      outputModalities:
          (json['output_modalities'] as List?)?.cast<String>() ??
              const <String>[],
      isPackage: json['is_package'] as bool? ?? false,
      isCached: json['is_cached'] as bool? ?? false,
      isLoaded: json['is_loaded'] as bool? ?? false,
      promptTemplates:
          (json['prompt_templates'] as Map?)?.cast<String, String>() ??
              const <String, String>{},
      raw: json,
    );
  }
}
