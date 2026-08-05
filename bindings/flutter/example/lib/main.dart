// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

// End-to-end example for the foundry_local_mobile plugin: register a
// bring-your-own remote model source, watch the download, resolve the
// package's variant table, load the model, and stream a chat completion
// token by token. Every step goes through the plugin's public API — nothing
// here reaches into `src/`.
//
// Run:
//   flutter run \
//     --dart-define=FLM_MODEL_URL=https://.../manifest.json \
//     --dart-define=FLM_MODEL_AUTH="Bearer ..."      \
//     --dart-define=FLM_MODEL_NAME=qwen2.5-0.5b-instruct-generic-cpu:4
//
// The name must be the model's catalog id, version suffix and all: the runtime
// reads the model's task from the catalog, and a name it has never seen has no
// task, so no chat session can be created from it.
//
// Both fields can also be typed on-screen. Credentials are held only in
// widget state — no writes back to disk, and nothing here that a
// screenshot-committing habit could turn into a leak.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:foundry_local_mobile/foundry_local_mobile.dart';

void main() {
  runApp(const FoundryDemoApp());
}

class FoundryDemoApp extends StatelessWidget {
  const FoundryDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Foundry Local demo',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const _HomeScreen(),
    );
  }
}

class _HomeScreen extends StatefulWidget {
  const _HomeScreen();

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

/// Phases the demo walks through in order. Each is a strict superset of the
/// previous — none of the transitions are undoable, which keeps the app's
/// error paths shallow and the wiring easy to reason about.
enum _Phase { idle, downloading, ready, loading, chatting }

class _HomeScreenState extends State<_HomeScreen> {
  static const _defaultName = String.fromEnvironment(
    'FLM_MODEL_NAME',
    defaultValue: 'qwen2.5-0.5b-instruct-generic-cpu:4',
  );
  static const _defaultUrl = String.fromEnvironment('FLM_MODEL_URL');
  static const _defaultAuth = String.fromEnvironment('FLM_MODEL_AUTH');

  final _nameCtrl = TextEditingController(text: _defaultName);
  final _urlCtrl = TextEditingController(text: _defaultUrl);
  final _authCtrl = TextEditingController(text: _defaultAuth);
  final _promptCtrl = TextEditingController(
    text: 'In one sentence, what is on-device inference?',
  );
  final _logScroll = ScrollController();
  final _chatScroll = ScrollController();

  FoundryLocal? _foundry;
  Model? _model;
  ChatSession? _chat;
  ModelSourceResult? _sourceResult;
  ModelPackageManifest? _manifest;

  CancelToken? _downloadCancel;
  StreamSubscription<SessionDelta>? _chatSub;

  _Phase _phase = _Phase.idle;
  double _progress = 0;
  String _progressStage = '';
  String _status = 'Ready';
  final List<String> _log = <String>[];
  String _chatOutput = '';

  @override
  void dispose() {
    _chatSub?.cancel();
    _chat?.release();
    _model?.release();
    unawaited(_foundry?.dispose());
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _authCtrl.dispose();
    _promptCtrl.dispose();
    _logScroll.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  void _appendLog(String line) {
    setState(() => _log.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<FoundryLocal> _ensureFoundry() async {
    final existing = _foundry;
    if (existing != null) return existing;
    _appendLog('Initialising FoundryLocal…');
    final f = await FoundryLocal.create(
      const FoundryLocalConfig(appName: 'foundry_local_mobile_example'),
    );
    _foundry = f;
    _appendLog('FoundryLocal ready.');
    return f;
  }

  /// Register the remote model source and drive the download.
  ///
  /// The `constraints` here are what makes this the real feature demo rather
  /// than a smoke test: the core scores the manifest against this device
  /// **before** any weights transfer, so if the manifest ships a CoreML
  /// variant we skip it on Android without paying the bytes.
  Future<void> _downloadModel() async {
    final url = _urlCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    if (url.isEmpty || name.isEmpty) {
      setState(() => _status = 'A model name and URL are required.');
      return;
    }
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _progressStage = 'starting';
      _status = 'Requesting manifest…';
    });

    final headers = <String, String>{
      if (_authCtrl.text.trim().isNotEmpty) 'Authorization': _authCtrl.text.trim(),
    };
    final source = RemoteModelSource(
      name: name,
      url: url,
      headers: headers,
      constraints: const VariantConstraints(
        allowedDevices: [FlmDevice.npu, FlmDevice.gpu, FlmDevice.cpu],
        maxDownloadBytes: 2 * 1024 * 1024 * 1024,
      ),
    );
    final cancel = CancelToken();
    _downloadCancel = cancel;
    try {
      final foundry = await _ensureFoundry();
      _appendLog('addModelSource(name=$name)');
      final result = await foundry.addModelSource(
        source,
        cancelToken: cancel,
        onProgress: (p) {
          setState(() {
            _progress = p.fraction;
            _progressStage = p.stage;
            _status = 'Downloading… ${p.percent.toStringAsFixed(1)}% ($_progressStage)';
          });
        },
      );
      // requireModel throws only in the "download succeeded but catalog
      // scan missed it" case, which is a bug we would want to surface
      // during app testing. Real apps that want to recover instead can
      // read result.model directly and fall back to catalog.getModel.
      final model = result.requireModel();
      _sourceResult = result;
      _model = model;
      _manifest = model.package?.manifest;
      _appendLog(
        'Download complete. path=${result.path} variantId=${result.variantId ?? "-"} '
        'bytesDownloaded=${result.bytesDownloaded} bytesReused=${result.bytesReused} '
        'wasCached=${result.wasCached} handleResolved=${result.model != null}',
      );
      setState(() {
        _phase = _Phase.ready;
        _status = 'Model on device.';
      });
    } on CancelledException {
      _appendLog('Download cancelled by user.');
      setState(() {
        _phase = _Phase.idle;
        _status = 'Cancelled.';
        _progress = 0;
      });
    } catch (e) {
      _appendLog('Download failed: $e');
      setState(() {
        _phase = _Phase.idle;
        _status = 'Download failed: $e';
      });
    } finally {
      _downloadCancel = null;
    }
  }

  void _cancelDownload() {
    _downloadCancel?.cancel();
  }

  Future<void> _loadModel() async {
    final model = _model;
    if (model == null) return;
    setState(() {
      _phase = _Phase.loading;
      _status = 'Loading weights into runtime…';
      _progress = 0;
      _progressStage = 'loading';
    });
    try {
      final result = await model.load(
        onProgress: (p) {
          setState(() {
            _progress = p.fraction;
            _progressStage = p.stage;
            _status = 'Loading… ${p.percent.toStringAsFixed(1)}% ($_progressStage)';
          });
        },
      );
      _appendLog('Loaded. path=${result.path} bytes=${result.bytes}');
      _chat = model.createChatSession(
        options: const ChatSessionOptions(
          systemPrompt: 'You are a concise assistant.',
          temperature: 0.7,
        ),
      );
      setState(() {
        _phase = _Phase.chatting;
        _status = 'Ready to chat.';
      });
    } catch (e) {
      _appendLog('Load failed: $e');
      setState(() {
        _phase = _Phase.ready;
        _status = 'Load failed: $e';
      });
    }
  }

  Future<void> _sendPrompt() async {
    final chat = _chat;
    if (chat == null) return;
    final prompt = _promptCtrl.text.trim();
    if (prompt.isEmpty) return;
    setState(() {
      _chatOutput = '';
      _status = 'Streaming…';
    });
    final request = ChatRequest(
      messages: [ChatMessage.user(prompt)],
    );
    await _chatSub?.cancel();
    final completer = Completer<void>();
    _chatSub = chat.completeStreaming(request).listen(
      (delta) {
        if (delta is TextDelta) {
          setState(() => _chatOutput += delta.text);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_chatScroll.hasClients) {
              _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
            }
          });
        } else if (delta is CompletedDelta) {
          _appendLog(
            'Completed. reason=${delta.finishReason.name} '
            'prompt=${delta.promptTokens} completion=${delta.completionTokens}',
          );
        }
      },
      onError: (Object e) {
        _appendLog('Stream error: $e');
        setState(() => _status = 'Stream error: $e');
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        setState(() => _status = 'Done.');
        if (!completer.isCompleted) completer.complete();
      },
    );
    await completer.future;
  }

  Future<void> _cancelChat() async {
    await _chatSub?.cancel();
    _chatSub = null;
    setState(() => _status = 'Chat cancelled.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Foundry Local — end-to-end demo'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sourceCard(),
              const SizedBox(height: 12),
              _progressCard(),
              const SizedBox(height: 12),
              _variantCard(),
              const SizedBox(height: 12),
              Expanded(child: _chatCard()),
              const SizedBox(height: 12),
              _logCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sourceCard() {
    final canStart = _phase == _Phase.idle;
    final canCancel = _phase == _Phase.downloading;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('1. Remote model source',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              enabled: canStart,
              decoration: const InputDecoration(
                labelText: 'Model name (the model\'s catalog id)',
                helperText: 'Chat needs a task, and the task comes with the id',
              ),
            ),
            TextField(
              controller: _urlCtrl,
              enabled: canStart,
              decoration: const InputDecoration(
                labelText: 'Manifest URL',
                hintText: 'https://…/manifest.json',
              ),
            ),
            TextField(
              controller: _authCtrl,
              enabled: canStart,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Authorization header (optional)',
                hintText: 'Bearer …',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: canStart ? _downloadModel : null,
                  child: const Text('Download'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: canCancel ? _cancelDownload : null,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: _phase == _Phase.downloading || _phase == _Phase.loading
                  ? (_progress > 0 && _progress <= 1 ? _progress : null)
                  : 0,
            ),
          ],
        ),
      ),
    );
  }

  Widget _variantCard() {
    final result = _sourceResult;
    final manifest = _manifest;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('2. Model package + selected variant',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (result == null)
              const Text('Downloading a source populates this.')
            else ...[
              Text('Chosen variant: ${result.variantId?.isNotEmpty == true ? result.variantId : "(flat model, no variants)"}'),
              const SizedBox(height: 4),
              if (manifest != null && manifest.variants.isNotEmpty)
                ..._variantRows(manifest, selectedId: result.variantId)
              else
                const Text('No package manifest (this is a flat model).'),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _phase == _Phase.ready ? _loadModel : null,
                child: const Text('Load into runtime'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _variantRows(ModelPackageManifest manifest, {String? selectedId}) {
    final rows = <Widget>[
      const Row(
        children: [
          Expanded(flex: 3, child: Text('id')),
          Expanded(flex: 2, child: Text('device')),
          Expanded(flex: 2, child: Text('EP')),
          Expanded(flex: 2, child: Text('MB')),
          Expanded(flex: 1, child: Text('score')),
          Expanded(flex: 1, child: Text('ok')),
        ],
      ),
      const Divider(height: 1),
    ];
    for (final v in manifest.variants) {
      final chosen = v.id == selectedId;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  v.id,
                  style: TextStyle(
                    fontWeight: chosen ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              Expanded(flex: 2, child: Text(v.device.name)),
              Expanded(flex: 2, child: Text(v.executionProvider)),
              Expanded(
                flex: 2,
                child: Text((v.downloadSizeBytes / (1024 * 1024))
                    .toStringAsFixed(1)),
              ),
              Expanded(flex: 1, child: Text('${v.compatibilityScore}')),
              Expanded(
                flex: 1,
                child: Text(v.isCompatible ? '✓' : '✗'),
              ),
            ],
          ),
        ),
      );
      if (!v.isCompatible && v.incompatibilityReason != null) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 4),
            child: Text('why-not: ${v.incompatibilityReason}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
        );
      }
    }
    return rows;
  }

  Widget _chatCard() {
    final canSend = _phase == _Phase.chatting && _chatSub == null;
    final canCancel = _chatSub != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('3. Streaming chat',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _promptCtrl,
              enabled: _phase == _Phase.chatting,
              decoration: const InputDecoration(
                labelText: 'Prompt',
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                FilledButton(
                  onPressed: canSend ? _sendPrompt : null,
                  child: const Text('Send'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: canCancel ? _cancelChat : null,
                  child: const Text('Stop'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.all(8),
                child: SingleChildScrollView(
                  controller: _chatScroll,
                  child: Text(_chatOutput),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SizedBox(
              height: 100,
              child: ListView.builder(
                controller: _logScroll,
                itemCount: _log.length,
                itemBuilder: (context, i) => Text(
                  _log[i],
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
