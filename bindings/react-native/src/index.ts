// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

export { FoundryLocal } from './FoundryLocal';
export { Catalog } from './Catalog';
export { Model, ModelPackage } from './Model';
export {
  Session,
  ChatSession,
  AudioSession,
  EmbeddingSession,
} from './Session';
export {
  FoundryLocalError,
  statusToCode,
  type FoundryLocalErrorCode,
} from './errors';
export type {
  // Config
  FoundryLocalConfig,
  LogLevel,
  // Device profile
  DeviceProfile,
  ExecutionProviderInfo,
  FlmDevice,
  NetworkKind,
  ThermalState,
  // Model metadata
  ModelInfo,
  ModelVariant,
  PackageVariants,
  DownloadEstimate,
  VariantConstraints,
  // Model sources
  ModelSource,
  BundledModelSource,
  RemoteModelSource,
  ModelSourceResult,
  // Catalog
  CatalogFilter,
  // Sessions and requests
  ChatOptions,
  AudioOptions,
  EmbeddingOptions,
  ChatContentPart,
  ChatMessage,
  ChatRequest,
  Tool,
  ToolCall,
  ToolResult,
  CompleteResult,
  FinishReason,
  UsageStats,
  TranscribeRequest,
  TranscribeResult,
  TranscribeSegment,
  EmbeddingResult,
  // Streaming
  Delta,
  Progress,
} from './types';
