import 'dart:io';

import 'package:ai_app/app/app_state.dart';
import 'package:ai_app/app/layout.dart';
import 'package:ai_app/core/alcf_cli.dart';
import 'package:ai_app/core/agents.dart';
import 'package:ai_app/core/app_store.dart';
import 'package:ai_app/core/guard.dart';
import 'package:ai_app/core/launch.dart';
import 'package:ai_app/core/profiles.dart';
import 'package:ai_app/core/runner.dart';
import 'package:ai_app/core/sandbox.dart';
import 'package:ai_app/core/term_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_runner.dart';
import '../ui/terminal_tab_test.dart' show FakePty;

void main() {
  late Directory tmp;
  late String realHome;
  late Sandbox sb;
  late FakeRunner runner;
  late AppStore store;
  late List<LaunchSpec> started;

  AppState make({Set<String> missing = const {}}) {
    started = [];
    return AppState(
      profiles: defaultProfiles(
        realHome,
        accounts: [
          ClaudeAccount('claude-pro', 'Claude · Pro', '$realHome/.claude-alt'),
        ],
      ),
      which: (exe) => missing.contains(exe) ? null : '/bin/$exe',
      sandbox: sb,
      alcf: AlcfCli(
        runner: runner,
        sandbox: sb,
        guard: RealConfigGuard([]),
        alcfExe: '/bin/alcf-ai',
        tokensExe: '/bin/alcf-tokens',
        uvCacheDir: '/uv',
        sharedSettingsPath: '$realHome/shared.json',
        parentEnv: {'HOME': realHome, 'PATH': '/bin'},
      ),
      start: (spec) {
        started.add(spec);
        return FakePty();
      },
      parentEnv: {'HOME': realHome, 'PATH': '/bin'},
      defaultCwd: tmp.path,
      store: store,
    );
  }

  Profile p(AppState s, String id) => s.profiles.firstWhere((x) => x.id == id);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aiapp_state_');
    realHome = '${tmp.path}/home';
    sb = Sandbox(
      root: '$realHome/.local/share/alcfai/home',
      realHome: realHome,
    );
    File('${sb.claudeDir}/settings.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"env": {"ANTHROPIC_BASE_URL": "https://x/resource_server/minerva/api", "ANTHROPIC_MODEL": "inkling-bf16"}}',
      );
    File('${sb.home}/.pi/agent/models.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"providers": {"alcf-inference-service-minerva-api": {"models": [{"id": "gpt-oss-120b"}]}}}',
      );
    runner = FakeRunner();
    store = AppStore('${tmp.path}/state.json');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('open pi passes the remembered model', () async {
    store.choices['pi-alcf'] = const AgentChoice('minerva', 'gpt-oss-120b');
    final s = make();
    await s.refresh();
    s.open(p(s, 'pi-alcf'), tmp.path);
    expect(s.tabs.single.spec.args, [
      '--model',
      'alcf-inference-service-minerva-api/gpt-oss-120b',
    ]);
  });

  test('open codex and opencode pass the remembered model', () async {
    File('${sb.home}/.codex/alcf-minerva-gpt-oss-120b.config.toml')
        .createSync(recursive: true);
    File('${sb.home}/.config/opencode/opencode.jsonc')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"provider": {"alcf-inference-service-minerva-api": {"models": {"gpt-oss-120b": {}}}}}',
      );
    const c = AgentChoice('minerva', 'gpt-oss-120b');
    store.choices['codex-alcf'] = c;
    store.choices['opencode-alcf'] = c;
    final s = make();
    await s.refresh();
    s.open(p(s, 'codex-alcf'), tmp.path);
    s.open(p(s, 'opencode-alcf'), tmp.path);
    expect(s.tabs[0].spec.args, [
      ...alcfCompatArgs(AgentKind.codex),
      '-p',
      'alcf-minerva-gpt-oss-120b',
    ]);
    expect(s.tabs[1].spec.args, [
      '--model',
      'alcf-inference-service-minerva-api/gpt-oss-120b',
    ]);
  });

  test('choiceFor claude falls back to the sandbox settings', () async {
    final s = make();
    expect(
      s.choiceFor(p(s, 'claude-alcf')),
      const AgentChoice('minerva', 'inkling-bf16'),
    );
    expect(s.choiceFor(p(s, 'pi-alcf')), isNull);
    expect(s.choiceFor(p(s, 'claude-pro')), isNull);
  });

  test('recordChoice persists to the store file', () async {
    final s = make();
    await s.recordChoice(p(s, 'pi-alcf'), const AgentChoice('sophia', 'm'));
    final again = AppStore(store.path);
    await again.load();
    expect(again.choices['pi-alcf'], const AgentChoice('sophia', 'm'));
  });

  test('open and close keep recent folders and last tabs saved', () async {
    final s = make();
    await s.refresh();
    s.open(p(s, 'pi-alcf'), '/w1');
    s.open(p(s, 'claude-pro'), '/w2');
    await s.saving;
    final a = AppStore(store.path);
    await a.load();
    expect(a.recentFolders, ['/w2', '/w1']);
    expect(a.lastTabs, [
      const SavedTab('pi-alcf', '/w1'),
      const SavedTab('claude-pro', '/w2'),
    ]);
    s.close(0);
    await s.saving;
    final b = AppStore(store.path);
    await b.load();
    expect(b.lastTabs, [const SavedTab('claude-pro', '/w2')]);
  });

  test('restart replaces an ended tab with a fresh session in place', () async {
    final s = make();
    await s.refresh();
    s.open(p(s, 'pi-alcf'), '/w1');
    s.open(p(s, 'claude-pro'), '/w2');
    final old = s.tabs[0];
    s.markExited(old, 1);
    s.restart(0);
    expect(s.tabs.length, 2);
    expect(s.tabs[0].id, isNot(old.id));
    expect(s.tabs[0].title, old.title);
    expect(s.tabs[0].spec.cwd, '/w1');
    expect(
      s.tabs[0].spec.env['ALCF_SESSION_ID'],
      isNot(old.spec.env['ALCF_SESSION_ID']),
    );
    expect(s.tabs[0].exitCode, isNull);
    expect(s.active, 0);
    expect(started.length, 0, reason: 'specs only; ptys start in widgets');
  });

  test(
    'reopenLast opens saved tabs that can open and skips the rest',
    () async {
      store.lastTabs = [
        SavedTab('pi-alcf', tmp.path),
        SavedTab('codex-alcf', tmp.path),
        const SavedTab('gone', '/'),
        SavedTab('claude-pro', '${tmp.path}/deleted-folder'),
      ];
      final s = make(missing: {'codex'});
      await s.refresh();
      expect(s.canReopen, 4);
      s.reopenLast();
      expect(s.tabs.map((t) => t.profile!.id), ['pi-alcf']);
      expect(s.canReopen, 0);
    },
  );

  test('zoom changes the font size and persists it', () async {
    final s = make();
    expect(s.fontSize, kTermFontSize);
    s.zoom(1);
    s.zoom(1);
    expect(s.fontSize, kTermFontSize + 2);
    s.zoom(0);
    expect(s.fontSize, kTermFontSize);
    s.zoom(-1);
    await s.saving;
    final a = AppStore(store.path);
    await a.load();
    expect(a.fontSize, kTermFontSize - 1);
  });

  test('statusFor reports the remembered model status', () async {
    runner.handlers['/bin/alcf-ai ls-jobs minerva'] = (_) =>
        const RunResult(0, "{'queued': [{'Models': 'inkling-bf16'}]}", '');
    final s = make();
    expect(await s.statusFor(p(s, 'claude-alcf')), ModelStatus.queued);
    expect(await s.statusFor(p(s, 'claude-pro')), isNull);
  });

  testWidgets('login is re-checked on a timer', (tester) async {
    var checks = 0;
    runner.handlers['/bin/alcf-tokens get-token'] = (_) {
      checks++;
      return const RunResult(0, '', '');
    };
    final s = make();
    s.startLoginChecks(const Duration(hours: 3));
    await tester.pump(const Duration(hours: 3));
    await tester.pump(const Duration(hours: 3));
    expect(checks, 2);
    s.dispose();
    await tester.pump(const Duration(hours: 3));
    expect(checks, 2);
  });

  group('split view', () {
    Future<AppState> three() async {
      final s = make();
      await s.refresh();
      for (final w in ['/a', '/b', '/c']) {
        s.open(p(s, 'pi-alcf'), w);
      }
      return s;
    }

    List<String?> shown(AppState s) => [
      for (final t in s.paneTabs) t?.spec.cwd,
    ];

    int pane(AppState s, int i) => s.panes[i].id;

    test(
      'split right shows a hidden tab in the new pane and focuses it',
      () async {
        final s = await three();
        expect(shown(s), ['/c']);
        s.splitPane(s.focus, Side.right);
        expect(s.isSplit, isTrue);
        expect(shown(s), ['/c', '/a']);
        expect(s.focusIndex, 1);
      },
    );

    test('split left / top put the new pane first', () async {
      final s = await three();
      s.splitPane(s.focus, Side.left);
      expect(shown(s), ['/a', '/c']);
      expect(s.focusIndex, 0);
      final top = s.focus;
      s.splitPane(top, Side.bottom);
      expect(shown(s), ['/a', '/b', '/c']);
      final root = s.layout as SplitNode;
      expect(root.sideBySide, isTrue);
      expect((root.first as SplitNode).sideBySide, isFalse);
    });

    test('many splits; empty panes when tabs run out', () async {
      final s = make();
      await s.refresh();
      s.open(p(s, 'pi-alcf'), '/a');
      s.splitPane(s.focus, Side.right);
      s.splitPane(s.focus, Side.bottom);
      expect(shown(s), ['/a', null, null]);
      s.open(p(s, 'pi-alcf'), '/b'); // goes to the focused (last) pane
      expect(shown(s), ['/a', null, '/b']);
    });

    test('select focuses the pane already showing a tab, else uses the focused one', () async {
      final s = await three();
      s.splitPane(s.focus, Side.right); // ['/c', '/a'], focus right
      s.select(2);
      expect(s.focusIndex, 0);
      s.select(1); // '/b' hidden: goes to the focused (left) pane
      expect(shown(s), ['/b', '/a']);
      expect(s.active, 1);
    });

    test('dropping on an edge splits that pane with the dragged tab', () async {
      final s = await three(); // shows '/c'
      s.splitPane(s.focus, Side.right, tabIndex: 2); // drag the shown tab
      expect(shown(s), ['/b', '/c']);
      s.splitPane(pane(s, 0), Side.top, tabIndex: 0); // '/a' above '/b'
      expect(shown(s), ['/a', '/b', '/c']);
      expect(s.focusIndex, 0);
    });

    test('dragging the only tab to an edge leaves an empty pane', () async {
      final s = make();
      await s.refresh();
      s.open(p(s, 'pi-alcf'), '/a');
      s.splitPane(s.focus, Side.right, tabIndex: 0);
      expect(shown(s), [null, '/a']);
    });

    test(
      'dropping in the middle shows the tab there; a shown tab swaps',
      () async {
        final s = await three();
        s.splitPane(s.focus, Side.right); // ['/c', '/a']
        s.showInPane(pane(s, 0), 1); // '/b' hidden
        expect(shown(s), ['/b', '/a']);
        s.showInPane(pane(s, 0), 0); // '/a' shown on the right: swap
        expect(shown(s), ['/a', '/b']);
        expect(s.focusIndex, 0);
      },
    );

    test(
      'closing a tab shows another hidden one, or removes its pane',
      () async {
        final s = await three();
        s.splitPane(s.focus, Side.right); // ['/c', '/a']
        s.close(0); // '/a' closes; '/b' is hidden and takes its place
        expect(shown(s), ['/c', '/b']);
        s.close(0); // '/b' closes; nothing hidden left
        expect(s.isSplit, isFalse);
        expect(shown(s), ['/c']);
        s.close(0);
        expect(shown(s), [null]);
      },
    );

    test(
      'closePane keeps the tab running; the sibling takes the space',
      () async {
        final s = await three();
        s.splitPane(s.focus, Side.right);
        s.splitPane(s.focus, Side.bottom); // ['/c', '/a', '/b']
        s.closePane(pane(s, 1));
        expect(shown(s), ['/c', '/b']);
        expect(s.tabs.length, 3);
        expect(s.focusIndex, 1);
      },
    );

    test('restart stays in its pane; ratio is clamped', () async {
      final s = await three();
      s.splitPane(s.focus, Side.right); // ['/c', '/a']
      s.markExited(s.tabs[0], 0);
      s.restart(0);
      expect(shown(s), ['/c', '/a']);
      expect(s.focusIndex, 1);
      final root = s.layout as SplitNode;
      s.setRatio(root, 0.99);
      expect(root.ratio, 0.85);
    });
  });
}
