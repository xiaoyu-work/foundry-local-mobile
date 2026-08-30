// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

class AssistantTextBuffer {
  final StringBuffer _text = StringBuffer();
  String _pendingPrefix = '';
  bool _started = false;

  String get text => _text.toString();

  void append(String fragment) {
    if (fragment.isEmpty) return;
    if (_started) {
      _text.write(fragment);
      return;
    }

    _pendingPrefix += fragment;
    final firstVisible = RegExp(r'\S').firstMatch(_pendingPrefix);
    if (firstVisible == null) return;

    final leadingWhitespace = _pendingPrefix.substring(0, firstVisible.start);
    final lastLineFeed = leadingWhitespace.lastIndexOf('\n');
    final lastCarriageReturn = leadingWhitespace.lastIndexOf('\r');
    final lastLineBreak =
        lastLineFeed > lastCarriageReturn ? lastLineFeed : lastCarriageReturn;
    if (lastLineBreak >= 0) {
      _text.write(_pendingPrefix.substring(lastLineBreak + 1));
    } else {
      _text.write(_pendingPrefix);
    }
    _pendingPrefix = '';
    _started = true;
  }
}
