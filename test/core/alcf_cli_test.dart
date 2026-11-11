import 'dart:convert';
import 'dart:io';

import 'package:ai_app/core/agents.dart';
import 'package:ai_app/core/alcf_cli.dart';
import 'package:ai_app/core/guard.dart';
import 'package:ai_app/core/runner.dart';
import 'package:ai_app/core/sandbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_runner.dart';

const lsModels = '''
[
  {"id": "beam-1.0-bf16", "display_name": "Beam 1.0 BF16",
   "capabilities": {"api_protocols": ["chat_completions", "responses", "messages"],
                    "context_window_tokens": 1048576}},
  {"id": "plain-model", "display_name": "Plain",
   "capabilities": {"api_protocols": ["chat_completions"]}}
]
''';

const lsJobs = '''
{
    'running': [
        {
            'Models': 'gpt-oss-120b',
            'Framework': 'api',
            'Model Status': 'running'
        },
        {
            'Models': 'beam-1.0-bf16',
            'Model Status': 'running'
        }
    ],
    'queued': [
        {
            'Models': 'inkling-bf16',
            'Model Status': 'queued'
        }
    ],
    'stopped': [
        {
            'Models': 'muse-spark-bf16'
        }
    ]
}
''';

void main() {
  late Directory tmp;
  late String realHome;
  late Sandbox sb;
  late FakeRunner runner;
  late String sharedPath;

  AlcfCli cli() => AlcfCli(
    runner: runner,
    sandbox: sb,
    guard: RealConfigGuard(RealConfigGuard.defaultPaths(realHome)),
    alcfExe: '/bin/alcf-ai',
    tokensExe: '/bin/alcf-tokens',
    uvCacheDir: '/uvcache',
    sharedSettingsPath: sharedPath,
    parentEnv: {
      'HOME': realHome,
      'PATH': '/bin',
      'CLAUDE_CONFIG_DIR': '$realHome/.claude-alt',
    },
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aiapp_cli_');
    realHome = '${tmp.path}/home';
    Directory('$realHome/.globus').createSync(recursive: true);
    Directory('$realHome/.claude/plugins').createSync(recursive: true);
    sharedPath = '$realHome/.claude/settings.json';
    File(sharedPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'model': 'opus',
          'outputStyle': 'Concise',
          'enabledPlugins': {'x': true},
        }),
      );
    sb = Sandbox(
      root: '$realHome/.local/share/alcfai/home',
      realHome: realHome,
    );
    runner = FakeRunner();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Iterable<Call> configureCalls() =>
      runner.calls.where((c) => c.args.take(2).join(' ') == 'agent configure');

  test('configure runs alcf-ai with sandbox HOME', () async {
    final r = await cli().configure(AgentKind.claude);
    expect(r, isA<ConfigureOk>());
    final c = configureCalls().single;
    expect(c.exe, '/bin/alcf-ai');
    expect(c.args, [
      'agent',
      'configure',
      'claude',
      '-m',
      'inkling-bf16',
      '-c',
      'minerva',
    ]);
    expect(c.env!['HOME'], sb.home);
    expect(c.env!['UV_CACHE_DIR'], '/uvcache');
    expect(c.env!.containsKey('CLAUDE_CONFIG_DIR'), isFalse);
    expect(c.env!['PATH'], '/bin');
  });

  test('configure seeds claude settings before alcf-ai', () async {
    Map<String, dynamic>? seen;
    runner.handlers['/bin/alcf-ai agent configure'] = (c) {
      seen = jsonDecode(
        File('${sb.claudeDir}/settings.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      return const RunResult(0, '', '');
    };
    await cli().configure(AgentKind.claude);
    expect(seen!['outputStyle'], 'Concise');
    expect(seen!.containsKey('model'), isFalse);
  });

  test('configure passes includePlugins to seed and plugins link', () async {
    await cli().configure(AgentKind.claude, includePlugins: true);
    final s = jsonDecode(
      File('${sb.claudeDir}/settings.json').readAsStringSync(),
    );
    expect(s['enabledPlugins'], {'x': true});
    expect(FileSystemEntity.isLinkSync('${sb.claudeDir}/plugins'), isTrue);

    await cli().configure(AgentKind.claude, includePlugins: false);
    final s2 = jsonDecode(
      File('${sb.claudeDir}/settings.json').readAsStringSync(),
    );
    expect(s2.containsKey('enabledPlugins'), isFalse);
    expect(FileSystemEntity.isLinkSync('${sb.claudeDir}/plugins'), isFalse);
  });

  test('configure does not seed for pi/codex/opencode', () async {
    for (final k in [AgentKind.pi, AgentKind.codex, AgentKind.opencode]) {
      await cli().configure(k);
    }
    expect(File('${sb.claudeDir}/settings.json').existsSync(), isFalse);
    expect(configureCalls().map((c) => c.args[2]), ['pi', 'codex', 'opencode']);
  });

  test(
    'configure codex drops freeform apply_patch from the catalogs',
    () async {
      final cat = File('${sb.home}/.codex/catalogs/m.json');
      runner.handlers['/bin/alcf-ai agent configure codex'] = (_) {
        cat
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'models': [
                {'slug': 'm', 'apply_patch_tool_type': 'freeform'},
              ],
            }),
          );
        File('${sb.home}/.codex/catalogs/broken.json').writeAsStringSync('{');
        return const RunResult(0, '', '');
      };
      expect(await cli().configure(AgentKind.codex), isA<ConfigureOk>());
      final m = (jsonDecode(cat.readAsStringSync())['models'] as List).single;
      expect(m, {'slug': 'm', 'apply_patch_tool_type': null});
    },
  );

  test('configure adds --include-experimental when asked', () async {
    await cli().configure(
      AgentKind.pi,
      model: 'm',
      cluster: 'tara',
      experimental: true,
    );
    expect(configureCalls().single.args, [
      'agent',
      'configure',
      'pi',
      '-m',
      'm',
      '-c',
      'tara',
      '--include-experimental',
    ]);
  });

  test('configure adds --include-experimental for a model alcf-ai does not '
      'allowlist yet on that cluster', () async {
    await cli().configure(
      AgentKind.pi,
      model: 'muse-spark-bf16',
      cluster: 'tara',
    );
    expect(configureCalls().single.args, contains('--include-experimental'));
  });

  test(
    'configure leaves --include-experimental out for an allowlisted model',
    () async {
      await cli().configure(AgentKind.pi, model: 'muse-spark-bf16');
      expect(
        configureCalls().single.args,
        isNot(contains('--include-experimental')),
      );
    },
  );

  test('configure returns LoginNeeded when token check fails', () async {
    runner.handlers['/bin/alcf-tokens get-token inference'] = (_) =>
        const RunResult(1, '', 'no tokens');
    expect(await cli().configure(AgentKind.claude), isA<LoginNeeded>());
    expect(configureCalls(), isEmpty);
    expect(await cli().tokenOk(), isFalse);
  });

  test(
    'configure reports RealConfigTouched when a guarded file changes',
    () async {
      runner.handlers['/bin/alcf-ai agent configure'] = (_) {
        File('$realHome/.claude/settings.json')
            .writeAsStringSync('{"env": {}}');
        return const RunResult(0, '', '');
      };
      final r = await cli().configure(AgentKind.claude);
      expect(r, isA<RealConfigTouched>());
      expect((r as RealConfigTouched).paths, [
        '$realHome/.claude/settings.json',
      ]);
    },
  );

  test('configure maps non-zero exit to ConfigureFailed', () async {
    runner.handlers['/bin/alcf-ai agent configure'] = (_) =>
        const RunResult(1, '', 'Traceback\nValueError: bad model\n');
    final r = await cli().configure(AgentKind.pi);
    expect((r as ConfigureFailed).message, 'ValueError: bad model');
  });

  test('loginCommand is alcf-tokens login inference', () {
    expect(cli().loginCommand, ['/bin/alcf-tokens', 'login', 'inference']);
  });

  test('explainError maps known ALCF errors', () {
    expect(
      explainError('x IdentityMismatchError: Detected a change'),
      contains('alcf-tokens clear-tokens'),
    );
    expect(
      explainError('HTTP 429 Too Many Requests'),
      contains('rate limit, wait and retry'),
    );
    expect(
      explainError('Permission denied'),
      contains('run alcf-tokens login inference'),
    );
    expect(
      explainError('httpx.ReadTimeout: timed out'),
      contains('model may be queued: check its status and retry'),
    );
    expect(explainError('first\nlast line\n\n'), 'last line');
  });

  test('listModels parses ls-models JSON', () async {
    runner.handlers['/bin/alcf-ai ls-models minerva'] = (_) =>
        const RunResult(0, lsModels, '');
    final all = await cli().listModels('minerva');
    expect(all.map((m) => m.id), ['beam-1.0-bf16', 'plain-model']);
    expect(all.first.displayName, 'Beam 1.0 BF16');
    expect(all.first.contextTokens, 1048576);
    final claude = await cli().listModels(
      'minerva',
      forAgent: AgentKind.claude,
    );
    expect(claude.map((m) => m.id), ['beam-1.0-bf16']);
    final codex = await cli().listModels('minerva', forAgent: AgentKind.codex);
    expect(codex.map((m) => m.id), ['beam-1.0-bf16']);
  });

  test(
    'listModels survives rich line wrapping and asks for wide output',
    () async {
      runner.handlers['/bin/alcf-ai ls-models minerva'] = (_) =>
          const RunResult(
            0,
            '[{"id": "m", "display_name": "M", "description": "served through ALCF\nMinerva"}]',
            '',
          );
      expect((await cli().listModels('minerva')).map((m) => m.id), ['m']);
      expect(runner.calls.last.env!['COLUMNS'], '100000');
    },
  );

  test('listModels returns empty list on bad JSON', () async {
    runner.handlers['/bin/alcf-ai ls-models'] = (_) =>
        const RunResult(0, 'not json', '');
    expect(await cli().listModels('minerva'), isEmpty);
  });

  test('modelStatus parses ls-jobs repr', () async {
    runner.handlers['/bin/alcf-ai ls-jobs minerva'] = (_) =>
        const RunResult(0, lsJobs, '');
    expect(await cli().modelStatus('minerva'), {
      'gpt-oss-120b': ModelStatus.running,
      'beam-1.0-bf16': ModelStatus.running,
      'inkling-bf16': ModelStatus.queued,
      'muse-spark-bf16': ModelStatus.offline,
    });
    runner.handlers['/bin/alcf-ai ls-jobs minerva'] = (_) =>
        const RunResult(0, '<<garbage>>', '');
    expect(await cli().modelStatus('minerva'), isEmpty);
  });

  test('kClusters never offers metis', () {
    expect(kClusters, ['tara', 'minerva', 'sophia']);
  });
}
