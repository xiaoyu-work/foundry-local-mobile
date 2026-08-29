// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:foundry_local_mobile/foundry_local_mobile.dart';

import 'model_path_resolver.dart';

void main() {
  runApp(const FoundryDemoApp());
}

class FoundryDemoApp extends StatelessWidget {
  const FoundryDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Qwen3 on device',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10A37F),
          surface: const Color(0xFFF7F7F8),
        ),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const _HomeScreen(),
    );
  }
}

enum _Phase { idle, loading, ready, chatting }

enum _MessageRole { user, assistant }

class _ConversationMessage {
  _ConversationMessage({
    required this.role,
    required this.text,
    this.isThinking = false,
  });

  final _MessageRole role;
  String text;
  bool isThinking;
  bool isError = false;
}

class _HomeScreen extends StatefulWidget {
  const _HomeScreen();

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  static const _modelName = 'Qwen3 0.6B INT4';
  static const _defaultPath = String.fromEnvironment('FLM_MODEL_PATH');
  static const _autoRun = bool.fromEnvironment('FLM_AUTORUN');

  final _promptCtrl = TextEditingController();
  final _chatScroll = ScrollController();
  final _composerFocus = FocusNode();
  final List<_ConversationMessage> _messages = <_ConversationMessage>[];

  FoundryLocal? _foundry;
  Model? _model;
  ChatSession? _chat;
  StreamSubscription<SessionDelta>? _chatSub;

  _Phase _phase = _Phase.loading;
  double _progress = 0;
  String _status = 'Loading model on device...';
  bool _receivedTextDelta = false;
  bool _receivedReasoningDelta = false;
  final File _deviceLogFile = File('${Directory.systemTemp.path}/flm_e2e.log');
  Future<void> _deviceLogWrites = Future<void>.value();
  bool _hasWrittenDeviceLog = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_resolveAndLoadDefaultModel());
    });
  }

  @override
  void dispose() {
    _chatSub?.cancel();
    _chat?.release();
    _model?.dispose();
    unawaited(_foundry?.dispose());
    _promptCtrl.dispose();
    _chatScroll.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _appendLog(String line) {
    debugPrint('[FLM] $line');
    _deviceLogWrites = _deviceLogWrites.then((_) async {
      try {
        await _deviceLogFile.writeAsString(
          '${DateTime.now().toIso8601String()} $line\n',
          mode: _hasWrittenDeviceLog ? FileMode.append : FileMode.write,
          flush: true,
        );
        _hasWrittenDeviceLog = true;
      } catch (error) {
        debugPrint('[FLM] Unable to persist device log: $error');
      }
    });
  }

  Future<void> _resolveAndLoadDefaultModel() async {
    try {
      final path = Platform.isIOS
          ? await const ModelPathResolver().resolve()
          : _defaultPath;
      if (!mounted) return;
      if (path.isEmpty) {
        setState(() {
          _phase = _Phase.idle;
          _status = 'Bundled model is unavailable.';
        });
        return;
      }
      _appendLog('FLM_MODEL_PATH $path');
      await _loadModel(path);
    } catch (error) {
      if (!mounted) return;
      _appendLog('FLM_E2E_FAILURE model-path: $error');
      setState(() {
        _phase = _Phase.idle;
        _status = 'Could not find the bundled model.';
      });
    }
  }

  Future<FoundryLocal> _ensureFoundry() async {
    final existing = _foundry;
    if (existing != null) return existing;
    _appendLog('Initialising FoundryLocal...');
    final foundry = await FoundryLocal.create(
      const FoundryLocalConfig(appName: 'foundry_local_mobile_example'),
    );
    if (!mounted) {
      await foundry.dispose();
      throw StateError('The chat screen was disposed during SDK startup.');
    }
    _foundry = foundry;
    _appendLog('FoundryLocal ready.');
    return foundry;
  }

  Future<void> _loadModel(String path) async {
    await _chatSub?.cancel();
    _chatSub = null;
    _chat?.release();
    _chat = null;
    _model?.dispose();
    _model = null;

    setState(() {
      _phase = _Phase.loading;
      _progress = 0;
      _status = 'Loading $_modelName on device...';
    });

    try {
      final foundry = await _ensureFoundry();
      _appendLog('loadModel(path=$path)');
      final model = await foundry.loadModel(
        path,
        executionProvider: Platform.isIOS ? 'CPU' : null,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _progress = progress.fraction;
            _status =
                'Loading $_modelName - ${progress.percent.toStringAsFixed(0)}%';
          });
        },
      );
      if (!mounted) {
        model.dispose();
        return;
      }
      final info = model.getInfo();
      _model = model;
      _chat = model.createChatSession(
        options: const ChatSessionOptions(
          systemPrompt: 'You are a concise, helpful assistant.',
          temperature: 0.2,
          maxOutputTokens: 512,
          seed: 42,
        ),
      );
      _appendLog(
        'Loaded. path=${model.path} task=${info.task} ep=${info.executionProvider}',
      );
      if (!mounted) return;
      setState(() {
        _phase = _Phase.ready;
        _progress = 1;
        _status = 'On-device - ${info.executionProvider} - Ready';
      });
      _appendLog('FLM_MODEL_READY');
      if (_autoRun) {
        await _sendPrompt(prompt: 'Reply with exactly ON_DEVICE_OK.');
      }
    } catch (error) {
      _appendLog('FLM_E2E_FAILURE model-load: $error');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _status = 'Model failed to load.';
      });
    }
  }

  Future<void> _sendPrompt({String? prompt}) async {
    final chat = _chat;
    final content = (prompt ?? _promptCtrl.text).trim();
    if (chat == null || content.isEmpty || _phase != _Phase.ready) return;

    _composerFocus.unfocus();
    final assistant = _ConversationMessage(
      role: _MessageRole.assistant,
      text: '',
      isThinking: true,
    );
    setState(() {
      _messages
        ..add(_ConversationMessage(role: _MessageRole.user, text: content))
        ..add(assistant);
      _phase = _Phase.chatting;
      _status = 'Generating on device...';
      _receivedTextDelta = false;
      _receivedReasoningDelta = false;
      _promptCtrl.clear();
    });
    _scrollToBottom();

    await _chatSub?.cancel();
    final completer = Completer<void>();
    _chatSub = chat
        .completeStreaming(
      ChatRequest(messages: [ChatMessage.user(content)]),
    )
        .listen(
      (delta) {
        if (!mounted) return;
        if (delta is TextDelta) {
          if (delta.text.isNotEmpty && !_receivedTextDelta) {
            _receivedTextDelta = true;
            _appendLog('FLM_E2E_TEXT_DELTA');
          }
          setState(() {
            assistant
              ..text += delta.text
              ..isThinking = false;
          });
          _scrollToBottom();
        } else if (delta is ReasoningDelta) {
          if (delta.text.isNotEmpty && !_receivedReasoningDelta) {
            _receivedReasoningDelta = true;
            _appendLog('FLM_E2E_REASONING_DELTA');
          }
        } else if (delta is CompletedDelta) {
          _appendLog(
            'FLM_E2E_COMPLETED reason=${delta.finishReason.name} '
            'prompt=${delta.promptTokens} completion=${delta.completionTokens}',
          );
        }
      },
      onError: (Object error) {
        _appendLog('FLM_E2E_FAILURE stream: $error');
        if (mounted) {
          setState(() {
            assistant
              ..isThinking = false
              ..isError = true;
            if (assistant.text.isEmpty) {
              assistant.text = 'The on-device model could not answer.';
            }
            _chatSub = null;
            _phase = _Phase.ready;
            _status = 'On-device - CPU - Ready';
          });
        }
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (mounted) {
          setState(() {
            assistant.isThinking = false;
            if (assistant.text.isEmpty && !assistant.isError) {
              assistant.text = 'The model returned an empty response.';
            }
            _chatSub = null;
            _phase = _Phase.ready;
            _status = 'On-device - CPU - Ready';
          });
          _scrollToBottom();
        }
        if (!completer.isCompleted) completer.complete();
      },
    );
    await completer.future;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        titleSpacing: 16,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        bottom: _phase == _Phase.loading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  value: _progress > 0 && _progress <= 1 ? _progress : null,
                ),
              )
            : null,
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: Color(0xFF10A37F),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Text(
                'Q',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    _modelName,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: _phase == _Phase.idle
                          ? Theme.of(context).colorScheme.error
                          : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Container(
                key: const ValueKey('chat-message-list'),
                color: Colors.white,
                child: _messages.isEmpty
                    ? _buildWelcome(context)
                    : ListView.separated(
                        controller: _chatScroll,
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
                        itemCount: _messages.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 18),
                        itemBuilder: (_, index) =>
                            _buildMessage(context, _messages[index]),
                      ),
              ),
            ),
            _buildComposer(context),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcome(BuildContext context) {
    final ready = _phase == _Phase.ready;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              ready ? Icons.chat_bubble_outline_rounded : Icons.memory_rounded,
              size: 48,
              color: const Color(0xFF10A37F),
            ),
            const SizedBox(height: 18),
            Text(
              ready ? 'How can I help?' : 'Preparing your local AI',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 10),
            Text(
              ready
                  ? 'Messages stay on this iPhone and run through $_modelName.'
                  : 'Loading $_modelName. This usually takes less than a second.',
              textAlign: TextAlign.center,
              style: TextStyle(
                height: 1.4,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessage(
    BuildContext context,
    _ConversationMessage message,
  ) {
    final isUser = message.role == _MessageRole.user;
    return Row(
      mainAxisAlignment:
          isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isUser) ...[
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
              color: Color(0xFF10A37F),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Text(
              'Q',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Flexible(
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            decoration: BoxDecoration(
              color: isUser
                  ? const Color(0xFF10A37F)
                  : message.isError
                      ? Theme.of(context).colorScheme.errorContainer
                      : const Color(0xFFF1F1F2),
              borderRadius: BorderRadius.circular(20).copyWith(
                bottomRight: isUser ? const Radius.circular(5) : null,
                bottomLeft: isUser ? null : const Radius.circular(5),
              ),
            ),
            child: message.isThinking && message.text.isEmpty
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 9),
                      Text(
                        'Thinking...',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ],
                  )
                : SelectableText(
                    message.text,
                    style: TextStyle(
                      height: 1.4,
                      color: isUser ? Colors.white : Colors.black87,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildComposer(BuildContext context) {
    final isGenerating = _phase == _Phase.chatting;
    final canCompose = _phase == _Phase.ready;
    final canSend = canCompose && _promptCtrl.text.trim().isNotEmpty;

    return Container(
      key: const ValueKey('chat-composer'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('chat-input'),
                  controller: _promptCtrl,
                  focusNode: _composerFocus,
                  enabled: canCompose,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (canSend) unawaited(_sendPrompt());
                  },
                  decoration: InputDecoration(
                    hintText:
                        canCompose ? 'Message Qwen3...' : 'Loading model...',
                    filled: true,
                    fillColor: const Color(0xFFF4F4F5),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: const BorderSide(
                        color: Color(0xFF10A37F),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: isGenerating ? 'Generating' : 'Send',
                onPressed: canSend ? _sendPrompt : null,
                icon: isGenerating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Loaded model: $_modelName - Runs locally with CPU',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}
