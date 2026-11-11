import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_app/app/app_state.dart';
import 'package:ai_app/core/app_store.dart';
import 'package:ai_app/core/host_client.dart';
import 'package:ai_app/core/hosts.dart';
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

Map<String, dynamic> status(String state) => {
  'schema': 1,
  'host': 'x',
  'state': state,
  'recipe': state == 'ready' ? 'q-64k' : null,
  'label': state == 'ready' ? 'Q · 64K' : null,
  'alias': state == 'ready' ? 'q-64k' : null,
  'ctx': state == 'ready' ? 65536 : null,
  'max_output': 8192,
  'vision': false,
  'port': 9931,
  'pid': null,
  'started': null,
  'gpu': null,
  'error': null,
};

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
  late HostRegistry registry;
  late String sshAnswer;

  AppState makeState(List<ModelHost> hosts) {
    sshAnswer = 'ready';
    runner = FakeRunner({
      'llm-host status': (_) => RunResult(0, jsonEncode(status('ready')), ''),
      'llm-host list': (_) => RunResult(
        0,
        jsonEncode({'schema': 1, 'recipes': [], 'invalid': []}),
        '',
      ),
      '/usr/bin/ssh': (c) => switch (sshAnswer) {
        'down' => const RunResult(
          255,
          '',
          'ssh: Could not resolve hostname mini',
        ),
        final st => RunResult(0, jsonEncode(status(st)), ''),
      },
    });
    registry = HostRegistry('${tmp.path}/cfg/hosts.json');
    return AppState(
      profiles: defaultProfiles(realHome, accounts: const []),
      which: (exe) => '/bin/$exe',
      sandbox: Sandbox(
        root: '$realHome/.local/share/alcfai/home',
        realHome: realHome,
      ),
      alcf: null,
      start: (_) => FakePty(),
      parentEnv: {'HOME': realHome, 'PATH': '/bin'},
      defaultCwd: tmp.path,
      store: AppStore('${tmp.path}/state.json'),
      hosts: hosts,
      registry: registry,
      hostClient: HostClient(
        runner: runner,
        sshExe: '/usr/bin/ssh',
        controlDir: '/c',
      ),
      tunnels: TunnelManager(
        start: (_, _) async => _NeverProc(),
        probe: (_) async => true,
        sshExe: '/usr/bin/ssh',
      ),
      dataRoot: '$realHome/.local/share/ai-app',
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

  Future<void> openAdd(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('add-host')));
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(ValueKey(key)), text);
    await tester.pump();
  }

  FilledButton save(WidgetTester t) =>
      t.widget<FilledButton>(find.byKey(const ValueKey('host-save')));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aiapp_hostdlg_');
    realHome = '${tmp.path}/home';
    Directory(realHome).createSync(recursive: true);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('SSH fields appear only for Over SSH', (tester) async {
    await pump(tester, makeState([local]));
    await openAdd(tester);
    expect(find.byKey(const ValueKey('host-target')), findsNothing);
    expect(find.byKey(const ValueKey('host-local-port')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('kind-ssh')));
    await tester.pump();
    expect(find.byKey(const ValueKey('host-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-local-port')), findsOneWidget);
  });

  testWidgets('local port is prefilled with the next free port', (
    tester,
  ) async {
    await pump(tester, makeState([local, pc]));
    await openAdd(tester);
    await tester.tap(find.byKey(const ValueKey('kind-ssh')));
    await tester.pump();
    final f = tester.widget<TextField>(
      find.byKey(const ValueKey('host-local-port')),
    );
    expect(f.controller!.text, '19932');
  });

  testWidgets('Save is disabled and the problem is listed', (tester) async {
    await pump(tester, makeState([local, pc]));
    await openAdd(tester);
    await tester.tap(find.byKey(const ValueKey('kind-ssh')));
    await tester.pump();
    await enter(tester, 'host-label', 'PC');
    await enter(tester, 'host-target', 'other');
    expect(save(tester).onPressed, isNull);
    expect(
      find.text('A host with the id "pc" already exists.'),
      findsOneWidget,
    );

    await enter(tester, 'host-label', 'Mini PC');
    await enter(tester, 'host-target', '');
    expect(save(tester).onPressed, isNull);
    expect(find.textContaining('Enter the SSH target'), findsOneWidget);

    await enter(tester, 'host-target', '-oProxyCommand=evil');
    expect(save(tester).onPressed, isNull);
    expect(
      find.textContaining('cannot contain spaces or start with "-"'),
      findsOneWidget,
    );

    await enter(tester, 'host-target', 'me@mini');
    expect(save(tester).onPressed, isNotNull);
  });

  testWidgets('Test is disabled while problems are listed', (tester) async {
    await pump(tester, makeState([local]));
    await openAdd(tester);
    await tester.tap(find.byKey(const ValueKey('kind-ssh')));
    await tester.pump();
    await enter(tester, 'host-label', 'Mini');
    final test = find.byKey(const ValueKey('host-test'));
    expect(tester.widget<OutlinedButton>(test).onPressed, isNull);
    await enter(tester, 'host-target', 'me@mini');
    expect(tester.widget<OutlinedButton>(test).onPressed, isNotNull);
  });

  testWidgets('a new ssh host defaults to ~/.local/bin/llm-host', (
    tester,
  ) async {
    await pump(tester, makeState([local]));
    await openAdd(tester);
    final cmd = find.byKey(const ValueKey('host-cmd'));
    expect(tester.widget<TextField>(cmd).controller!.text, 'llm-host');
    await tester.tap(find.byKey(const ValueKey('kind-ssh')));
    await tester.pump();
    expect(
      tester.widget<TextField>(cmd).controller!.text,
      '~/.local/bin/llm-host',
    );
  });

  testWidgets('testHost uses its own tunnel and reports the forward', (
    tester,
  ) async {
    final state = await pump(tester, makeState([local, pc]));
    late String r;
    await tester.runAsync(() async {
      // An edited copy of pc with another target: the live pc tunnel is untouched.
      r = await state.testHost(pc.copyWith(sshTarget: 'other'));
    });
    expect(r, 'ready: Q · 64K');
    expect(state.tunnelOf('pc').phase, TunnelPhase.up);
    expect(state.tunnels!.stateOf('pc').error, isNull);
  });

  testWidgets('Test shows the one-line result', (tester) async {
    final state = await pump(tester, makeState([local]));
    Future<String> testWith(String answer) async {
      sshAnswer = answer;
      late String r;
      await tester.runAsync(() async {
        r = await state.testHost(
          const ModelHost(
            id: 'mini',
            label: 'Mini',
            kind: HostKind.ssh,
            sshTarget: 'mini',
            localPort: 19932,
          ),
        );
      });
      return r;
    }

    expect(await testWith('ready'), 'ready: Q · 64K');
    expect(await testWith('stopped'), 'reachable, no model running');
    expect(await testWith('down'), 'ssh: Could not resolve hostname mini');

    // and the button shows it (once the form has no problems)
    await openAdd(tester);
    await enter(tester, 'host-label', 'Mini');
    // "This machine" already serves on 9931: a second local host needs its own
    expect(
      find.text('Port 9931 is already used by another host on this machine.'),
      findsOneWidget,
    );
    await enter(tester, 'host-server-port', '9932');
    await tester.tap(find.byKey(const ValueKey('host-test')));
    await tester.pumpAndSettle();
    expect(find.text('ready: Q · 64K'), findsOneWidget);
  });

  testWidgets('saving a new host adds its section with three profiles', (
    tester,
  ) async {
    final state = await pump(tester, makeState([local]));
    await openAdd(tester);
    await tester.tap(find.byKey(const ValueKey('kind-ssh')));
    await tester.pump();
    await enter(tester, 'host-label', 'Mini PC');
    await enter(tester, 'host-target', 'me@mini');
    await tester.tap(find.byKey(const ValueKey('host-save')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(state.hosts.map((h) => h.id), ['local', 'mini-pc']);
    expect(find.text('Pi · Mini PC'), findsOneWidget);
    expect(find.text('OpenCode · Mini PC'), findsOneWidget);
    expect(find.text('Claude · Mini PC'), findsOneWidget);
    final saved = await tester.runAsync(registry.load);
    expect(saved!.map((h) => h.id), ['local', 'mini-pc']);
    expect(saved[1].localPort, 19931);
  });

  testWidgets('editing keeps the id and its sandbox directory', (tester) async {
    final state = await pump(tester, makeState([local, pc]));
    await tester.tap(find.byKey(const ValueKey('host-edit-pc')));
    await tester.pumpAndSettle();
    await enter(tester, 'host-label', 'Home PC');
    await tester.tap(find.byKey(const ValueKey('host-save')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(state.hosts.map((h) => (h.id, h.label)), [
      ('local', 'This machine'),
      ('pc', 'Home PC'),
    ]);
    expect(find.text('Pi · Home PC'), findsOneWidget);
    expect(state.profiles.where((p) => p.hostId == 'pc').map((p) => p.id), [
      'local-pi-pc',
      'local-opencode-pc',
      'local-claude-pc',
    ]);
  });

  testWidgets('remove is refused while tabs are open, with the message', (
    tester,
  ) async {
    final state = await pump(tester, makeState([local, pc]));
    await tester.runAsync(() async {
      await state.openLocal(
        state.profiles.firstWhere((p) => p.id == 'local-pi-local'),
        tmp.path,
      );
    });
    await tester.pump();
    expect(
      await state.removeHost('local'),
      'Close the 1 tab using This machine first',
    );
    expect(state.hosts.length, 2);

    await tester.tap(find.byKey(const ValueKey('host-edit-pc')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-remove')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(state.hosts.map((h) => h.id), ['local']);
    expect(find.text('Pi · PC'), findsNothing);
    final saved = await tester.runAsync(registry.load);
    expect(saved!.map((h) => h.id), ['local']);
  });
}
