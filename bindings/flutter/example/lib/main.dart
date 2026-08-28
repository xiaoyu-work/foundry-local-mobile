// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

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

enum _Phase { idle, loading, ready, chatting }

class _HomeScreen extends StatefulWidget {
  const _HomeScreen();

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  static const _defaultPath = String.fromEnvironment('FLM_MODEL_PATH');

  final _pathCtrl = TextEditingController(text: _defaultPath);
  final _promptCtrl = TextEditingController(
    text: 'In one sentence, what is on-device inference?',
  );
  final _logScroll = ScrollController();
  final _chatScroll = ScrollController();

  FoundryLocal? _foundry;
  Model? _model;
  ChatSession? _chat;
  StreamSubscription<SessionDelta>? _chatSub;

  _Phase _phase = _Phase.idle;
  double _progress = 0;
  String _progressStage = '';
  String _status = 'Ready';
  String _chatOutput = '';
  String _modelSummary = 'No model loaded.';
  final List<String> _log = <String>[];

  @override
  void dispose() {
    _chatSub?.cancel();
    _chat?.release();
    _model?.dispose();
    unawaited(_foundry?.dispose());
    _pathCtrl.dispose();
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
    final foundry = await FoundryLocal.create(
      const FoundryLocalConfig(appName: 'foundry_local_mobile_example'),
    );
    _foundry = foundry;
    _appendLog('FoundryLocal ready.');
    return foundry;
  }

  Future<void> _loadModel() async {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty) {
      setState(() => _status = 'Enter a model directory path.');
      return;
    }

    await _chatSub?.cancel();
    _chatSub = null;
    _chat?.release();
    _chat = null;
    _model?.dispose();
    _model = null;

    setState(() {
      _phase = _Phase.loading;
      _progress = 0;
      _progressStage = 'loading';
      _status = 'Loading model…';
      _chatOutput = '';
      _modelSummary = 'Loading $path';
    });

    try {
      final foundry = await _ensureFoundry();
      _appendLog('loadModel(path=$path)');
      final model = await foundry.loadModel(
        path,
        onProgress: (p) {
          setState(() {
            _progress = p.fraction;
            _progressStage = p.stage;
            _status = 'Loading… ${p.percent.toStringAsFixed(1)}% ($_progressStage)';
          });
        },
      );
      final info = model.getInfo();
      _model = model;
      _chat = model.createChatSession(
        options: const ChatSessionOptions(
          systemPrompt: 'You are a concise assistant.',
          temperature: 0.7,
        ),
      );
      _appendLog(
        'Loaded. path=${model.path} task=${info.task} ep=${info.executionProvider}',
      );
      setState(() {
        _phase = _Phase.ready;
        _status = 'Model ready.';
        _modelSummary =
            '${info.displayName.isEmpty ? info.name : info.displayName} '
            '(task=${info.task}, ep=${info.executionProvider})';
      });
    } catch (e) {
      _appendLog('Load failed: $e');
      setState(() {
        _phase = _Phase.idle;
        _status = 'Load failed: $e';
        _modelSummary = 'No model loaded.';
      });
    }
  }

  Future<void> _sendPrompt() async {
    final chat = _chat;
    if (chat == null) return;
    final prompt = _promptCtrl.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _phase = _Phase.chatting;
      _chatOutput = '';
      _status = 'Streaming…';
    });

    await _chatSub?.cancel();
    final completer = Completer<void>();
    _chatSub = chat.completeStreaming(
      ChatRequest(messages: [ChatMessage.user(prompt)]),
    ).listen(
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
        setState(() {
          _phase = _Phase.ready;
          _status = 'Stream error: $e';
        });
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        setState(() {
          _phase = _Phase.ready;
          _status = 'Done.';
        });
        if (!completer.isCompleted) completer.complete();
      },
    );
    await completer.future;
  }

  Future<void> _stopChat() async {
    await _chatSub?.cancel();
    _chatSub = null;
    setState(() {
      _phase = _Phase.ready;
      _status = 'Chat cancelled.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Foundry Local — path-only demo')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _modelCard(),
              const SizedBox(height: 12),
              _progressCard(),
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

  Widget _modelCard() {
    final canLoad = _phase == _Phase.idle || _phase == _Phase.ready;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('1. Load a local model directory',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _pathCtrl,
              enabled: canLoad,
              decoration: const InputDecoration(
                labelText: 'Model path',
                helperText:
                    'Absolute path to a local ONNX Runtime GenAI model directory.',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: canLoad ? _loadModel : null,
              child: const Text('Load model'),
            ),
            const SizedBox(height: 8),
            Text(_modelSummary),
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
              value: _phase == _Phase.loading
                  ? (_progress > 0 && _progress <= 1 ? _progress : null)
                  : 0,
            ),
            if (_progressStage.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('stage: $_progressStage'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chatCard() {
    final canSend = _phase == _Phase.ready && _chatSub == null && _chat != null;
    final canCancel = _chatSub != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('2. Streaming chat',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _promptCtrl,
              enabled: _chat != null,
              decoration: const InputDecoration(labelText: 'Prompt'),
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
                  onPressed: canCancel ? _stopChat : null,
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
