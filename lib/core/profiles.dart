import 'dart:io';

import 'agents.dart';

/// Where a profile's requests go: ALCF, a native Claude account, or a
/// model host of the user's own (llm-host).
enum Backend { alcf, native, local }

/// One entry in the sidebar: an agent plus where its config lives.
class Profile {
  const Profile({
    required this.id,
    required this.label,
    required this.kind,
    required this.backend,
    this.nativeConfigDir,
    this.hostId,
  });

  final String id;
  final String label;
  final AgentKind kind;
  final Backend backend;

  /// For native Claude profiles: the existing Claude home, launch-only.
  final String? nativeConfigDir;

  /// For local profiles: the model host's id (hosts.dart).
  final String? hostId;

  bool get isAlcf => backend == Backend.alcf;
  bool get isNative => backend == Backend.native;
  bool get isLocal => backend == Backend.local;
}

/// A Claude Code home (config dir) the user is logged in with, launched
/// as is, never configured by the app.
class ClaudeAccount {
  const ClaudeAccount(this.id, this.label, this.dir);

  final String id;
  final String label;
  final String dir;
}

/// `~/.claude` (Claude Code's default home), then every `~/.claude-<name>`
/// folder holding a login (`.credentials.json`), as made by
/// `CLAUDE_CONFIG_DIR=~/.claude-<name> claude`. Folders of other tools
/// such as `~/.claude-mem` have no login and are left out.
List<ClaudeAccount> detectClaudeAccounts(String realHome) {
  final found = <ClaudeAccount>[
    ClaudeAccount(
      'claude-default',
      'Claude · your account',
      '$realHome/.claude',
    ),
  ];
  final others = <String>[];
  try {
    for (final e in Directory(realHome).listSync(followLinks: false)) {
      final name = e.path.split('/').last;
      if (name.startsWith('.claude-') &&
          File('${e.path}/.credentials.json').existsSync()) {
        others.add(name.substring('.claude-'.length));
      }
    }
  } on FileSystemException {
    // Unreadable home: only the default account.
  }
  others.sort();
  for (final n in others) {
    found.add(
      ClaudeAccount('claude-$n', 'Claude · $n', '$realHome/.claude-$n'),
    );
  }
  return found;
}

/// The ALCF profiles, then one native profile per Claude account
/// ([accounts], or [detectClaudeAccounts] when null).
List<Profile> defaultProfiles(
  String realHome, {
  List<ClaudeAccount>? accounts,
}) => [
  const Profile(
    id: 'claude-alcf',
    label: 'Claude · ALCF',
    kind: AgentKind.claude,
    backend: Backend.alcf,
  ),
  const Profile(
    id: 'pi-alcf',
    label: 'Pi · ALCF',
    kind: AgentKind.pi,
    backend: Backend.alcf,
  ),
  const Profile(
    id: 'codex-alcf',
    label: 'Codex · ALCF',
    kind: AgentKind.codex,
    backend: Backend.alcf,
  ),
  const Profile(
    id: 'opencode-alcf',
    label: 'OpenCode · ALCF',
    kind: AgentKind.opencode,
    backend: Backend.alcf,
  ),
  for (final a in accounts ?? detectClaudeAccounts(realHome))
    Profile(
      id: a.id,
      label: a.label,
      kind: AgentKind.claude,
      backend: Backend.native,
      nativeConfigDir: a.dir,
    ),
];
