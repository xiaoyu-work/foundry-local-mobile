// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Codable models for the JSON payloads the ABI shuttles across `char**` out-params
// and completion callbacks. The shapes here follow the schemas documented on
// `flm_manager_get_device_profile_json`, `flm_model_get_info_json`,
// `flm_package_get_variants_json`, `flm_package_estimate_download_json` and the job
// result JSONs listed on `flm_job_take_result_json`.
//
// The ABI is uniformly snake_case, so the shared JSONDecoder is configured with
// `keyDecodingStrategy = .convertFromSnakeCase` and the JSONEncoder with
// `keyEncodingStrategy = .convertToSnakeCase`. Explicit `CodingKeys` enums are avoided
// where a property name is a mechanical snake_case → camelCase conversion of the JSON
// key, because Foundation's strategy transforms the JSON key at lookup time and any
// hand-written CodingKey with a snake_case `stringValue` would then fail to match.

import Foundation
import FoundryLocalMobile

// Both instances are configured once at module load and are thread-safe to reuse per
// Apple's Foundation documentation. Swift 6 can't see that, so mark them explicitly.
nonisolated(unsafe) let flmJSONDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

nonisolated(unsafe) let flmJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
}()

// MARK: - Device profile

/// SoC / accelerator / runtime-state snapshot, mirroring
/// `flm_manager_get_device_profile_json`. Used by the SDK to score variants; apps that
/// run their own download policy read the same profile.
public struct DeviceProfile: Codable, Sendable {
    public let platform: String
    public let osVersion: String?
    public let deviceModel: String?
    public let soc: String?
    public let abi: String?
    public let cpuCores: Int
    public let totalMemoryBytes: Int64
    public let availableMemoryBytes: Int64
    public let availableStorageBytes: Int64
    public let hasNpu: Bool
    public let hasGpu: Bool
    public let executionProviders: [ExecutionProvider]
    public let thermalState: ThermalState
    public let lowPowerMode: Bool
    public let network: NetworkState

    public struct ExecutionProvider: Codable, Sendable {
        public let name: String
        public let device: Device
        public let available: Bool
        public let priority: Int
    }

    public enum ThermalState: String, Codable, Sendable {
        case nominal, fair, serious, critical, unknown

        public init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "unknown"
            self = ThermalState(rawValue: raw) ?? .unknown
        }
    }

    public enum NetworkState: String, Codable, Sendable {
        case unmetered, metered, offline, unknown

        public init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "unknown"
            self = NetworkState(rawValue: raw) ?? .unknown
        }
    }
}

/// Compute device a model variant targets. Values match `flm_device` but this is the
/// idiomatic Swift enum apps see on `ModelVariant.device`.
public enum Device: String, Codable, Sendable {
    case unknown, cpu, gpu, npu
}

// MARK: - Model info

/// Full model metadata, mirroring `flm_model_get_info_json`. Some fields are optional
/// because they only apply to particular task types (e.g. `contextLength` for chat).
public struct ModelInfo: Codable, Sendable {
    public let id: String
    public let alias: String?
    public let name: String
    public let displayName: String?
    public let version: Int?
    public let publisher: String?
    public let license: String?
    public let task: String?
    public let device: Device?
    public let executionProvider: String?
    public let fileSizeBytes: Int64?
    public let contextLength: Int?
    public let maxOutputTokens: Int?
    public let supportsToolCalling: Bool?
    public let supportsReasoning: Bool?
    public let inputModalities: [String]?
    public let outputModalities: [String]?
    public let isPackage: Bool?
    public let isCached: Bool?
    public let isLoaded: Bool?
    public let promptTemplates: [String: String]?
}

// MARK: - Model package variants

/// Enumeration of the variants of a model package, plus device-scored metadata used
/// for selection. Mirrors `flm_package_get_variants_json`.
public struct PackageVariants: Codable, Sendable {
    public let packageId: String
    public let schemaVersion: String?
    public let selectedVariantId: String?
    public let sharedAssetsBytes: Int64?
    public let variants: [ModelVariant]
}

/// One variant of a model package.
public struct ModelVariant: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let component: String?
    public let executionProvider: String
    public let device: Device
    public let compatibilityString: String?
    public let platform: String
    public let downloadSizeBytes: Int64
    public let diskSizeBytes: Int64
    public let sharedAssetRefs: [String]
    public let isCompatible: Bool
    public let compatibilityScore: Int
    public let isCached: Bool
    public let incompatibilityReason: String?

    public static func == (lhs: ModelVariant, rhs: ModelVariant) -> Bool {
        lhs.id == rhs.id
    }
}

/// Estimate returned by `flm_package_estimate_download_json`.
public struct DownloadEstimate: Codable, Sendable {
    public let downloadBytes: Int64
    public let diskBytes: Int64
    public let alreadyCachedBytes: Int64
    public let availableStorageBytes: Int64
    public let fitsOnDevice: Bool
}

// MARK: - Job results

/// Payload of `flm_catalog_list_models_async`.
struct CatalogListResult: Decodable {
    let models: [ModelInfo]
}

/// Payload of `flm_catalog_get_model_async`.
struct CatalogGetResult: Decodable {
    let modelHandle: UInt64
}

/// JSON DTO for `flm_manager_add_model_source_async`. The public
/// ``AddModelSourceResult`` wraps this and swaps the raw handle for a
/// ready-to-use ``Model``.
struct AddModelSourcePayload: Decodable {
    let name: String
    let path: String
    let variantId: String?
    let bytesDownloaded: Int64
    let bytesReused: Int64
    let wasCached: Bool
    /// Ready-to-use model handle, or `0` (`FLM_INVALID_HANDLE`) when the catalog
    /// scan did not pick up the freshly-committed files. `0` still means the
    /// transfer succeeded; the caller can look the model up via the catalog by
    /// ``name`` or work from ``path`` directly.
    let modelHandle: UInt64
}

/// Result of ``FoundryLocal/addModelSource(_:progress:)``. The download itself
/// has completed by the time this is returned — the files are on disk at
/// ``path`` — but variant selection, checksum verification and the local
/// catalog scan all ran inside the same job.
///
/// In the common case ``model`` is a ready-to-use handle minted inside that
/// same job, so acquisition is one round trip: no follow-up
/// `flm_catalog_get_model_async` is needed. ``model`` is `nil` only in the
/// rare case where the transfer succeeded but the catalog scan did not pick
/// up the freshly-installed files. That is not an error — the model *is* on
/// disk — so recover by looking the model up via ``FoundryLocal/catalog``
/// by ``name``, or work from ``path`` directly:
///
/// ```swift
/// let added = try await sdk.addModelSource(source)
/// let model = try await added.model ?? sdk.catalog.model(alias: added.name)
/// ```
public struct AddModelSourceResult: Sendable {
    /// Resolved model name (the `name` field from the ``ModelSource``).
    public let name: String
    /// Directory the model's files landed at.
    public let path: String
    /// Selected variant id when the source was a package, `nil` otherwise.
    /// (The ABI reports `""` for the non-package case; we normalise that
    /// to `nil` so a caller can just check `if let variantId`.)
    public let variantId: String?
    /// Bytes newly transferred during this call.
    public let bytesDownloaded: Int64
    /// Bytes reused from previously-cached shared assets.
    public let bytesReused: Int64
    /// `true` when every file was already on disk before this call and no
    /// transfer was needed.
    public let wasCached: Bool
    /// Ready-to-use model handle, or `nil` in the handle-less case documented
    /// on this type.
    public let model: Model?
}

/// Payload of `flm_model_load_async`. `flm_model_download_async` returns the same
/// shape, but the idiomatic Swift API no longer surfaces the download call — see
/// ``Model/load`` and the README's model-sources section.
public struct LoadResult: Decodable, Sendable {
    public let path: String
    public let bytes: Int64
}

/// Payload of `flm_session_complete_async`.
///
/// The core omits `toolCalls` and `usage` entirely (rather than encoding empty
/// values) when there is nothing to report, so both are optional. Callers should
/// treat `nil` as "not reported" rather than "reported empty".
public struct ChatCompletion: Decodable, Sendable {
    public let text: String?
    public let finishReason: FinishReason
    public let toolCalls: [ToolCall]?
    public let usage: TokenUsage?
}

/// Why the model stopped generating.
///
/// The known cases mirror the ABI's `flm_finish_reason` and the JSON strings
/// documented on `flm_job_take_result_json`. Unknown strings decode to
/// ``FinishReason/unknown(_:)`` rather than throwing so that a runtime that adds a
/// new reason keeps working with older builds of this SDK.
public enum FinishReason: Codable, Sendable, Equatable {
    /// Model stopped without a specific reason (e.g. before generation started).
    case none
    /// End-of-turn / stop-sequence reached.
    case stop
    /// `max_tokens` reached.
    case length
    /// The model requested one or more tool calls; the app should execute them and
    /// resubmit via ``ChatSession/submitToolResults``.
    case toolCalls
    /// Cancelled by ``ChatSession/cancel`` or Swift task cancellation.
    case cancelled
    /// The runtime raised an error mid-generation.
    case error
    /// A reason the runtime emitted that this SDK does not recognise. The raw JSON
    /// string is preserved so apps can still inspect it.
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .none: return "none"
        case .stop: return "stop"
        case .length: return "length"
        case .toolCalls: return "tool_calls"
        case .cancelled: return "cancelled"
        case .error: return "error"
        case .unknown(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FinishReason(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "stop": self = .stop
        case "length": self = .length
        case "tool_calls": self = .toolCalls
        case "cancelled": self = .cancelled
        case "error": self = .error
        default: self = .unknown(rawValue)
        }
    }

    init(cValue: flm_finish_reason) {
        // Match against the imported C enumerators directly; comparing against raw
        // integer values would depend on how the importer typed the storage.
        switch cValue {
        case FLM_FINISH_STOP: self = .stop
        case FLM_FINISH_LENGTH: self = .length
        case FLM_FINISH_TOOL_CALLS: self = .toolCalls
        case FLM_FINISH_CANCELLED: self = .cancelled
        case FLM_FINISH_ERROR: self = .error
        default: self = .none
        }
    }
}

/// A tool call the model requested.
///
/// ``arguments`` is the model's raw JSON string, exactly as delivered. The SDK
/// deliberately never parses or validates it: models can and do emit arguments that
/// don't match the declared tool schema, and whether that's fatal is the app's call.
/// Parse it yourself (with your own tolerant decoder) when you're ready to invoke
/// the tool.
public struct ToolCall: Codable, Sendable, Equatable {
    public let callId: String
    public let name: String
    /// Raw JSON string, as delivered by the model. May not match the tool's declared
    /// argument schema — do your own validation before invoking the tool.
    public let arguments: String

    public init(callId: String, name: String, arguments: String) {
        self.callId = callId
        self.name = name
        self.arguments = arguments
    }
}

/// Token counts for a completion. All three fields are populated when ``usage`` is
/// present on a ``ChatCompletion`` — if the runtime cannot report the numbers, it
/// omits the ``ChatCompletion/usage`` key entirely rather than emitting partial
/// counts.
public struct TokenUsage: Codable, Sendable {
    public let promptTokens: Int64
    public let completionTokens: Int64
    public let totalTokens: Int64
}

/// Payload of `flm_session_transcribe_async`.
public struct TranscriptionResult: Decodable, Sendable {
    public let text: String
    public let language: String?
    public let segments: [TranscriptionSegment]?
}

public struct TranscriptionSegment: Codable, Sendable {
    public let text: String
    public let startTimeMs: Int64
    public let endTimeMs: Int64
    /// Per-segment language when the model detected one; `nil` otherwise.
    public let language: String?
}

/// Payload of `flm_session_embed_async`.
public struct EmbeddingResult: Decodable, Sendable {
    public let embeddings: [[Float]]
    public let dimensions: Int
}

// MARK: - Chat request payload

/// One turn in a chat conversation. Encodable so the SDK can serialise apps' typed
/// values into the JSON shape `flm_session_complete_async` expects.
public struct ChatMessage: Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: [ChatContent]
    public var toolCallId: String?
    public var name: String?

    public init(role: Role, text: String) {
        self.role = role
        self.content = [.text(text)]
        self.toolCallId = nil
        self.name = nil
    }

    public init(role: Role, content: [ChatContent], toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.name = name
    }

    /// Convenience for the common `role == .user, content == "hello"` case.
    public static func user(_ text: String) -> ChatMessage { .init(role: .user, text: text) }
    public static func system(_ text: String) -> ChatMessage { .init(role: .system, text: text) }
    public static func assistant(_ text: String) -> ChatMessage { .init(role: .assistant, text: text) }
}

public enum ChatContent: Codable, Sendable {
    case text(String)
    case image(path: String? = nil, dataBase64: String? = nil)
    case audio(path: String? = nil, dataBase64: String? = nil, format: String? = nil, sampleRate: Int? = nil)

    enum CodingKeys: String, CodingKey {
        // Bare property names — the encoder's `.convertToSnakeCase` strategy takes
        // `dataBase64` and `sampleRate` to `data_base64` / `sample_rate` on the wire,
        // and the decoder's `.convertFromSnakeCase` strategy round-trips them back
        // for reads. Explicit snake_case string values here would defeat the strategy
        // and produce mismatched JSON keys.
        case type, text, path, dataBase64, format, sampleRate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let path, let data):
            try container.encode("image", forKey: .type)
            try container.encodeIfPresent(path, forKey: .path)
            try container.encodeIfPresent(data, forKey: .dataBase64)
        case .audio(let path, let data, let format, let sampleRate):
            try container.encode("audio", forKey: .type)
            try container.encodeIfPresent(path, forKey: .path)
            try container.encodeIfPresent(data, forKey: .dataBase64)
            try container.encodeIfPresent(format, forKey: .format)
            try container.encodeIfPresent(sampleRate, forKey: .sampleRate)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                path: try container.decodeIfPresent(String.self, forKey: .path),
                dataBase64: try container.decodeIfPresent(String.self, forKey: .dataBase64)
            )
        case "audio":
            self = .audio(
                path: try container.decodeIfPresent(String.self, forKey: .path),
                dataBase64: try container.decodeIfPresent(String.self, forKey: .dataBase64),
                format: try container.decodeIfPresent(String.self, forKey: .format),
                sampleRate: try container.decodeIfPresent(Int.self, forKey: .sampleRate)
            )
        default:
            self = .text("")
        }
    }
}

public struct ChatTool: Codable, Sendable {
    public var name: String
    public var description: String?
    /// Raw JSON schema string; kept opaque here because a strongly-typed JSON schema
    /// representation is out of scope and apps usually already have their tool
    /// definitions as strings.
    public var parametersJSON: String

    public init(name: String, description: String? = nil, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// Full chat completion request. Assembled by ``ChatSession`` from either the current
/// history or an ad-hoc set of messages, then encoded to JSON for the ABI.
public struct ChatRequest: Encodable, Sendable {
    public var messages: [ChatMessage]
    public var tools: [ChatTool]?
    public var toolChoice: String?
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var maxOutputTokens: Int?
    public var seed: Int64?
    public var stopSequences: [String]?

    // Bare property names. The shared encoder's `.convertToSnakeCase` strategy turns
    // `toolChoice` into `tool_choice`, `topP` into `top_p`, and so on. Custom
    // stringValues here would either double-transform or bypass the strategy.
    enum CodingKeys: String, CodingKey {
        case messages, tools, toolChoice, temperature, topP, topK, maxOutputTokens, seed, stopSequences
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messages, forKey: .messages)
        if let tools {
            var arr = container.nestedUnkeyedContainer(forKey: .tools)
            for tool in tools {
                var obj = arr.nestedContainer(keyedBy: ToolKeys.self)
                try obj.encode(tool.name, forKey: .name)
                try obj.encodeIfPresent(tool.description, forKey: .description)
                if let data = tool.parametersJSON.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    try obj.encode(AnyEncodable(parsed), forKey: .parameters)
                }
            }
        }
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(topP, forKey: .topP)
        try container.encodeIfPresent(topK, forKey: .topK)
        try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encodeIfPresent(seed, forKey: .seed)
        try container.encodeIfPresent(stopSequences, forKey: .stopSequences)
    }

    private enum ToolKeys: String, CodingKey {
        case name, description, parameters
    }

    public init(
        messages: [ChatMessage],
        tools: [ChatTool]? = nil,
        toolChoice: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        maxOutputTokens: Int? = nil,
        seed: Int64? = nil,
        stopSequences: [String]? = nil
    ) {
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxOutputTokens = maxOutputTokens
        self.seed = seed
        self.stopSequences = stopSequences
    }
}

/// Minimal `Encodable` shim that lets us push already-parsed JSON through
/// `JSONEncoder`. Used by ``ChatRequest`` for tool parameter schemas the app supplies
/// as a raw JSON string.
struct AnyEncodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let v as Bool:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Int64:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as String:
            try container.encode(v)
        case let v as [Any]:
            try container.encode(v.map(AnyEncodable.init))
        case let v as [String: Any]:
            try container.encode(v.mapValues(AnyEncodable.init))
        default:
            try container.encodeNil()
        }
    }
}
