import 'dart:convert';
import 'dart:io';

import 'package:ai_app/app/app_state.dart';
import 'package:ai_app/core/alcf_cli.dart';
import 'package:ai_app/core/app_store.dart';
import 'package:ai_app/core/guard.dart';
import 'package:ai_app/core/profiles.dart';
import 'package:ai_app/core/runner.dart';
import 'package:ai_app/core/sandbox.dart';
import 'package:ai_app/ui/configure_dialog.dart';
import 'package:ai_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_runner.dart';
import 'terminal_tab_test.dart' show FakePty;

const lsModels = '''
[
  {"id": "gpt-oss-120b", "display_name": "GPT-OSS 120B",
   "capabilities": {"api_protocols": ["chat_completions", "messages"]}},
  {"id": "inkling-bf16", "display_name": "Inkling",
   "capabilities": {"api_protocols": ["chat_completions", "messages"]}},
  {"id": "chat-only", "display_name": "Chat only",
   "capabilities": {"api_protocols": ["chat_completions"]}}
]
''';

const lsJobs =
    "{'running': [{'Models': 'gpt-oss-120b'}], 'queued': [{'Models': 'inkling-bf16'}]}";

void main() {
  late Directory tmp;
  late String realHome;
  late Sandbox sb;
  late FakeRunner runner;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aiapp_cfg_');
    realHome = '${tmp.path}/home';
    Directory('$realHome/.globus').createSync(recursive: true);
    Directory('$realHome/.claude/plugins').createSync(recursive: true);
    File('$realHome/.claude/settings.json').writeAsStringSync('{}');
    sb = Sandbox(
      root: '$realHome/.local/share/alcfai/home',
      realHome: realHome,
    );
    runner = FakeRunner({
      '/bin/alcf-ai ls-models': (_) => const RunResult(0, lsModels, ''),
      '/bin/alcf-ai ls-jobs': (_) => const RunResult(0, lsJobs, ''),
    });
    state = AppState(
      profiles: defaultProfiles(realHome),
      which: (exe) => '/bin/$exe',
      sandbox: sb,
      alcf: AlcfCli(
        runner: runner,
        sandbox: sb,
        guard: RealConfigGuard(['$realHome/.claude/settings.json']),
        alcfExe: '/bin/alcf-ai',
        tokensExe: '/bin/alcf-tokens',
        uvCacheDir: '/uv',
        sharedSettingsPath: '$realHome/shared.json',
        parentEnv: {'HOME': realHome, 'PATH': '/bin'},
      ),
      start: (_) => FakePty(),
      parentEnv: {'HOME': realHome, 'PATH': '/bin'},
      defaultCwd: tmp.path,
      store: AppStore('${tmp.path}/state.json'),
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Profile profile(String id) => state.profiles.firstWhere((p) => p.id == id);

  /// Real file IO completes on the real event loop; alternate with pumps.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  Future<void> openDialog(WidgetTester tester, String id) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.runAsync(state.refresh);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showConfigureDialog(context, state, profile(id)),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await settle(tester);
  }

  Future<void> pressConfigure(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('configure-submit')));
    await settle(tester);
  }

  Iterable<Call> configureCalls() =>
      runner.calls.where((c) => c.args.take(2).join(' ') == 'agent configure');

  testWidgets('cluster dropdown offers kClusters, default tara, no metis', (
    tester,
  ) async {
    await openDialog(tester, 'pi-alcf');
    expect(find.text('tara'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cluster-dropdown')));
    await tester.pumpAndSettle();
    for (final c in kClusters) {
      expect(find.text(c), findsWidgets, reason: c);
    }
    expect(find.text('metis'), findsNothing);
  });

  testWidgets('model dropdown is filled from listModels(forAgent)', (
    tester,
  ) async {
    await openDialog(tester, 'claude-alcf');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('model-dropdown')),
        matching: find.text('inkling-bf16'),
      ),
      findsOneWidget,
    );
    expect(find.text('queued'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('model-dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('gpt-oss-120b'), findsWidgets);
    expect(find.text('running'), findsWidgets);
    expect(find.text('chat-only'), findsNothing);
  });

  testWidgets('experimental checkbox is passed to configure', (tester) async {
    await openDialog(tester, 'pi-alcf');
    await tester.tap(find.byKey(const ValueKey('experimental-box')));
    await tester.pump();
    await pressConfigure(tester);
    expect(configureCalls().single.args, contains('--include-experimental'));
  });

  testWidgets('plugins checkbox shows only for Claude, unchecked', (
    tester,
  ) async {
    const label = 'Include plugins & hooks (uses much more context)';
    await openDialog(tester, 'pi-alcf');
    expect(find.text(label), findsNothing);
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();

    await openDialog(tester, 'claude-alcf');
    expect(find.text(label), findsOneWidget);
    final box = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('plugins-box')),
    );
    expect(box.value, isFalse);
    await tester.tap(find.text(label));
    await tester.pump();
    await pressConfigure(tester);
    expect(FileSystemEntity.isLinkSync('${sb.claudeDir}/plugins'), isTrue);
  });

  testWidgets('Claude: one dropdown per /model alias, written on configure', (
    tester,
  ) async {
    await openDialog(tester, 'pi-alcf');
    expect(find.byKey(const ValueKey('slot-opus')), findsNothing);
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();

    await openDialog(tester, 'claude-alcf');
    for (final s in ['opus', 'sonnet', 'haiku']) {
      expect(find.byKey(ValueKey('slot-$s')), findsOneWidget, reason: s);
    }
    await tester.tap(find.byKey(const ValueKey('slot-haiku')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('gpt-oss-120b').last);
    await tester.pumpAndSettle();
    await pressConfigure(tester);
    await settle(tester);

    final env =
        (jsonDecode(File('${sb.claudeDir}/settings.json').readAsStringSync())
                as Map)['env']
            as Map;
    expect(env['ANTHROPIC_DEFAULT_OPUS_MODEL'], 'inkling-bf16');
    expect(env['ANTHROPIC_DEFAULT_HAIKU_MODEL'], 'gpt-oss-120b');
    expect(env['ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME'], 'GPT-OSS 120B');
  });

  testWidgets('Ok closes the dialog and refreshes', (tester) async {
    await openDialog(tester, 'pi-alcf');
    runner.handlers['/bin/alcf-ai agent configure'] = (_) {
      File('${sb.home}/.pi/agent/models.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('alcf-inference-service-x');
      return const RunResult(0, '', '');
    };
    await pressConfigure(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(state.statusOf(profile('pi-alcf')).configured, isTrue);
  });

  testWidgets('LoginNeeded shows a Log in button', (tester) async {
    runner.handlers['/bin/alcf-tokens get-token'] = (_) =>
        const RunResult(1, '', '');
    await openDialog(tester, 'pi-alcf');
    await pressConfigure(tester);
    expect(
      find.text('ALCF login needed. Log in, then configure again.'),
      findsOneWidget,
    );
    expect(find.text('Log in'), findsOneWidget);
  });

  testWidgets('Failed shows explainError text', (tester) async {
    runner.handlers['/bin/alcf-ai agent configure'] = (_) =>
        const RunResult(1, '', 'HTTP 429 Too Many Requests');
    await openDialog(tester, 'pi-alcf');
    await pressConfigure(tester);
    expect(find.text('ALCF rate limit, wait and retry.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('RealConfigTouched lists the paths in red', (tester) async {
    runner.handlers['/bin/alcf-ai agent configure'] = (_) {
      File('$realHome/.claude/settings.json').writeAsStringSync('{"x": 1}');
      return const RunResult(0, '', '');
    };
    await openDialog(tester, 'pi-alcf');
    await pressConfigure(tester);
    final path = find.text('$realHome/.claude/settings.json');
    expect(path, findsOneWidget);
    expect(tester.widget<Text>(path).style?.color, Tok.danger);
    expect(
      find.textContaining('a .bak.* copy sits next to it: restore it'),
      findsOneWidget,
    );
  });

  testWidgets('Ok remembers the choice; reopening starts from it', (
    tester,
  ) async {
    final generic = runner.handlers.remove('/bin/alcf-ai ls-models')!;
    runner.handlers['/bin/alcf-ai ls-models sophia'] = (_) => const RunResult(
      0,
      '[{"id": "openai/gpt-oss-120b", "capabilities": {"api_protocols": ["chat_completions"]}}]',
      '',
    );
    runner.handlers['/bin/alcf-ai ls-models'] = generic;
    await openDialog(tester, 'pi-alcf');
    await tester.tap(find.byKey(const ValueKey('cluster-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sophia').last);
    await settle(tester);
    await pressConfigure(tester);
    await tester.pumpAndSettle();
    expect(
      state.store.choices['pi-alcf'],
      const AgentChoice('sophia', 'openai/gpt-oss-120b'),
    );

    await openDialog(tester, 'pi-alcf');
    expect(find.text('sophia'), findsOneWidget);
    expect(find.text('openai/gpt-oss-120b'), findsOneWidget);
  });
}
