// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

/// Foundry Local Mobile — on-device AI for Flutter.
///
/// This package is a `dart:ffi` plugin over the Foundry Local Mobile core, a
/// C++ layer above the Foundry Local ONNX Runtime GenAI runtime. It runs
/// entirely on the device; there is no backend, no per-token cost and no
/// network required for inference.
///
/// See [FoundryLocal] for the entry point.
library foundry_local_mobile;

export 'src/audio_session.dart' show AudioSession, AudioSessionOptions;
export 'src/cancel_token.dart' show CancelToken;
export 'src/catalog.dart' show Catalog, CatalogFilter;
export 'src/chat_session.dart' show ChatSession, ChatSessionOptions;
export 'src/embedding_session.dart' show EmbeddingSession;
export 'src/foundry_local.dart' show FoundryLocal, FlmLifecycleEventKind;
export 'src/model.dart' show LoadOptions, LoadResult, Model;
export 'src/model_package.dart' show ModelPackage;
export 'src/models/chat.dart'
    show
        AudioContent,
        ChatCompletion,
        ChatMessage,
        ChatRequest,
        ChatTool,
        ContentPart,
        EmbeddingResult,
        ImageContent,
        TextContent,
        ToolCall,
        ToolResult,
        TranscriptionResult,
        TranscriptionSegment,
        Usage;
export 'src/models/config.dart' show FoundryLocalConfig, RuntimeSettings;
export 'src/models/delta.dart'
    show
        CompletedDelta,
        FinishReason,
        ReasoningDelta,
        SessionDelta,
        SpeechDelta,
        TextDelta,
        ToolCallDelta,
        UsageDelta;
export 'src/models/device_profile.dart'
    show
        DeviceProfile,
        ExecutionProvider,
        FlmDevice,
        NetworkStatus,
        ThermalState;
export 'src/models/errors.dart'
    show
        CancelledException,
        FoundryLocalException,
        FoundryLocalStatus,
        IncompatibleModelException,
        MemoryPressureException,
        ShutdownException;
export 'src/models/model_info.dart' show ModelInfo, flmUnknownSize;
export 'src/models/model_source.dart'
    show
        BundledModelSource,
        ModelSource,
        ModelSourceResult,
        RemoteModelSource,
        VariantConstraints;
export 'src/models/model_variant.dart'
    show
        DownloadEstimate,
        ModelPackageManifest,
        ModelVariant;
export 'src/models/progress.dart' show Progress;
export 'src/session_base.dart' show Session;
export 'src/transport.dart'
    show
        DartHttpTransport,
        FlmHttpRequest,
        FlmTransport,
        FlmTransportReporter,
        TransportRegistration,
        installTransport;
