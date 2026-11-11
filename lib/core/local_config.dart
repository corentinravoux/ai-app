import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agents.dart';
import 'pi_extension.dart';

/// What an agent needs to know about the model it talks to. Built from the
/// host's live status, so the declared window is the server's real one.
class LocalTarget {
  const LocalTarget({
    required this.baseUrl,
    required this.alias,
    required this.hostLabel,
    required this.ctx,
    required this.maxOutput,
    required this.vision,
  });

  /// `http://127.0.0.1:<port>`, no trailing slash, no `/v1`.
  final String baseUrl;

  /// The model name the server answers to (the recipe name).
  final String alias;
  final String hostLabel;
  final int ctx;
  final int maxOutput;
  final bool vision;
}

/// Smallest window each agent works in: its own prompt and tools take
/// ~1.5K (Pi), ~13K (OpenCode) and ~22K (Claude Code) tokens
/// (docs/local-wire-notes.md).
const kMinCtx = {
  AgentKind.pi: 16384,
  AgentKind.opencode: 24576,
  AgentKind.claude: 32768,
};

/// Agents offered against model hosts, in sidebar order.
const kLocalAgents = [AgentKind.pi, AgentKind.opencode, AgentKind.claude];

String localDir(String dataRoot, String hostId, AgentKind k) =>
    '$dataRoot/local/$hostId/${k.name}';

Map<String, dynamic> piModels(LocalTarget t) => {
  'providers': {
    'local': {
      'name': t.hostLabel,
      'baseUrl': '${t.baseUrl}/v1',
      'api': 'openai-completions',
      'apiKey': 'local',
      'models': [
        {
          'id': t.alias,
          'reasoning': false,
          'input': ['text', if (t.vision) 'image'],
          'contextWindow': t.ctx,
          'maxTokens': t.maxOutput,
          'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
        },
      ],
    },
  },
};

/// The keys of Pi's settings.json the app owns; others are kept.
Map<String, dynamic> piSettings(LocalTarget t) => {
  'defaultProvider': 'local',
  'defaultModel': t.alias,
  'compaction': {
    'enabled': true,
    'reserveTokens': t.maxOutput + 2048,
    'keepRecentTokens': t.ctx ~/ 4,
  },
};

/// OpenCode 1.19 reads the v1 `provider` block (the "V2" `providers`
/// block is silently dropped; docs/local-wire-notes.md).
Map<String, dynamic> opencodeConfig(LocalTarget t) => {
  r'$schema': 'https://opencode.ai/config.json',
  'model': 'local/${t.alias}',
  'provider': {
    'local': {
      'npm': '@ai-sdk/openai-compatible',
      'name': t.hostLabel,
      'options': {
        'baseURL': '${t.baseUrl}/v1',
        'apiKey': 'local',
        'headerTimeout': 600000,
      },
      'models': {
        t.alias: {
          'name': t.alias,
          'tool_call': true,
          if (t.vision)
            'modalities': {
              'input': ['text', 'image'],
              'output': ['text'],
            },
          'limit': {'context': t.ctx, 'output': t.maxOutput},
        },
      },
    },
  },
  'compaction': {
    'auto': true,
    'reserved': t.ctx ~/ 4,
    'keep': {'tokens': t.ctx * 3 ~/ 16},
  },
  'tool_output': {'max_lines': 400, 'max_bytes': 16384},
};

/// Claude Code against llama-server's `/v1/messages`: everything goes
/// through the environment, nothing into a settings file.
Map<String, String> claudeLocalEnv(LocalTarget t, String dir) => {
  'CLAUDE_CONFIG_DIR': dir,
  'ANTHROPIC_BASE_URL': t.baseUrl,
  'ANTHROPIC_API_KEY': 'local',
  'ANTHROPIC_MODEL': t.alias,
  'ANTHROPIC_DEFAULT_HAIKU_MODEL': t.alias,
  'ANTHROPIC_DEFAULT_SONNET_MODEL': t.alias,
  'ANTHROPIC_DEFAULT_OPUS_MODEL': t.alias,
  'CLAUDE_CODE_SUBAGENT_MODEL': t.alias,
  'CLAUDE_CODE_MAX_CONTEXT_TOKENS': '${t.ctx}',
  'CLAUDE_CODE_MAX_OUTPUT_TOKENS': '${t.maxOutput}',
  'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
  'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS': '1',
  'CLAUDE_CODE_ATTRIBUTION_HEADER': '0',
  'CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT': '1',
  'NO_PROXY': '127.0.0.1,localhost',
};

/// No hooks, plugins, skills or CLAUDE.md, and three tools: the local
/// window is too small for the full scaffolding. Web pages go through
/// `webread` (tools/webread), first on the tab's PATH.
///
/// `--setting-sources user` keeps a project's `.claude/settings.json` from
/// overriding the endpoint: its `env` block applies even under `--bare`
/// (measured with Claude Code 2.1.322). "user" is this tab's own empty
/// config folder.
List<String> claudeLocalArgs() => const [
  '--bare',
  '--setting-sources',
  'user',
  '--tools',
  'Bash,Read,Edit',
  '--append-system-prompt',
  'To read a web page, run: webread <url>',
];

Map<String, String> overrideEnv(AgentKind k, String dir) => switch (k) {
  AgentKind.pi => {'PI_CODING_AGENT_DIR': dir},
  // A project's opencode.json would otherwise be merged over this config
  // (its provider wins); no update checks or models.dev fetches offline.
  AgentKind.opencode => {
    'OPENCODE_CONFIG': '$dir/opencode.jsonc',
    'OPENCODE_DISABLE_PROJECT_CONFIG': '1',
    'OPENCODE_DISABLE_AUTOUPDATE': '1',
    'OPENCODE_DISABLE_MODELS_FETCH': '1',
  },
  AgentKind.claude => {'CLAUDE_CONFIG_DIR': dir},
  AgentKind.codex => throw ArgumentError('codex is not offered on model hosts'),
};

/// Writes agent [k]'s config for [t] into [dir]. Refuses (StateError,
/// nothing written) when [dir] is, or resolves through a symlink to, a
/// place under one of [guardedRoots] (the user's real agent configs).
Future<void> writeLocalConfig(
  AgentKind k,
  LocalTarget t,
  String dir, {
  required List<String> guardedRoots,
}) async {
  _refuseGuarded(dir, guardedRoots);
  await Directory(dir).create(recursive: true);
  _refuseGuarded(dir, guardedRoots);
  switch (k) {
    case AgentKind.pi:
      await _writeJson('$dir/models.json', piModels(t));
      Map<String, dynamic> old = {};
      try {
        final v = jsonDecode(await File('$dir/settings.json').readAsString());
        if (v is Map) old = Map<String, dynamic>.from(v);
      } on Object {
        // missing or corrupt: start over
      }
      await _writeJson('$dir/settings.json', {...old, ...piSettings(t)});
      // A symlinked extensions/ would carry the write into its target: the
      // guard on [dir] does not cover what a child resolves to.
      final ext = '$dir/extensions';
      _refuseGuarded(ext, guardedRoots);
      await Directory(ext).create();
      _refuseGuarded(ext, guardedRoots);
      await _writeText('$ext/web_read.ts', kPiWebReadExtension);
    case AgentKind.opencode:
      await _writeJson('$dir/opencode.jsonc', opencodeConfig(t));
    case AgentKind.claude:
      break;
    case AgentKind.codex:
      throw ArgumentError('codex is not offered on model hosts');
  }
}

void _refuseGuarded(String dir, List<String> roots) {
  final plain = p.normalize(p.absolute(dir));
  final real = _resolveExisting(plain);
  for (final r in roots) {
    final root = p.normalize(p.absolute(r));
    final realRoot = _resolveExisting(root);
    for (final d in {plain, real}) {
      for (final x in {root, realRoot}) {
        if (p.equals(d, x) || p.isWithin(x, d)) {
          throw StateError('refusing to write agent config into $r ($dir)');
        }
      }
    }
  }
}

/// [path] with its longest existing prefix resolved through symlinks.
String _resolveExisting(String path) {
  var head = path;
  final tail = <String>[];
  while (true) {
    final type = FileSystemEntity.typeSync(head);
    if (type != FileSystemEntityType.notFound) {
      try {
        final real = Directory(head).resolveSymbolicLinksSync();
        return p.joinAll([real, ...tail.reversed]);
      } on FileSystemException {
        return path;
      }
    }
    final parent = p.dirname(head);
    if (parent == head) return path;
    tail.add(p.basename(head));
    head = parent;
  }
}

Future<void> _writeJson(String path, Map<String, dynamic> v) =>
    _writeText(path, const JsonEncoder.withIndent('  ').convert(v));

int _tmpCounter = 0;

/// Temp file + rename; a symlink at [path] is replaced, never followed.
Future<void> _writeText(String path, String text) async {
  if (await FileSystemEntity.isLink(path)) await Link(path).delete();
  // A temp name of its own: two tabs opening at once must not collide.
  final tmp = File('$path.$pid.${_tmpCounter++}.tmp');
  await tmp.writeAsString(text);
  await tmp.rename(path);
}
