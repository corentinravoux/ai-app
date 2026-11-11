import 'dart:convert';
import 'dart:io';

import 'package:ai_app/core/agents.dart';
import 'package:ai_app/core/host_client.dart';
import 'package:ai_app/core/hosts.dart';
import 'package:ai_app/core/launch.dart';
import 'package:ai_app/core/local_config.dart';
import 'package:ai_app/core/local_launch.dart';
import 'package:ai_app/core/profiles.dart';
import 'package:ai_app/core/sandbox.dart';
import 'package:flutter_test/flutter_test.dart';

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

HostStatus st(
  ServerState s, {
  int? ctx = 65536,
  String label = 'Qwen3.6 35B-A3B · 64K',
}) => HostStatus(
  state: s,
  recipe: 'qwen36-35b-64k',
  label: label,
  alias: 'qwen36-35b-64k',
  ctx: ctx,
  maxOutput: 8192,
  port: 9931,
);

void main() {
  test('localProfiles builds three profiles per host with stable ids', () {
    final ps = localProfiles([local, pc]);
    expect(ps.map((p) => p.id), [
      'local-pi-local',
      'local-opencode-local',
      'local-claude-local',
      'local-pi-pc',
      'local-opencode-pc',
      'local-claude-pc',
    ]);
    expect(ps.map((p) => p.label).take(3), [
      'Pi · This machine',
      'OpenCode · This machine',
      'Claude · This machine',
    ]);
    expect(ps.every((p) => p.backend == Backend.local && p.isLocal), isTrue);
    expect(ps.every((p) => !p.isAlcf && !p.isNative), isTrue);
    expect(ps[3].hostId, 'pc');
  });

  group('localReadiness', () {
    String reason(LocalReadiness r) => (r as LocalBlocked).reason;

    test('blocked reasons verbatim', () {
      expect(
        reason(localReadiness(AgentKind.pi, pc, null)),
        'PC is unreachable',
      );
      expect(
        reason(localReadiness(AgentKind.pi, pc, st(ServerState.stopped))),
        'No model is running on PC: start one',
      );
      expect(
        reason(localReadiness(AgentKind.pi, pc, st(ServerState.loading))),
        'PC is loading Qwen3.6 35B-A3B · 64K…',
      );
      expect(
        reason(localReadiness(AgentKind.pi, pc, st(ServerState.foreign))),
        'A llama-server not started by AI App is running on PC',
      );
      expect(
        reason(localReadiness(AgentKind.pi, pc, st(ServerState.error))),
        'The model failed to start on PC: open the log',
      );
    });

    test('ready carries ctx, output cap, alias and the host url', () {
      final r = localReadiness(AgentKind.claude, pc, st(ServerState.ready));
      final t = (r as LocalReady).target;
      expect(
        (t.ctx, t.maxOutput, t.alias, t.baseUrl, t.hostLabel),
        (65536, 8192, 'qwen36-35b-64k', 'http://127.0.0.1:19931', 'PC'),
      );
    });

    test('open is refused below the agent minimum', () {
      final s = st(ServerState.ready, ctx: 24576, label: 'Small · 24K');
      expect(localReadiness(AgentKind.pi, local, s), isA<LocalReady>());
      expect(localReadiness(AgentKind.opencode, local, s), isA<LocalReady>());
      expect(
        reason(localReadiness(AgentKind.claude, local, s)),
        'Claude Code needs a 32768-token window; Small · 24K has 24576',
      );
    });

    test('ready without a known window or alias is blocked', () {
      final s = HostStatus(state: ServerState.ready, port: 9931);
      expect(localReadiness(AgentKind.pi, local, s), isA<LocalBlocked>());
    });
  });

  group('buildLocalLaunch', () {
    late Directory tmp;
    late String home;
    late List<String> guarded;
    const target = LocalTarget(
      baseUrl: 'http://127.0.0.1:19931',
      alias: 'qwen36-35b-64k',
      hostLabel: 'PC',
      ctx: 65536,
      maxOutput: 8192,
      vision: false,
    );
    final parent = {
      'PATH': '/usr/bin:/bin',
      'HOME': '/h',
      'ANTHROPIC_API_KEY': 'real',
      'ANTHROPIC_BASE_URL': 'https://api.anthropic.com',
      'CLAUDE_CONFIG_DIR': '/h/.claude-alt',
      'CLAUDE_CODE_OAUTH_TOKEN': 't',
      'PI_CODING_AGENT_DIR': '/h/.pi/agent',
      'OPENCODE_CONFIG': '/h/.config/opencode/opencode.jsonc',
      'ALCF_SESSION_ID': 'x',
    };

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('aiapp_ll_');
      home = tmp.path;
      guarded = ['$home/.claude', '$home/.pi', '$home/.config/opencode'];
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<LaunchSpec> launch(AgentKind k) => buildLocalLaunch(
      localProfiles([pc]).firstWhere((p) => p.kind == k),
      host: pc,
      target: target,
      dataRoot: '$home/data',
      parentEnv: parent,
      exePath: '/bin/${k.exe}',
      cwd: '/work dir',
      toolsBinDir: '$home/data/bin',
      guardedRoots: guarded,
    );

    test(
      'local claude env never contains an inherited ANTHROPIC key',
      () async {
        final s = await launch(AgentKind.claude);
        expect(s.env['ANTHROPIC_API_KEY'], 'local');
        expect(s.env['ANTHROPIC_BASE_URL'], 'http://127.0.0.1:19931');
        expect(s.env['CLAUDE_CONFIG_DIR'], '$home/data/local/pc/claude');
        expect(s.env.containsKey('CLAUDE_CODE_OAUTH_TOKEN'), isFalse);
        expect(s.env.containsKey('ALCF_SESSION_ID'), isFalse);
        expect(s.args.take(5), [
          '--bare',
          '--setting-sources',
          'user',
          '--tools',
          'Bash,Read,Edit',
        ]);
      },
    );

    test(
      'opencode env disables project config, updates and model fetches',
      () async {
        final oc = await launch(AgentKind.opencode);
        expect(oc.env['OPENCODE_DISABLE_PROJECT_CONFIG'], '1');
        expect(oc.env['OPENCODE_DISABLE_AUTOUPDATE'], '1');
        expect(oc.env['OPENCODE_DISABLE_MODELS_FETCH'], '1');
        final pi = await launch(AgentKind.pi);
        expect(pi.env.containsKey('OPENCODE_DISABLE_PROJECT_CONFIG'), isFalse);
      },
    );

    test('local OpenCode ignores config injected from the parent', () async {
      parent.addAll({
        'OPENCODE_CONFIG_CONTENT': '{"model": "evil/x"}',
        'OPENCODE_CONFIG_DIR': '/elsewhere',
      });
      addTearDown(
        () => parent.removeWhere((k, _) => k.startsWith('OPENCODE_CONFIG_')),
      );
      for (final k in [AgentKind.claude, AgentKind.pi, AgentKind.opencode]) {
        final s = await launch(k);
        expect(s.env.containsKey('OPENCODE_CONFIG_CONTENT'), isFalse);
        expect(s.env.containsKey('OPENCODE_CONFIG_DIR'), isFalse);
      }
      expect(kLocalStrippedEnvKeys, contains('OPENCODE_CONFIG_CONTENT'));
    });

    test('local tabs drop cloud-provider switches', () async {
      parent.addAll({
        'CLAUDE_CODE_USE_BEDROCK': '1',
        'CLAUDE_CODE_USE_VERTEX': '1',
        'CLAUDE_CODE_USE_FOUNDRY': '1',
        'AWS_BEARER_TOKEN_BEDROCK': 'secret',
      });
      addTearDown(
        () => parent.removeWhere(
          (k, _) => k.startsWith('CLAUDE_CODE_USE_') || k.startsWith('AWS_'),
        ),
      );
      for (final k in [AgentKind.claude, AgentKind.pi, AgentKind.opencode]) {
        final s = await launch(k);
        for (final key in kLocalStrippedEnvKeys) {
          expect(s.env.containsKey(key), isFalse, reason: '$k $key');
        }
      }
    });

    test('pi and opencode specs carry only their own override', () async {
      final pi = await launch(AgentKind.pi);
      expect(pi.env['PI_CODING_AGENT_DIR'], '$home/data/local/pc/pi');
      expect(pi.env.keys.where((k) => k.startsWith('ANTHROPIC_')), isEmpty);
      expect(pi.env.containsKey('CLAUDE_CONFIG_DIR'), isFalse);
      expect(pi.env.containsKey('OPENCODE_CONFIG'), isFalse);
      expect(pi.args, isEmpty);
      final oc = await launch(AgentKind.opencode);
      expect(
        oc.env['OPENCODE_CONFIG'],
        '$home/data/local/pc/opencode/opencode.jsonc',
      );
      expect(oc.env.containsKey('PI_CODING_AGENT_DIR'), isFalse);
      expect(oc.env.keys.where((k) => k.startsWith('ANTHROPIC_')), isEmpty);
    });

    test(
      'PATH starts with toolsBinDir and keeps the parent PATH; HOME unchanged',
      () async {
        final s = await launch(AgentKind.pi);
        expect(s.env['PATH'], '$home/data/bin:/usr/bin:/bin');
        expect(s.env['HOME'], '/h');
        expect(s.env['TERM'], 'xterm-256color');
        expect((s.executable, s.cwd), ('/bin/pi', '/work dir'));
      },
    );

    test('buildLocalLaunch writes the config before returning', () async {
      await launch(AgentKind.pi);
      final m = jsonDecode(
        File('$home/data/local/pc/pi/models.json').readAsStringSync(),
      );
      expect(
        (m['providers']['local']['models'] as List).single['contextWindow'],
        65536,
      );
    });
  });

  test('buildLaunch refuses a local profile', () {
    expect(
      () => buildLaunch(
        localProfiles([local]).first,
        sandbox: Sandbox(root: '/s', realHome: '/h'),
        parentEnv: const {},
        exePath: '/bin/pi',
        cwd: '/',
        sessionId: 'x',
      ),
      throwsArgumentError,
    );
  });

  test('native and ALCF profiles keep their flags', () {
    final ps = defaultProfiles(
      '/h',
      accounts: const [
        ClaudeAccount('claude-default', 'Claude · your account', '/h/.claude'),
      ],
    );
    expect(ps.where((p) => p.isAlcf).length, 4);
    expect(ps.where((p) => p.isNative).single.id, 'claude-default');
    expect(ps.any((p) => p.isLocal), isFalse);
  });

  test('kAgentBinDirs includes the user Node install', () {
    expect(kAgentBinDirs, contains('opt/node/bin'));
    expect(kAgentBinDirs, contains('.npm-global/bin'));
  });

  test('every local agent has a minimum window', () {
    for (final k in kLocalAgents) {
      expect(kMinCtx[k], isNotNull);
    }
  });
}
