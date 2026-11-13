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

String localDir(String dataRoot, String hostId, LocalAgent a) =>
    '$dataRoot/local/$hostId/${a.dirName}';

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

/// Qwen Code's `settings.json` (measured with Qwen Code 0.27.3). Folder
/// trust is on with a private trusted-folders file, so a project's own
/// `.qwen/settings.json` (which would replace the provider) is ignored.
Map<String, dynamic> qwenSettings(LocalTarget t) => {
  'modelProviders': {
    'openai': [
      {
        'id': t.alias,
        'name': t.alias,
        'envKey': 'LOCAL_API_KEY',
        'baseUrl': '${t.baseUrl}/v1',
        'generationConfig': {
          'contextWindowSize': t.ctx,
          'samplingParams': {'max_tokens': t.maxOutput},
        },
      },
    ],
  },
  'env': {'LOCAL_API_KEY': 'local'},
  'security': {
    'auth': {'selectedType': 'openai'},
    'folderTrust': {'enabled': true},
  },
  'model': {'name': t.alias},
  'context': {'autoCompactThreshold': 0.75},
  'telemetry': {'enabled': false},
  'privacy': {'usageStatisticsEnabled': false},
};

/// Claude Code against llama-server's `/v1/messages`, set through the
/// environment. [full] (Claude with the user's instructions and skills)
/// authenticates through `apiKeyHelper` in its settings instead: outside
/// `--bare`, `ANTHROPIC_API_KEY` alone gives "Not logged in" (measured).
Map<String, String> claudeLocalEnv(
  LocalTarget t,
  String dir, {
  bool full = false,
}) => {
  'CLAUDE_CONFIG_DIR': dir,
  'ANTHROPIC_BASE_URL': t.baseUrl,
  if (!full) 'ANTHROPIC_API_KEY': 'local',
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
  if (!full) 'CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT': '1',
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
///
/// [full]: no `--bare` and every tool; the user's `CLAUDE.md`, commands and
/// skills come from links in the tab's config folder.
List<String> claudeLocalArgs({bool full = false}) => [
  if (!full) '--bare',
  '--setting-sources',
  'user',
  if (!full) ...['--tools', 'Bash,Read,Edit'],
  '--append-system-prompt',
  kWebToolsPrompt,
];

/// Tells an agent how to reach the web from a local tab (Claude through
/// its system prompt, Qwen Code and OpenCode through an instructions file).
const kWebToolsPrompt =
    'To read a web page, run: webread <url>\n'
    'To search the web, run: websearch <query>';

Map<String, String> overrideEnv(LocalAgent a, String dir) => switch (a) {
  LocalAgent.pi => {'PI_CODING_AGENT_DIR': dir},
  // A project's opencode.json would otherwise be merged over this config
  // (its provider wins); no update checks or models.dev fetches offline.
  LocalAgent.opencode => {
    'OPENCODE_CONFIG': '$dir/opencode.jsonc',
    'OPENCODE_DISABLE_PROJECT_CONFIG': '1',
    'OPENCODE_DISABLE_AUTOUPDATE': '1',
    'OPENCODE_DISABLE_MODELS_FETCH': '1',
  },
  // Qwen Code keeps its whole global config in QWEN_HOME; the trusted
  // folders list stays private, so no project is trusted.
  LocalAgent.qwen => {
    'QWEN_HOME': dir,
    'QWEN_CODE_TRUSTED_FOLDERS_PATH': '$dir/trustedFolders.json',
  },
  LocalAgent.claude || LocalAgent.claudeFull => {'CLAUDE_CONFIG_DIR': dir},
};

/// What full Claude shares from the user's own Claude folder. They are
/// copied, not linked, at every tab open: Claude Code writes into its own
/// folder (`/memory`, `/agents`), and a link would carry that into the
/// user's real `~/.claude`.
const kClaudeSharedItems = ['CLAUDE.md', 'commands', 'skills', 'agents'];

/// Writes agent [a]'s config for [t] into [dir]. Refuses (StateError,
/// nothing written) when [dir] is, or resolves through a symlink to, a
/// place under one of [guardedRoots] (the user's real agent configs).
/// [claudeSourceDir]: the user's Claude folder, linked into full Claude's.
Future<void> writeLocalConfig(
  LocalAgent a,
  LocalTarget t,
  String dir, {
  required List<String> guardedRoots,
  String? claudeSourceDir,
}) async {
  _refuseGuarded(dir, guardedRoots);
  await Directory(dir).create(recursive: true);
  _refuseGuarded(dir, guardedRoots);
  switch (a) {
    case LocalAgent.pi:
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
    case LocalAgent.opencode:
      await _writeText('$dir/AGENTS.md', kWebToolsPrompt);
      await _writeJson('$dir/opencode.jsonc', {
        ...opencodeConfig(t),
        'instructions': ['$dir/AGENTS.md'],
      });
    case LocalAgent.qwen:
      // QWEN.md in QWEN_HOME is Qwen Code's global instructions file.
      await _writeText('$dir/QWEN.md', kWebToolsPrompt);
      await _writeJson('$dir/settings.json', {
        ...await _readJsonOrEmpty('$dir/settings.json'),
        ...qwenSettings(t),
      });
    case LocalAgent.claude:
      break;
    case LocalAgent.claudeFull:
      await _writeJson('$dir/settings.json', {
        ...await _readJsonOrEmpty('$dir/settings.json'),
        'apiKeyHelper': 'echo local',
      });
      // Skip Claude Code's first-run screens in this fresh folder. A link
      // planted here is dropped first, so nothing is written through it.
      if (FileSystemEntity.isLinkSync('$dir/.claude.json')) {
        await Link('$dir/.claude.json').delete();
      }
      final state = await _readJsonOrEmpty('$dir/.claude.json');
      if (state['hasCompletedOnboarding'] != true) {
        await _writeJson('$dir/.claude.json', {
          ...state,
          'hasCompletedOnboarding': true,
        });
      }
      final src = claudeSourceDir;
      if (src != null) {
        for (final n in kClaudeSharedItems) {
          await _copyShared('$src/$n', '$dir/$n');
        }
      }
  }
}

/// Marks [cwd] as not trusted for Qwen Code: no trust prompt, and the
/// project's own `.qwen/settings.json` stays ignored.
Future<void> writeQwenTrust(String dir, String cwd) =>
    _writeJson('$dir/trustedFolders.json', {cwd: 'DO_NOT_TRUST'});

/// [path]'s JSON object; {} when missing, corrupt, or a link (never read
/// through a link someone planted in the app's folder).
Future<Map<String, dynamic>> _readJsonOrEmpty(String path) async {
  if (FileSystemEntity.isLinkSync(path)) return {};
  try {
    final v = jsonDecode(await File(path).readAsString());
    if (v is Map) return Map<String, dynamic>.from(v);
  } on Object {
    // missing or corrupt: start over
  }
  return {};
}

/// Replaces [dest] (in the app's own folder) by a fresh copy of [source],
/// links in [source] followed. A link at [dest] is removed, never followed;
/// a missing [source] leaves no copy.
Future<void> _copyShared(String source, String dest) async {
  switch (FileSystemEntity.typeSync(dest, followLinks: false)) {
    case FileSystemEntityType.link:
      await Link(dest).delete();
    case FileSystemEntityType.directory:
      await Directory(dest).delete(recursive: true);
    case FileSystemEntityType.notFound:
      break;
    default:
      await File(dest).delete();
  }
  switch (FileSystemEntity.typeSync(source)) {
    case FileSystemEntityType.file:
      await File(source).copy(dest);
    case FileSystemEntityType.directory:
      await _copyDir(source, dest, 0);
    default:
      break;
  }
}

Future<void> _copyDir(String src, String dst, int depth) async {
  if (depth > 16) return; // a link loop in the source
  await Directory(dst).create();
  await for (final e in Directory(src).list(followLinks: false)) {
    final to = '$dst/${p.basename(e.path)}';
    switch (FileSystemEntity.typeSync(e.path)) {
      case FileSystemEntityType.directory:
        await _copyDir(e.path, to, depth + 1);
      case FileSystemEntityType.file:
        await File(e.path).copy(to);
      default:
        break; // broken link, socket…
    }
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
