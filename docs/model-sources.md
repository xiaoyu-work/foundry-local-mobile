# Model sources

A Foundry Local Mobile app gets its model one of two ways. Both end up as a directory the
runtime loads, so everything after acquisition — sessions, streaming, tool calling — is
identical.

| | Bundled | Remote |
|---|---|---|
| Where the model lives | Inside the app | On storage you control |
| Works offline on first launch | Yes | No |
| Adds to app size | Yes | No |
| Update without shipping a release | No | Yes |
| Good for | Small models, guaranteed availability | Large models, models that change |

You can use both: bundle a small model so the app works immediately, and download a larger
one in the background.

---

## Bundled

Ship the model inside the app, extract it to a directory you control, and hand over the
path.

```json
{
  "kind": "bundled",
  "name": "phi-4-mini",
  "path": "/data/user/0/com.example.app/files/models/phi-4-mini"
}
```

The model is loaded **in place**. The files are already on the device, and copying them
would double the storage the user pays for. Set `"copy_into_cache": true` only when the
source is somewhere you cannot keep, such as a temporary extraction directory.

### Android

Android cannot load a model directly out of `assets/` — the files are compressed inside the
APK and have no filesystem path. Extract once on first launch:

```kotlin
val modelDir = File(context.filesDir, "models/phi-4-mini")
if (!modelDir.exists()) {
    context.assets.extractDirectory("models/phi-4-mini", modelDir)
}

val model = manager.addModelSource(
    ModelSource.Bundled(name = "phi-4-mini", path = modelDir.absolutePath)
)
```

Large model files should be left uncompressed so the extraction is a plain copy:

```groovy
android {
    androidResources {
        noCompress += listOf("onnx", "onnx_data", "bin")
    }
}
```

### iOS

Files in the app bundle already have real paths, so no extraction is needed. Add the model
directory to the target as a **folder reference** (blue folder), not a group, so its
structure is preserved:

```swift
let path = Bundle.main.path(forResource: "phi-4-mini", ofType: nil)!
let model = try await manager.addModelSource(.bundled(name: "phi-4-mini", path: path))
```

### Bundling a package

A bundled model can be a model package rather than a single model. The SDK scores the
device against the variants and selects one at load time, so a single build can run the
NPU variant on hardware that has one and fall back to CPU everywhere else.

---

## Remote

Host the model on storage you control and give the SDK a URL. You supply the link and the
credentials; the SDK has no built-in provider, no default host, and no account of its own.

```json
{
  "kind": "remote",
  "name": "phi-4-mini",
  "url": "https://models.example.com/phi-4-mini/manifest.json",
  "headers": {
    "Authorization": "Bearer eyJhbGci..."
  }
}
```

`headers` is sent with every request. Because it is just headers, the same mechanism covers
every common setup with no per-provider code:

| Setup | How |
|---|---|
| Azure Blob SAS URL | Put the SAS token in the URL query string; no headers needed |
| Bearer token | `"Authorization": "Bearer <token>"` |
| API key | `"x-api-key": "<key>"` |
| Signed CDN URL | Signature in the URL; no headers needed |
| Public bucket | Omit `headers` |

A SAS token in the URL query string is preserved when per-file URLs are derived from the
manifest URL, so signed links keep working for every file in the download.

### Credentials that expire

Static headers cover the common case. A token that has to be refreshed part-way through a
multi-gigabyte download belongs in the **transport**, which is your own code — see
[Transport](#transport) below. Attach the current token there and it is always fresh,
including on retries.

### What the URL serves

The SDK sniffs the document rather than the URL, so a signed link with no meaningful path
works fine.

**A model package manifest** — an object with `components`. The device is scored against
the variants and only the matching one is downloaded, together with the shared assets it
references.

```json
{
  "schema_version": "1.0",
  "components": [{
    "name": "model",
    "variants": [
      {
        "id": "phi-4-mini.qnn",
        "path": "variants/qnn",
        "ep": "QNN",
        "device": "npu",
        "platform": "android",
        "compatibility_string": "v75",
        "files": [
          { "path": "variants/qnn/genai_config.json", "size": 2048, "digest": "sha256:1a2b..." },
          { "path": "variants/qnn/model.onnx", "size": 412000000, "digest": "sha256:3c4d..." }
        ],
        "shared_asset_refs": ["sha256:9f8e..."]
      },
      {
        "id": "phi-4-mini.cpu",
        "path": "variants/cpu",
        "ep": "CPU",
        "device": "cpu",
        "platform": "any",
        "files": [
          { "path": "variants/cpu/genai_config.json", "size": 2048, "digest": "sha256:5e6f..." },
          { "path": "variants/cpu/model.onnx", "size": 1900000000, "digest": "sha256:7a8b..." }
        ],
        "shared_asset_refs": ["sha256:9f8e..."]
      }
    ]
  }],
  "shared_assets": {
    "sha256:9f8e...": {
      "path": "shared/tokenizer",
      "size": 4200000,
      "files": [
        { "path": "shared/tokenizer/tokenizer.json", "size": 4200000, "digest": "sha256:9f8e..." }
      ]
    }
  }
}
```

The `files` array is what makes selective download possible: HTTPS offers no way to list a
directory, so the manifest has to say which files a variant needs before anything is
fetched. `size` and `digest` are optional per file but strongly recommended — `size`
enables the storage check and resume, `digest` enables verification.

**A flat file index** — an object with `files`, for a model that is not a package:

```json
{
  "files": [
    { "path": "genai_config.json", "size": 2048, "digest": "sha256:1a2b..." },
    { "path": "model.onnx", "size": 1900000000, "digest": "sha256:3c4d..." },
    { "path": "tokenizer.json", "size": 4200000 }
  ]
}
```

Relative paths are resolved against the manifest URL. A file may also carry an absolute
`"url"` to point somewhere else entirely, which is how you serve weights from a CDN while
keeping the manifest on an API host.

### Why selective download matters here

On desktop, downloading variants you cannot run wastes bandwidth. On a phone it is the
difference between a usable feature and an unusable one: the connection is often metered,
storage is finite and not expandable, and the variants a device cannot run are routinely
*larger* than the one it can — a CPU build carries full-precision weights where an NPU
build is quantized. So this is the default, not an optimization you opt into.

After a selective download the on-disk `manifest.json` is rewritten to describe only the
variant that was actually fetched, so the directory does not advertise variants whose files
are absent.

---

## Transport

The core plans downloads but never performs them. You install an HTTP transport at
startup and it moves the bytes.

This is not indirection for its own sake. A model download is hundreds of megabytes to
several gigabytes, so it has to survive the app being backgrounded — and the only APIs that
can do that are `URLSession` background sessions on Apple platforms and
`WorkManager`/`DownloadManager` on Android, both of which hand the transfer to a system
daemon that keeps running after your process is suspended. A socket loop inside the library
would be suspended with the process and then killed.

Delegating has three more consequences worth having:

- Your certificate pinning, proxy configuration, Android Network Security Config and
  per-app VPN rules all apply, because the request goes through your own HTTP stack.
- Credentials stay in your code, where they can be refreshed.
- The SDK ships no TLS or HTTP stack of its own, so it adds no CVE surface and no binary
  size for something the platform already has.

The default transports supplied by the Android and iOS bindings are the right choice for
most apps. Install your own when you need custom authentication, a proxy, or an existing
download queue.

---

## Behaviour common to both

**Resume.** Downloads resume across app restarts. A partially downloaded file is continued
from its current length rather than restarted, which matters when the app is killed near
the end of a multi-gigabyte transfer.

**Verification.** Every file with a `digest` is checked after download. A mismatch is
retried once — the usual cause is a truncated resume — and then the file is discarded and
the download fails rather than leaving a corrupt model on disk.

**Atomic completion.** Files land in their final location behind a `download.tmp` sentinel,
which keeps a half-finished directory invisible to the runtime. Removing the sentinel is
the single step that publishes the model, so an interrupted download can never be mistaken
for a usable one.

**Storage check.** A download that would not fit, with 20% headroom, is refused before it
starts. Filling the last byte of a phone's storage breaks unrelated apps.

**Metered networks.** A large download on a metered connection is refused unless
`download_on_metered_network` is enabled. Set it from your own UI once the user has agreed
to use their data.

**Path safety.** A manifest is remote input, so file paths that are absolute or that
traverse outside the model directory are rejected rather than written.

---

## Choosing at runtime

Nothing stops you from deciding per device. A common pattern is to bundle a small model for
immediate availability and fetch a better one when conditions allow:

```kotlin
val model = if (manager.deviceProfile.hasNpu && manager.deviceProfile.isUnmetered) {
    manager.addModelSource(ModelSource.Remote(name = "phi-4-mini", url = MANIFEST_URL, headers = authHeaders()))
} else {
    manager.addModelSource(ModelSource.Bundled(name = "phi-4-mini-small", path = bundledPath))
}
```
