import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_app/app/app_state.dart';
import 'package:ai_app/core/app_store.dart';
import 'package:ai_app/core/hosts.dart';
import 'package:ai_app/core/host_client.dart';
import 'package:ai_app/core/launch.dart';
import 'package:ai_app/core/profiles.dart';
import 'package:ai_app/core/runner.dart';
import 'package:ai_app/core/sandbox.dart';
import 'package:ai_app/core/tunnel.dart';
import 'package:ai_app/ui/home_page.dart';
import 'package:ai_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_runner.dart';
import 'terminal_tab_test.dart' show FakePty;

const local = ModelHost(
  id: 'local',
  label: 'This machine',
  kind: HostKind.local,
);
const pc = ModelHost(
  id: 'pc',
  label: 'PC',
  kind: HostKind.ssh,
  sshTarget: 'pc',
  localPort: 19931,
);

Map<String, dynamic> status(
  String state, {
  int ctx = 32768,
  String label = 'Qwen3.6 35B-A3B · 32K',
  String? error,
  Object? gpu = const {
    'name': 'RTX 3060',
    'used_mib': 10035,
    'total_mib': 12288,
  },
}) => {
  'schema': 1,
  'host': 'pc',
  'state': state,
  'recipe': state == 'foreign' || state == 'stopped' ? null : 'qwen36-35b-32k',
  'label': state == 'foreign' || state == 'stopped' ? null : label,
  'alias': state == 'foreign' || state == 'stopped' ? null : 'qwen36-35b-32k',
  'ctx': state == 'ready' ? ctx : null,
  'max_output': 4096,
  'vision': false,
  'port': 9931,
  'pid': state == 'ready' ? 42 : null,
  'started': null,
  'gpu': gpu,
  'error': error,
};

const recipes = {
  'schema': 1,
  'recipes': [
    {
      'name': 'qwen36-35b-32k',
      'label': 'Qwen3.6 35B-A3B · 32K',
      'model': 'q.gguf',
      'ctx': 32768,
      'max_output': 4096,
      'vision': false,
      'notes': '',
      'model_present': true,
    },
    {
      'name': 'gone-64k',
      'label': 'Gone · 64K',
      'model': 'g.gguf',
      'ctx': 65536,
      'max_output': 4096,
      'vision': false,
      'notes': '',
      'model_present': false,
    },
  ],
  'invalid': [],
};

/// An ssh forward whose local port is taken.
class _PortTakenProc implements Proc {
  final _exit = Completer<int>();
  final _err = StreamController<String>.broadcast();
  _PortTakenProc() {
    Future<void>.delayed(Duration.zero, () {
      _err.add('bind [127.0.0.1]:19931: Address already in use');
      _exit.complete(255);
    });
  }
  @override
  Future<int> get exitCode => _exit.future;
  @override
  Stream<String> get stderrLines => _err.stream;
  @override
  void kill() {}
}

class _NeverProc implements Proc {
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  Stream<String> get stderrLines => const Stream.empty();
  @override
  void kill() {}
}

void main() {
  late Directory tmp;
  late String realHome;
  late FakeRunner runner;
  late List<LaunchSpec> started;
  late Map<String, dynamic> current;

  AppState makeState({
    List<ModelHost> hosts = const [local, pc],
    TunnelManager? tunnels,
    AppStore? store,
  }) {
    runner = FakeRunner({
      'llm-host status': (_) => RunResult(0, jsonEncode(current), ''),
      'llm-host list': (_) => RunResult(0, jsonEncode(recipes), ''),
      'llm-host log': (_) =>
          const RunResult(0, 'cudaMalloc failed\nexiting\n', ''),
      'llm-host stop': (_) {
        current = status('stopped');
        return RunResult(0, jsonEncode(current), '');
      },
      'llm-host start': (c) {
        current = status('ready');
        return RunResult(0, jsonEncode(current), '');
      },
      '/usr/bin/ssh': (_) => const RunResult(
        255,
        '',
        'ssh: connect to host pc port 22: No route to host',
      ),
    });
    started = [];
    final sb = Sandbox(
      root: '$realHome/.local/share/alcfai/home',
      realHome: realHome,
    );
    return AppState(
      profiles: defaultProfiles(realHome, accounts: const []),
      which: (exe) => '/bin/$exe',
      sandbox: sb,
      alcf: null,
      start: (spec) {
        started.add(spec);
        return FakePty();
      },
      parentEnv: {'HOME': realHome, 'PATH': '/bin'},
      defaultCwd: tmp.path,
      store: store ?? AppStore('${tmp.path}/state.json'),
      hosts: hosts,
      hostClient: HostClient(
        runner: runner,
        sshExe: '/usr/bin/ssh',
        controlDir: '/c',
      ),
      tunnels:
          tunnels ??
          TunnelManager(
            start: (_, _) async => _NeverProc(),
            probe: (_) async => true,
            sshExe: '/usr/bin/ssh',
          ),
      dataRoot: '$realHome/.local/share/ai-app',
      guardedRoots: [
        '$realHome/.claude',
        '$realHome/.pi',
        '$realHome/.config/opencode',
      ],
    );
  }

  Future<AppState> pump(WidgetTester tester, AppState state) async {
    await tester.binding.setSurfaceSize(const Size(1280, 2400));
    await tester.runAsync(() async {
      await state.refresh();
      for (final h in state.hosts) {
        await state.refreshHost(h.id);
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: HomePage(state: state),
      ),
    );
    await tester.pump();
    return state;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aiapp_hosttile_');
    realHome = '${tmp.path}/home';
    Directory(realHome).createSync(recursive: true);
    current = status('ready');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  IconButton button(WidgetTester t, String key) =>
      t.widget<IconButton>(find.byKey(ValueKey(key)));

  testWidgets('ready host shows model, context and VRAM', (tester) async {
    await pump(tester, makeState(hosts: const [local]));
    expect(find.text('This machine'), findsOneWidget);
    expect(find.text('Qwen3.6 35B-A3B · 32K'), findsOneWidget);
    expect(find.text('32K window · VRAM 9.8 / 12.0 GB'), findsOneWidget);
    expect(find.text('Pi · This machine'), findsOneWidget);
    expect(find.text('OpenCode · This machine'), findsOneWidget);
    expect(find.text('Claude · This machine'), findsOneWidget);
  });

  testWidgets('without gpu the window shows alone', (tester) async {
    current = status('ready', gpu: null);
    await pump(tester, makeState(hosts: const [local]));
    expect(find.text('32K window'), findsOneWidget);
  });

  testWidgets(
    'unreachable host greys its three profiles and shows the reason',
    (tester) async {
      await pump(tester, makeState());
      expect(
        find.text('ssh: connect to host pc port 22: No route to host'),
        findsOneWidget,
      );
      for (final a in ['pi', 'opencode', 'claude']) {
        expect(button(tester, 'open-$a-pc').onPressed, isNull, reason: a);
      }
      expect(find.text('PC is unreachable'), findsNWidgets(3));
      expect(button(tester, 'open-pi-local').onPressed, isNotNull);
    },
  );

  testWidgets('stopped host offers Start with the recipe list', (tester) async {
    current = status('stopped');
    final state = await pump(tester, makeState(hosts: const [local]));
    expect(
      find.text('No model is running on This machine: start one'),
      findsNWidgets(4),
    );
    await tester.tap(find.byKey(const ValueKey('host-menu-local')));
    await tester.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
    await tester.tap(find.text('Qwen3.6 35B-A3B · 32K').last);
    await tester.pump();
    await tester.runAsync(() => state.saving);
    await tester.pumpAndSettle();
    expect(runner.calls.where((c) => c.args.first == 'start').single.args, [
      'start',
      'qwen36-35b-32k',
      '--json',
    ]);
  });

  testWidgets('recipe with a missing model file is disabled', (tester) async {
    current = status('stopped');
    await pump(tester, makeState(hosts: const [local]));
    await tester.tap(find.byKey(const ValueKey('host-menu-local')));
    await tester.pumpAndSettle();
    final item = tester.widget<PopupMenuItem<String>>(
      find.byKey(const ValueKey('recipe-gone-64k')),
    );
    expect(item.enabled, isFalse);
    expect(
      find.byTooltip('model file missing on This machine'),
      findsOneWidget,
    );
  });

  testWidgets('switching with open tabs asks first', (tester) async {
    final state = await pump(tester, makeState(hosts: const [local]));
    await tester.runAsync(() async {
      final p = state.profiles.firstWhere((p) => p.id == 'pi-local');
      await state.openLocal(p, tmp.path);
      await state.openLocal(p, tmp.path);
    });
    await tester.pump();
    expect(state.openTabsOn('local'), 2);
    await tester.tap(find.byKey(const ValueKey('host-menu-local')));
    await tester.pumpAndSettle();
    expect(find.text('Switch model'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recipe-qwen36-35b-32k')));
    await tester.pumpAndSettle();
    expect(
      find.text('2 open tabs use This machine. They will lose their model.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(runner.calls.where((c) => c.args.first == 'start'), isEmpty);
  });

  testWidgets('start failure shows the log tail', (tester) async {
    current = status('stopped');
    final state = makeState(hosts: const [local]);
    runner.handlers['llm-host start'] = (_) => RunResult(
      3,
      jsonEncode(status('error', error: 'cudaMalloc failed: out of memory')),
      '',
    );
    await pump(tester, state);
    await tester.tap(find.byKey(const ValueKey('host-menu-local')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recipe-qwen36-35b-32k')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('cudaMalloc failed: out of memory'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('foreign server disables Stop and the menu', (tester) async {
    current = status(
      'foreign',
      error: 'a llama-server not started by llm-host is using port 9931',
    );
    await pump(tester, makeState(hosts: const [local]));
    expect(button(tester, 'host-stop-local').onPressed, isNull);
    expect(
      tester
          .widget<PopupMenuButton<String>>(
            find.byKey(const ValueKey('host-menu-local')),
          )
          .enabled,
      isFalse,
    );
    expect(
      find.text(
        'A llama-server not started by AI App is running on This machine',
      ),
      findsWidgets,
    );
  });

  testWidgets('Stop calls llm-host stop', (tester) async {
    final state = await pump(tester, makeState(hosts: const [local]));
    await tester.tap(find.byKey(const ValueKey('host-stop-local')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(runner.calls.where((c) => c.args.first == 'stop'), hasLength(1));
    expect(state.statusOfHost('local')!.state, ServerState.stopped);
  });

  testWidgets('Log opens the tail', (tester) async {
    await pump(tester, makeState(hosts: const [local]));
    await tester.tap(find.byKey(const ValueKey('host-log-local')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('cudaMalloc failed'), findsOneWidget);
  });

  testWidgets(
    'a blocked profile shows its reason as a tooltip and does not open a tab',
    (tester) async {
      current = status('stopped');
      final state = await pump(tester, makeState(hosts: const [local]));
      expect(
        find.byTooltip('No model is running on This machine: start one'),
        findsWidgets,
      );
      expect(button(tester, 'open-pi-local').onPressed, isNull);
      final p = state.profiles.firstWhere((p) => p.id == 'pi-local');
      String? err;
      await tester.runAsync(
        () async => err = await state.openLocal(p, tmp.path),
      );
      expect(err, 'No model is running on This machine: start one');
      expect(state.tabs, isEmpty);
    },
  );

  testWidgets('a ready profile opens a tab titled after it', (tester) async {
    final state = await pump(tester, makeState(hosts: const [local]));
    // The button opens the folder dialog for this profile.
    await tester.tap(find.byKey(const ValueKey('open-pi-local')));
    await tester.pumpAndSettle();
    expect(find.text('New Pi · This machine session'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Opening writes real files: run it outside the fake clock.
    final p = state.profiles.firstWhere((p) => p.id == 'pi-local');
    String? err;
    await tester.runAsync(() async => err = await state.openLocal(p, tmp.path));
    await tester.pumpAndSettle();
    expect(err, isNull);
    expect(state.tabs.single.title, 'Pi · This machine');
    expect(
      started.single.env['PI_CODING_AGENT_DIR'],
      '$realHome/.local/share/ai-app/local/local/pi',
    );
    expect(
      find.textContaining('This machine, model qwen36-35b-32k'),
      findsWidgets,
    );
  });

  testWidgets('Claude profile is blocked at a 24576 window while Pi is not', (
    tester,
  ) async {
    current = status('ready', ctx: 24576, label: 'Small · 24K');
    await pump(tester, makeState(hosts: const [local]));
    expect(button(tester, 'open-pi-local').onPressed, isNotNull);
    expect(button(tester, 'open-opencode-local').onPressed, isNotNull);
    expect(button(tester, 'open-claude-local').onPressed, isNull);
    expect(
      find.text(
        'Claude Code needs a 32768-token window; Small · 24K has 24576',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'a forward that cannot open blocks the remote profiles and says why',
    (tester) async {
      final state = makeState(
        tunnels: TunnelManager(
          start: (_, _) async => _PortTakenProc(),
          probe: (_) async => false,
          sshExe: '/usr/bin/ssh',
          probeEvery: Duration.zero,
        ),
      );
      // The host answers over the control connection: only the forward fails.
      runner.handlers['/usr/bin/ssh'] = (_) =>
          RunResult(0, jsonEncode(status('ready')), '');
      await pump(tester, state);
      const why =
          'The tunnel to PC is not open: port 19931 is already in use on this machine';
      expect(find.text(why), findsNWidgets(3));
      expect(button(tester, 'open-pi-pc').onPressed, isNull);
      expect(
        find.text('Tunnel: port 19931 is already in use on this machine'),
        findsOneWidget,
      );
      expect(button(tester, 'open-pi-local').onPressed, isNotNull);
    },
  );

  testWidgets('a local tab that cannot restart says why', (tester) async {
    final state = await pump(tester, makeState(hosts: const [local]));
    final p = state.profiles.firstWhere((p) => p.id == 'pi-local');
    await tester.runAsync(() => state.openLocal(p, tmp.path));
    await tester.pump();
    current = status('stopped');
    await tester.runAsync(() => state.restart(0));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('No model is running on This machine: start one'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('reopenLast reports a local tab that cannot open', (
    tester,
  ) async {
    current = status('stopped');
    final store = AppStore('${tmp.path}/state.json');
    store.lastTabs = [SavedTab('pi-local', tmp.path)];
    final state = makeState(hosts: const [local], store: store);
    await pump(tester, state);
    expect(state.canReopen, 1);
    await tester.runAsync(() async {
      state.reopenLast();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump();
    expect(state.tabs, isEmpty);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('No model is running on This machine: start one'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('openLocal turns a file error into a sentence', (tester) async {
    final state = await pump(tester, makeState(hosts: const [local]));
    // The data folder is a file: writing the config fails.
    File('$realHome/.local/share/ai-app').createSync(recursive: true);
    final p = state.profiles.firstWhere((p) => p.id == 'pi-local');
    String? err;
    await tester.runAsync(() async => err = await state.openLocal(p, tmp.path));
    expect(err, startsWith('Could not write the agent config'));
    expect(state.tabs, isEmpty);
  });

  testWidgets('Probe shows each check', (tester) async {
    final state = makeState(hosts: const [local]);
    runner.handlers['llm-host probe'] = (_) => RunResult(
      0,
      jsonEncode({
        'schema': 1,
        'ok': true,
        'checks': [
          {
            'name': 'tool_call',
            'ok': true,
            'detail': 'get_weather({"city": "Paris"})',
          },
          {'name': 'generation', 'ok': true, 'detail': '38.2 tok/s'},
        ],
        'error': null,
      }),
      '',
    );
    await pump(tester, state);
    await tester.tap(find.byKey(const ValueKey('host-probe-local')));
    await tester.pumpAndSettle();
    expect(find.textContaining('PASS  tool_call'), findsOneWidget);
    expect(find.textContaining('38.2 tok/s'), findsOneWidget);
  });

  testWidgets('existing ALCF and account sections are still there', (
    tester,
  ) async {
    await pump(tester, makeState(hosts: const [local]));
    expect(find.text('ALCF inference'), findsOneWidget);
    expect(find.text('Claude · ALCF'), findsOneWidget);
    expect(find.text('Model hosts'), findsOneWidget);
  });
}
