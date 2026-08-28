# Model directories: flat models vs. OGA packages

Foundry Local Mobile does not have its own package format, catalog, or download
mechanism. `loadModel()` accepts exactly one thing: a path to a local directory, and OGA
itself decides how to load whatever is inside it. This page describes the two directory
shapes OGA supports and how the SDK picks between them.

## Flat OGA model

A directory with `genai_config.json` at its top level, alongside the model weights and
tokenizer files OGA needs (for example `model.onnx` / `model.onnx.data`,
`tokenizer.json`). This is the common case:

```
qwen3-5/
├── genai_config.json
├── model.onnx
├── model.onnx.data
└── tokenizer.json
```

```kotlin
val model = foundry.loadModel(path = "/data/user/0/com.example.app/files/models/qwen3-5")
```

When no `execution_provider` is given, the SDK calls `OgaCreateModel(path)` directly and
OGA uses whatever provider `genai_config.json` declares.

## OGA package directory

A directory with a top-level `manifest.json` and **no** top-level `genai_config.json`.
This is the ONNX Runtime GenAI package layout (sometimes shipped as `.ortpackage`), where
one manifest can describe multiple execution-provider-specific variants under a single
directory:

```
qwen3-5.ortpackage/
├── manifest.json
├── qnn/genai_config.json + compiled QNN artifacts
└── cpu/genai_config.json + CPU graph
```

Loading a package **requires** an explicit `execution_provider` — the SDK detects the
package shape (`manifest.json` present, `genai_config.json` absent at the top level) and
calls `OgaCreateConfigFromPackageEp(path, execution_provider, &config)` so OGA can resolve
the matching variant. There is no automatic multi-variant scoring performed by this SDK;
you choose the provider, OGA resolves the package against it.

```kotlin
val model = foundry.loadModel(
    path = "/data/user/0/com.example.app/files/models/qwen3-5.ortpackage",
    executionProvider = "QNN",
    providerOptions = mapOf("backend_path" to "libQnnHtp.so"),
)
```

## Execution provider selection

- **Flat models**: `executionProvider` is optional. If omitted, OGA uses the provider(s)
  declared in `genai_config.json`. If given, the SDK clears the configured providers and
  appends the requested one (`OgaConfigClearProviders` + `OgaConfigAppendProvider`) before
  applying any `providerOptions`.
- **Package directories**: `executionProvider` is required, since that is what
  `OgaCreateConfigFromPackageEp` resolves against.
- **`providerOptions`** is a flat string-keyed JSON object passed through to
  `OgaConfigSetProviderOption` for the selected provider — e.g. `backend_path` for QNN.

## What this SDK does not do

- It does not parse, validate, or score a `manifest.json` itself — that work happens
  inside OGA.
- It does not download, cache, verify, or delete model files. The directory you pass in
  must already be complete and correct.
- It does not merge multiple packages, recompile a model on-device, or manage per-variant
  storage. Each `loadModel()` call is independent.
- It enforces one thing beyond OGA: a memory budget check (`DeviceProfile::MaxModelBytes`)
  before loading, so a model that clearly will not fit in available RAM fails fast with
  `FLM_ERROR_MEMORY_PRESSURE` instead of getting killed by the OS mid-load.

## Getting a model onto the device

However you produce the directory — bundling it in the app package, downloading it with
your own HTTP/CDN client, unzipping it from your own storage — is entirely up to your
app. Once the files are in a local, caller-owned directory, pass that path to
`loadModel()`.
