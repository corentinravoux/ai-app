import 'dart:convert';
import 'dart:io';

import 'agents.dart';
import 'app_store.dart';
import 'platform_paths.dart';
import 'profiles.dart';
import 'sandbox.dart';

typedef Which = String? Function(String exe);

/// Removed from the parent environment before every launch, together with
/// every `ANTHROPIC_*` key, so no tab inherits another account's routing.
const kStrippedEnvKeys = [
  'CLAUDE_CONFIG_DIR',
  'CODEX_HOME',
  'PI_CODING_AGENT_DIR',
  'OPENCODE_CONFIG',
  'CLAUDE_CODE_OAUTH_TOKEN',
  'ALCF_SESSION_ID',
];

class LaunchSpec {
  const LaunchSpec({
    required this.executable,
    required this.args,
    required this.env,
    required this.cwd,
  });

  final String executable;
  final List<String> args;

  /// The complete environment of the child (not merged with the parent).
  final Map<String, String> env;
  final String cwd;
}

String? whichOnPath(String exe, Map<String, String> env) =>
    whichOn(exe, env, currentOs());

LaunchSpec buildLaunch(
  Profile p, {
  required Sandbox sandbox,
  required Map<String, String> parentEnv,
  required String exePath,
  required String cwd,
  required String sessionId,
  List<String> args = const [],
}) {
  final env = {
    for (final e in parentEnv.entries)
      if (!kStrippedEnvKeys.contains(e.key) && !e.key.startsWith('ANTHROPIC_'))
        e.key: e.value,
  };
  if (p.isLocal) {
    throw ArgumentError('local profiles launch through buildLocalLaunch');
  }
  if (p.isAlcf) {
    env['ALCF_SESSION_ID'] = sessionId;
    final key = switch (p.kind) {
      AgentKind.claude => 'CLAUDE_CONFIG_DIR',
      AgentKind.codex => 'CODEX_HOME',
      AgentKind.pi => 'PI_CODING_AGENT_DIR',
      AgentKind.opencode => 'OPENCODE_CONFIG',
    };
    env[key] = sandbox.overrideValue(p.kind);
  } else {
    env['CLAUDE_CONFIG_DIR'] = p.nativeConfigDir!;
  }
  env['TERM'] = 'xterm-256color';
  return LaunchSpec(executable: exePath, args: args, env: env, cwd: cwd);
}

/// Folders agent installers use but a desktop session's PATH often lacks
/// (they are added in ~/.bashrc, which a menu launch never reads).
const kAgentBinDirs = [
  '.local/bin',
  'opt/node/bin',
  '.opencode/bin',
  '.pi/agent/bin',
  '.bun/bin',
  '.npm-global/bin',
  '.cargo/bin',
];

/// The parent PATH followed by every existing [kAgentBinDirs] folder not
/// already on it.
String agentPath(Map<String, String> env, String realHome) =>
    agentPathFor(env, realHome, currentOs());

/// Homebrew's folders: an app started from Finder gets only
/// /usr/bin:/bin:/usr/sbin:/sbin, without node, python3 ≥ 3.11 or ssh-agent
/// helpers installed by Homebrew.
const kMacExtraBinDirs = ['/opt/homebrew/bin', '/usr/local/bin'];

/// [agentPath] for a given OS. On Windows npm puts its shims in
/// `%APPDATA%\npm`, which is added too.
String agentPathFor(
  Map<String, String> env,
  String realHome,
  HostOs os, {
  List<String> macExtraDirs = kMacExtraBinDirs,
}) {
  final sep = pathSep(os);
  final dirs = [
    for (final d in (env['PATH'] ?? '').split(sep))
      if (d.isNotEmpty) d,
  ];
  // macOS: Homebrew first, as `brew shellenv` does, so python3 and node are
  // Homebrew's and not Apple's older copies in /usr/bin.
  if (os == HostOs.macos) {
    final brew = [
      for (final d in macExtraDirs)
        if (Directory(d).existsSync()) d,
    ];
    dirs
      ..removeWhere(brew.contains)
      ..insertAll(0, brew);
  }
  final extra = [
    for (final d in kAgentBinDirs) '$realHome/$d',
    if (os == HostOs.windows && env['APPDATA'] != null) '${env['APPDATA']}/npm',
  ];
  for (final full in extra) {
    if (!dirs.contains(full) && Directory(full).existsSync()) dirs.add(full);
  }
  return dirs.join(sep);
}

/// Flags that keep an agent inside what the ALCF gateway accepts.
///
/// Codex 0.165 sends tool types the ALCF responses endpoint rejects with
/// HTTP 400: `namespace` (from the multi_agent feature) and `web_search`.
/// The third one, the freeform apply_patch tool, is set per model in the
/// catalogs and cleared after configure ([clearFreeformApplyPatch]).
List<String> alcfCompatArgs(AgentKind kind) => switch (kind) {
  AgentKind.codex => const [
    '--disable',
    'multi_agent',
    '-c',
    'web_search="disabled"',
  ],
  _ => const [],
};

/// Sets `apply_patch_tool_type` to null in every codex catalog under [dir],
/// so codex stops sending the grammar-format apply_patch tool that the ALCF
/// gateway rejects (codex only accepts "freeform" or null there). Unreadable
/// files are left alone.
Future<void> clearFreeformApplyPatch(String dir) async {
  final d = Directory(dir);
  if (!d.existsSync()) return;
  await for (final f in d.list()) {
    if (f is! File || !f.path.endsWith('.json')) continue;
    try {
      final v = jsonDecode(await f.readAsString());
      var changed = false;
      for (final m in (v as Map)['models'] as List) {
        if (m is Map && m['apply_patch_tool_type'] == 'freeform') {
          m['apply_patch_tool_type'] = null;
          changed = true;
        }
      }
      if (changed) {
        await f.writeAsString(const JsonEncoder.withIndent('  ').convert(v));
      }
    } on Object {
      // Not a catalog we understand.
    }
  }
}

/// Launch arguments that select the remembered cluster and model.
///
/// alcf-ai names providers `alcf-inference-service-<cluster>-<framework>`:
/// pi and opencode take `--model <provider>/<model>`; codex takes the
/// per-model profile alcf-ai writes, `-p alcf-<cluster>-<model>`. Claude
/// needs nothing (configure writes the model into its settings). Empty when
/// nothing matches, so the agent falls back to its own default.
List<String> modelArgs(AgentKind kind, Sandbox sandbox, AgentChoice? choice) {
  if (choice == null) return const [];
  try {
    switch (kind) {
      case AgentKind.claude:
        return const [];
      case AgentKind.codex:
        final name =
            'alcf-${choice.cluster}-${choice.model.replaceAll('/', '-')}';
        return File('${sandbox.home}/.codex/$name.config.toml').existsSync()
            ? ['-p', name]
            : const [];
      case AgentKind.pi:
        final v = _readJson('${sandbox.home}/.pi/agent/models.json');
        return _providerArgs(v['providers'], choice, (models) {
          return models is List &&
              models.any((m) => m is Map && m['id'] == choice.model);
        });
      case AgentKind.opencode:
        final v = _readJson(sandbox.overrideValue(kind));
        return _providerArgs(v['provider'] ?? v['providers'], choice, (models) {
          return models is Map && models.containsKey(choice.model);
        });
    }
  } on Object {
    // No sandbox config yet: let the agent choose.
  }
  return const [];
}

Map _readJson(String path) => jsonDecode(File(path).readAsStringSync()) as Map;

List<String> _providerArgs(
  Object? providers,
  AgentChoice choice,
  bool Function(Object? models) serves,
) {
  if (providers is! Map) return const [];
  for (final e in providers.entries) {
    final key = '${e.key}';
    if (key.startsWith('alcf-inference-service-${choice.cluster}-') &&
        e.value is Map &&
        serves((e.value as Map)['models'])) {
      return ['--model', '$key/${choice.model}'];
    }
  }
  return const [];
}
