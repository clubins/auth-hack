import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [child] inside a MaterialApp — the minimal host for screens that
/// reach for ScaffoldMessenger or Navigator.
Future<void> pumpScreen(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: child));
}

/// Installs a process-local mock clipboard and returns a getter for the
/// last stored text (null when nothing was copied). Scoped per test: call
/// [resetMockClipboard] between tests if a file needs a clean slate.
String? _clipboardText;

void installMockClipboard() {
  _clipboardText = null;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      _clipboardText = call.arguments['text'] as String?;
      return null;
    }
    if (call.method == 'Clipboard.getData') {
      return {'text': _clipboardText};
    }
    return null;
  });
}

String? get clipboardText => _clipboardText;
