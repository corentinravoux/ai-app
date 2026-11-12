import 'dart:convert';
import 'dart:io';

import 'package:ai_app/core/agents.dart';
import 'package:ai_app/core/local_config.dart';
import 'package:flutter_test/flutter_test.dart';

const t32 = LocalTarget(
  baseUrl: 'http://127.0.0.1:9931',
  alias: 'qwen36-35b-32k',
  hostLabel: 'This machine',
  ctx: 32768,
  maxOutput: 4096,
  vision: false,
);

Map<String, dynamic> readJson(String p) =>
    jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>;

void main() {
  late Directory tmp;
  late String home;
  late List<String> guarded;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aiapp_lc_');
    home = tmp.path;
    guarded = [
      '$home/.claude',
      '$home/.claude-alt',
      '$home/.pi',
      '$home/.config/opencode',
      '$home/.codex',
    ];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('pi models at 32768/4096', () {
    final m = piModels(t32);
    final prov = (m['providers'] as Map)['local'] as Map;
    expect(prov['baseUrl'], 'http://127.0.0.1:9931/v1');
    expect(prov['api'], 'openai-completions');
    expect(prov['apiKey'], 'local');
    expect(prov['name'], 'This machine');
    final model = (prov['models'] as List).single as Map;
    expect(model['id'], 'qwen36-35b-32k');
    expect(model['contextWindow'], 32768);
    expect(model['maxTokens'], 4096);
    expect(model['reasoning'], false);
    expect(model['input'], ['text']);
    expect(model['cost'], {
      'input': 0,
      'output': 0,
      'cacheRead': 0,
      'cacheWrite': 0,
    });
    final v = piModels(
      const LocalTarget(
        baseUrl: 'http://127.0.0.1:9931',
        alias: 'a',
        hostLabel: 'h',
        ctx: 32768,
        maxOutput: 4096,
        vision: true,
      ),
    );
    expect(
      (((v['providers'] as Map)['local'] as Map)['models'] as List)
          .single['input'],
      ['text', 'image'],
    );
  });

  test('pi compaction and default model at 32768/4096', () {
    final s = piSettings(t32);
    expect(s['compaction'], {
      'enabled': true,
      'reserveTokens': 6144,
      'keepRecentTokens': 8192,
    });
    expect(s['defaultProvider'], 'local');
    expect(s['defaultModel'], 'qwen36-35b-32k');
  });

  test('opencode limits and caps (v1 provider schema)', () {
    final c = opencodeConfig(t32);
    expect(c['model'], 'local/qwen36-35b-32k');
    final prov = (c['provider'] as Map)['local'] as Map;
    expect(prov['npm'], '@ai-sdk/openai-compatible');
    expect(prov['options'], {
      'baseURL': 'http://127.0.0.1:9931/v1',
      'apiKey': 'local',
      'headerTimeout': 600000,
    });
    final model = (prov['models'] as Map)['qwen36-35b-32k'] as Map;
    expect(model['limit'], {'context': 32768, 'output': 4096});
    expect(model['tool_call'], true);
    expect(c['compaction'], {
      'auto': true,
      'reserved': 8192,
      'keep': {'tokens': 6144},
    });
    expect(c['tool_output'], {'max_lines': 400, 'max_bytes': 16384});
    expect(c.containsKey('providers'), isFalse);
    expect(c.containsKey('permissions'), isFalse);
  });

  test('claude env points at the target and nowhere else', () {
    const t = LocalTarget(
      baseUrl: 'http://127.0.0.1:19931',
      alias: 'qwen36-35b-2x64k',
      hostLabel: 'PC',
      ctx: 65536,
      maxOutput: 8192,
      vision: false,
    );
    final e = claudeLocalEnv(t, '/d/claude');
    expect(e['ANTHROPIC_BASE_URL'], 'http://127.0.0.1:19931');
    expect(e['ANTHROPIC_API_KEY'], 'local');
    expect(e.containsKey('ANTHROPIC_AUTH_TOKEN'), isFalse);
    expect(e['CLAUDE_CONFIG_DIR'], '/d/claude');
    for (final k in [
      'ANTHROPIC_MODEL',
      'ANTHROPIC_DEFAULT_HAIKU_MODEL',
      'ANTHROPIC_DEFAULT_SONNET_MODEL',
      'ANTHROPIC_DEFAULT_OPUS_MODEL',
      'CLAUDE_CODE_SUBAGENT_MODEL',
    ]) {
      expect(e[k], 'qwen36-35b-2x64k', reason: k);
    }
    expect(e['CLAUDE_CODE_MAX_CONTEXT_TOKENS'], '65536');
    expect(e['CLAUDE_CODE_MAX_OUTPUT_TOKENS'], '8192');
    expect(e['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'], '1');
    expect(e['NO_PROXY'], '127.0.0.1,localhost');
    expect(claudeLocalArgs().take(5), [
      '--bare',
      '--setting-sources',
      'user',
      '--tools',
      'Bash,Read,Edit',
    ]);
  });

  test('overrideEnv per agent', () {
    expect(overrideEnv(AgentKind.pi, '/d'), {'PI_CODING_AGENT_DIR': '/d'});
    expect(overrideEnv(AgentKind.opencode, '/d'), {
      'OPENCODE_CONFIG': '/d/opencode.jsonc',
      'OPENCODE_DISABLE_PROJECT_CONFIG': '1',
      'OPENCODE_DISABLE_AUTOUPDATE': '1',
      'OPENCODE_DISABLE_MODELS_FETCH': '1',
    });
    expect(overrideEnv(AgentKind.claude, '/d'), {'CLAUDE_CONFIG_DIR': '/d'});
  });

  test('writeLocalConfig writes each agent', () async {
    final pi = localDir('$home/.local/share/ai-app', 'local', AgentKind.pi);
    await writeLocalConfig(AgentKind.pi, t32, pi, guardedRoots: guarded);
    expect(readJson('$pi/models.json'), jsonDecode(jsonEncode(piModels(t32))));
    expect(readJson('$pi/settings.json')['defaultModel'], 'qwen36-35b-32k');
    final oc = localDir(
      '$home/.local/share/ai-app',
      'local',
      AgentKind.opencode,
    );
    await writeLocalConfig(AgentKind.opencode, t32, oc, guardedRoots: guarded);
    expect(readJson('$oc/opencode.jsonc')['model'], 'local/qwen36-35b-32k');
    final cl = localDir('$home/.local/share/ai-app', 'local', AgentKind.claude);
    await writeLocalConfig(AgentKind.claude, t32, cl, guardedRoots: guarded);
    expect(Directory(cl).existsSync(), isTrue);
    expect(
      Directory(cl).listSync(),
      isEmpty,
      reason: 'claude is configured by env only',
    );
  });

  test('writeLocalConfig refuses a dir under a guarded root', () async {
    for (final d in [
      '$home/.claude/x',
      '$home/.pi/agent',
      '$home/.config/opencode',
      '$home/.claude-alt',
    ]) {
      await expectLater(
        writeLocalConfig(AgentKind.pi, t32, d, guardedRoots: guarded),
        throwsStateError,
        reason: d,
      );
      expect(Directory(d).existsSync(), isFalse, reason: d);
    }
  });

  test('writeLocalConfig refuses a dir that reaches a guarded root through a symlink', () async {
    Directory('$home/.pi/agent').createSync(recursive: true);
    Directory('$home/.local/share').createSync(recursive: true);
    Link('$home/.local/share/ai-app').createSync('$home/.pi');
    await expectLater(
      writeLocalConfig(
        AgentKind.pi,
        t32,
        '$home/.local/share/ai-app/local/local/pi',
        guardedRoots: guarded,
      ),
      throwsStateError,
    );
    expect(Directory('$home/.pi/local').existsSync(), isFalse);
  });

  test('writeLocalConfig refuses a symlinked extensions dir into a guarded root', () async {
    final dir = '$home/data/local/pc/pi';
    Directory(dir).createSync(recursive: true);
    Directory('$home/.pi/agent/extensions').createSync(recursive: true);
    Link('$dir/extensions').createSync('$home/.pi/agent/extensions');
    await expectLater(
      writeLocalConfig(AgentKind.pi, t32, dir, guardedRoots: guarded),
      throwsStateError,
    );
    expect(
      File('$home/.pi/agent/extensions/web_read.ts').existsSync(),
      isFalse,
    );
  });

  test('writeLocalConfig replaces a symlinked models.json without touching its target', () async {
    final dir = '$home/data/local/pc/pi';
    Directory(dir).createSync(recursive: true);
    final target = File('$home/shared-models.json')
      ..writeAsStringSync('{"keep": true}');
    Link('$dir/models.json').createSync(target.path);
    await writeLocalConfig(AgentKind.pi, t32, dir, guardedRoots: guarded);
    expect(FileSystemEntity.isLinkSync('$dir/models.json'), isFalse);
    expect(target.readAsStringSync(), '{"keep": true}');
    expect(readJson('$dir/models.json')['providers'], isNotNull);
  });

  test(
    'rewriting pi settings keeps a user-added key and updates compaction',
    () async {
      final dir = '$home/data/local/pc/pi';
      Directory(dir).createSync(recursive: true);
      File('$dir/settings.json').writeAsStringSync(
        jsonEncode({
          'theme': 'light',
          'compaction': {'enabled': false, 'reserveTokens': 1},
        }),
      );
      await writeLocalConfig(AgentKind.pi, t32, dir, guardedRoots: guarded);
      final s = readJson('$dir/settings.json');
      expect(s['theme'], 'light');
      expect(s['compaction'], {
        'enabled': true,
        'reserveTokens': 6144,
        'keepRecentTokens': 8192,
      });
    },
  );

  test('a corrupt pi settings file is replaced', () async {
    final dir = '$home/data/pi';
    Directory(dir).createSync(recursive: true);
    File('$dir/settings.json').writeAsStringSync('{oops');
    await writeLocalConfig(AgentKind.pi, t32, dir, guardedRoots: guarded);
    expect(readJson('$dir/settings.json')['defaultProvider'], 'local');
  });

  test('pi config contains the web_read extension', () async {
    final dir = '$home/data/local/pc/pi';
    await writeLocalConfig(AgentKind.pi, t32, dir, guardedRoots: guarded);
    final ext = File('$dir/extensions/web_read.ts').readAsStringSync();
    expect(ext, contains('pi.registerTool'));
    expect(ext, contains('name: "web_read"'));
    expect(ext, contains('pi.exec("webread", [params.url]'));
    // Windows: no cmd.exe (it would split a URL at &); the script is found
    // on PATH and run by py -3 (else python), the URL as its own argument.
    expect(ext, isNot(contains('"cmd"')));
    expect(ext, contains('["-3", script, params.url]'));
    expect(ext, contains('[script, params.url]'));
    // Fall back to python only when py itself is missing, never because
    // webread failed (a 404 would otherwise be fetched twice).
    expect(ext, contains('/^spawn py ENOENT/'));
    expect(ext, isNot(contains('not found|')));
  });

  test('webread.cmd runs webread once, whatever its exit code', () {
    final cmd = File('tools/webread.cmd').readAsStringSync();
    // `a && b || c` would run c again when webread itself fails.
    expect(cmd, isNot(contains('||')));
    expect(cmd, contains('where py'));
    expect(cmd, contains('exit /b'));
    expect(cmd, contains('\r\n'), reason: 'CRLF line ends for cmd.exe');
  });

  test('claude args: bare, user settings only, three tools, web', () {
    // --setting-sources user: a project's .claude/settings.json env would
    // otherwise override ANTHROPIC_BASE_URL even under --bare (measured).
    expect(claudeLocalArgs(), [
      '--bare',
      '--setting-sources',
      'user',
      '--tools',
      'Bash,Read,Edit',
      '--append-system-prompt',
      'To read a web page, run: webread <url>',
    ]);
  });

  test('two hosts get two directories', () {
    expect(localDir('/d', 'local', AgentKind.pi), '/d/local/local/pi');
    expect(localDir('/d', 'pc', AgentKind.pi), '/d/local/pc/pi');
  });

  test('kMinCtx and kLocalAgents', () {
    expect(kMinCtx, {
      AgentKind.pi: 16384,
      AgentKind.opencode: 24576,
      AgentKind.claude: 32768,
    });
    expect(kLocalAgents, [AgentKind.pi, AgentKind.opencode, AgentKind.claude]);
  });

  test('two writes of the same file at once both succeed', () async {
    final dir = '$home/data/local/pc/pi';
    await Future.wait([
      writeLocalConfig(AgentKind.pi, t32, dir, guardedRoots: guarded),
      writeLocalConfig(AgentKind.pi, t32, dir, guardedRoots: guarded),
      writeLocalConfig(
        AgentKind.opencode,
        t32,
        '$home/data/local/pc/oc',
        guardedRoots: guarded,
      ),
      writeLocalConfig(
        AgentKind.opencode,
        t32,
        '$home/data/local/pc/oc',
        guardedRoots: guarded,
      ),
    ]);
    expect(readJson('$dir/models.json')['providers'], isNotNull);
    expect(
      Directory(dir).listSync().where((e) => e.path.endsWith('.tmp')),
      isEmpty,
    );
  });
}
