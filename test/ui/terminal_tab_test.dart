import 'dart:async';
import 'dart:convert';

import 'package:ai_app/core/launch.dart';
import 'package:ai_app/core/pty.dart';
import 'package:ai_app/ui/terminal_tab.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

class FakePty implements PtySession {
  final out = StreamController<Uint8List>();
  final exit = Completer<int>();
  final written = <String>[];
  bool killed = false;

  @override
  Stream<Uint8List> get output => out.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  void write(Uint8List data) => written.add(utf8.decode(data));
  @override
  void resize(int rows, int cols) {}
  @override
  void kill() => killed = true;
}

const spec = LaunchSpec(executable: '/bin/pi', args: [], env: {}, cwd: '/w');

void main() {
  late FakePty pty;

  final zooms = <int>[];
  final opened = <String>[];

  Future<Terminal> pump(WidgetTester tester) async {
    pty = FakePty();
    zooms.clear();
    opened.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTab(
            spec: spec,
            start: (_) => pty,
            title: 'Pi · ALCF',
            onZoom: zooms.add,
            openUrl: opened.add,
          ),
        ),
      ),
    );
    return tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
  }

  testWidgets('terminal tab shows exit code', (tester) async {
    final term = await pump(tester);
    pty.out.add(Uint8List.fromList(utf8.encode('hello')));
    await tester.pump();
    pty.exit.complete(3);
    await tester.pump();
    final text = term.buffer.getText();
    expect(text, contains('hello'));
    expect(text, contains('[process exited with code 3]'));
  });

  testWidgets('typing is forwarded', (tester) async {
    final term = await pump(tester);
    term.textInput('x');
    expect(pty.written, ['x']);
  });

  testWidgets('dispose kills the process', (tester) async {
    await pump(tester);
    await tester.pumpWidget(const SizedBox());
    expect(pty.killed, isTrue);
  });

  Future<void> chord(
    WidgetTester t,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(key);
    if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
  }

  Future<void> write(WidgetTester t, String text) async {
    pty.out.add(Uint8List.fromList(utf8.encode(text)));
    await t.pump();
  }

  testWidgets('ctrl+shift+A then ctrl+shift+C copies, ctrl+shift+V pastes', (
    tester,
  ) async {
    String? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clip = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': 'pasted'};
        return null;
      },
    );
    await pump(tester);
    await write(tester, 'copy\x1b[1Cme');
    await chord(tester, LogicalKeyboardKey.keyA, shift: true);
    await chord(tester, LogicalKeyboardKey.keyC, shift: true);
    expect(clip, contains('copy me'));
    expect(clip, isNot(contains('copyme')));
    await chord(tester, LogicalKeyboardKey.keyV, shift: true);
    expect(pty.written.join(), contains('pasted'));
  });

  testWidgets('ctrl+A goes to the agent, not select-all', (tester) async {
    await pump(tester);
    await chord(tester, LogicalKeyboardKey.keyA);
    expect(pty.written, ['\x01']);
  });

  testWidgets('ctrl+= / ctrl+- / ctrl+0 zoom', (tester) async {
    await pump(tester);
    await chord(tester, LogicalKeyboardKey.equal);
    await chord(tester, LogicalKeyboardKey.minus);
    await chord(tester, LogicalKeyboardKey.digit0);
    expect(zooms, [1, -1, 0]);
    expect(pty.written, isEmpty);
  });

  testWidgets('ctrl+shift+F searches the scrollback', (tester) async {
    await pump(tester);
    await write(tester, 'alpha\r\nbeta one\r\nbeta two\r\n');
    await chord(tester, LogicalKeyboardKey.keyF, shift: true);
    expect(find.byKey(const ValueKey('find-field')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('find-field')), 'beta');
    await tester.pump();
    expect(find.text('2 of 2'), findsOneWidget);
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(view.controller!.highlights.length, 1);
    await tester.tap(find.byKey(const ValueKey('find-prev')));
    await tester.pump();
    expect(find.text('1 of 2'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('find-field')), 'zzz');
    await tester.pump();
    expect(find.text('No matches'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('find-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey('find-field')), findsNothing);
    expect(view.controller!.highlights, isEmpty);
  });

  testWidgets('ctrl+click on a URL opens it', (tester) async {
    await pump(tester);
    await write(tester, 'docs: https://docs.alcf.anl.gov/x ok');
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    view.onTapUp!(
      TapUpDetails(kind: PointerDeviceKind.mouse),
      const CellOffset(12, 0),
    );
    expect(opened, isEmpty, reason: 'plain click does nothing');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    view.onTapUp!(
      TapUpDetails(kind: PointerDeviceKind.mouse),
      const CellOffset(12, 0),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(opened, ['https://docs.alcf.anl.gov/x']);
  });
}
