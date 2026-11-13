import 'dart:convert';
import 'dart:io';

import 'package:ai_app/core/agents.dart';
import 'package:ai_app/core/host_client.dart';
import 'package:ai_app/core/hosts.dart';
import 'package:ai_app/core/local_config.dart';
import 'package:ai_app/core/local_launch.dart';
import 'package:flutter_test/flutter_test.dart';

const pc = ModelHost(
  id: 'pc',
  label: 'PC',
  kind: HostKind.ssh,
  sshTarget: 'pc',
  localPort: 19931,
);

HostStatus ready(int ctx) => HostStatus(
  state: ServerState.ready,
  recipe: 'q',
  label: 'Q',
  alias: 'q',
  ctx: ctx,
  maxOutput: 8192,
  port: 9931,
);

const t64 = LocalTarget(
  baseUrl: 'http://127.0.0.1:19931',
  alias: 'qwen36-35b-64k',
  hostLabel: 'PC',
  ctx: 65536,
  maxOutput: 8192,
  vision: false,
);

Map<String, dynamic> readJson(String p) =>
    jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>;

void main() {
  test('five local agents, in sidebar order, with their minimum windows', () {
    expect(LocalAgent.values.map((a) => a.label), [
      'Pi',
      'OpenCode',
      'Qwen Code',
      'Claude',
      'Claude (full)',
    ]);
    expect(LocalAgent.values.map((a) => a.minCtx), [
      16384,
      24576,
      24576,
      32768,
      65536,
    ]);
    expect(LocalAgent.qwen.kind, AgentKind.qwen);
    expect(LocalAgent.claudeFull.kind, AgentKind.claude);
    expect(AgentKind.qwen.exe, 'qwen');
  });

  test('profile ids keep the old ones and add the new agents', () {
    final ps = localProfiles([pc]);
    expect(ps.map((p) => p.id), [
      'local-pi-pc',
      'local-opencode-pc',
      'local-qwen-pc',
      'local-claude-pc',
      'local-claude-full-pc',
    ]);
    expect(ps.map((p) => p.label), [
      'Pi · PC',
      'OpenCode · PC',
      'Qwen Code · PC',
      'Claude · PC',
      'Claude (full) · PC',
    ]);
    expect(ps.last.localAgent, LocalAgent.claudeFull);
  });

  test('full Claude needs a 64K window', () {
    expect(
      (localReadiness(
        LocalAgent.claudeFull,
        pc,
        ready(32768),
      ) as LocalBlocked).reason,
      'Claude (full) needs a 65536-token window; Q has 32768',
    );
    expect(
      localReadiness(LocalAgent.claudeFull, pc, ready(65536)),
      isA<LocalReady>(),
    );
    expect(
      localReadiness(LocalAgent.claude, pc, ready(32768)),
      isA<LocalReady>(),
    );
  });

  group('configs', () {
    late Directory tmp;
    late String home;
    late List<String> guarded;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('aiapp_la_');
      home = tmp.path;
      guarded = [
        '$home/.claude',
        '$home/.pi',
        '$home/.config/opencode',
        '$home/.qwen',
      ];
      // The user's main Claude folder: instructions and skills to share.
      Directory('$home/.claude/skills/s1').createSync(recursive: true);
      Directory('$home/.claude/commands').createSync();
      File('$home/.claude/CLAUDE.md').writeAsStringSync('# mine');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test(
      'full Claude: settings, onboarding, links to the user instructions',
      () async {
        final dir = localDir('$home/data', 'pc', LocalAgent.claudeFull);
        expect(dir, '$home/data/local/pc/claude-full');
        await writeLocalConfig(
          LocalAgent.claudeFull,
          t64,
          dir,
          guardedRoots: guarded,
          claudeSourceDir: '$home/.claude',
        );
        expect(readJson('$dir/settings.json'), {'apiKeyHelper': 'echo local'});
        expect(readJson('$dir/.claude.json')['hasCompletedOnboarding'], isTrue);
        for (final n in ['CLAUDE.md', 'commands', 'skills']) {
          expect(Link('$dir/$n').targetSync(), '$home/.claude/$n', reason: n);
        }
        expect(
          FileSystemEntity.typeSync('$dir/agents', followLinks: false),
          FileSystemEntityType.notFound,
          reason: 'missing sources are skipped',
        );
        // Rewriting keeps what the user added and does not follow links.
        File('$dir/settings.json')
            .writeAsStringSync('{"theme": "light", "apiKeyHelper": "x"}');
        File('$dir/.claude.json')
            .writeAsStringSync('{"hasCompletedOnboarding": true, "n": 1}');
        await writeLocalConfig(
          LocalAgent.claudeFull,
          t64,
          dir,
          guardedRoots: guarded,
          claudeSourceDir: '$home/.claude',
        );
        expect(readJson('$dir/settings.json'), {
          'theme': 'light',
          'apiKeyHelper': 'echo local',
        });
        expect(readJson('$dir/.claude.json')['n'], 1);
        expect(File('$home/.claude/CLAUDE.md').readAsStringSync(), '# mine');
      },
    );

    test('full Claude env and args', () {
      final e = claudeLocalEnv(t64, '/d', full: true);
      expect(e.containsKey('ANTHROPIC_API_KEY'), isFalse);
      expect(e.containsKey('CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT'), isFalse);
      expect(e['ANTHROPIC_BASE_URL'], 'http://127.0.0.1:19931');
      expect(e['ANTHROPIC_MODEL'], 'qwen36-35b-64k');
      expect(e['CLAUDE_CONFIG_DIR'], '/d');
      final a = claudeLocalArgs(full: true);
      expect(a.contains('--bare'), isFalse);
      expect(a.contains('--tools'), isFalse);
      expect(a.take(2), ['--setting-sources', 'user']);
      expect(a, contains('--append-system-prompt'));
    });

    test('Qwen Code settings', () async {
      final dir = localDir('$home/data', 'pc', LocalAgent.qwen);
      await writeLocalConfig(LocalAgent.qwen, t64, dir, guardedRoots: guarded);
      final s = readJson('$dir/settings.json');
      final prov = (s['modelProviders']['openai'] as List).single as Map;
      expect(prov['id'], 'qwen36-35b-64k');
      expect(prov['baseUrl'], 'http://127.0.0.1:19931/v1');
      expect(prov['envKey'], 'LOCAL_API_KEY');
      expect(prov['generationConfig'], {
        'contextWindowSize': 65536,
        'samplingParams': {'max_tokens': 8192},
      });
      expect(s['env'], {'LOCAL_API_KEY': 'local'});
      expect(s['security'], {
        'auth': {'selectedType': 'openai'},
        'folderTrust': {'enabled': true},
      });
      expect(s['model'], {'name': 'qwen36-35b-64k'});
      expect(s['context'], {'autoCompactThreshold': 0.75});
      expect(s['telemetry'], {'enabled': false});
      expect(s['privacy'], {'usageStatisticsEnabled': false});
    });

    test(
      'Qwen Code env: private home, private trust file, no inherited routing',
      () {
        final e = overrideEnv(LocalAgent.qwen, '/d');
        expect(e, {
          'QWEN_HOME': '/d',
          'QWEN_CODE_TRUSTED_FOLDERS_PATH': '/d/trustedFolders.json',
        });
        for (final k in [
          'OPENAI_API_KEY',
          'OPENAI_BASE_URL',
          'OPENAI_MODEL',
          'QWEN_HOME',
          'QWEN_MODEL',
          'GEMINI_API_KEY',
        ]) {
          expect(isLocalStripped(k), isTrue, reason: k);
        }
        expect(isLocalStripped('HOME'), isFalse);
      },
    );

    test('writing a Qwen config under ~/.qwen is refused', () async {
      await expectLater(
        writeLocalConfig(
          LocalAgent.qwen,
          t64,
          '$home/.qwen',
          guardedRoots: guarded,
        ),
        throwsStateError,
      );
    });
  });

  group('web tools reach every local agent', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('aiapp_web_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('Claude is told about webread and websearch', () {
      expect(kWebToolsPrompt, contains('webread <url>'));
      expect(kWebToolsPrompt, contains('websearch <query>'));
      for (final full in [false, true]) {
        expect(claudeLocalArgs(full: full).last, kWebToolsPrompt);
      }
    });

    test('Pi gets a web_search tool', () async {
      final dir = '${tmp.path}/pi';
      await writeLocalConfig(LocalAgent.pi, t64, dir, guardedRoots: const []);
      final ext = File('$dir/extensions/web_read.ts').readAsStringSync();
      expect(ext, contains('name: "web_search"'));
      expect(ext, contains('"websearch"'));
    });

    test('Qwen Code reads the web lines from QWEN.md in its home', () async {
      final dir = '${tmp.path}/qwen';
      await writeLocalConfig(LocalAgent.qwen, t64, dir, guardedRoots: const []);
      expect(File('$dir/QWEN.md').readAsStringSync(), kWebToolsPrompt);
    });

    test('OpenCode reads them from an instructions file', () async {
      final dir = '${tmp.path}/oc';
      await writeLocalConfig(
        LocalAgent.opencode,
        t64,
        dir,
        guardedRoots: const [],
      );
      final c = readJson('$dir/opencode.jsonc');
      expect(c['instructions'], ['$dir/AGENTS.md']);
      expect(File('$dir/AGENTS.md').readAsStringSync(), kWebToolsPrompt);
    });
  });
}
