import 'agents.dart';
import 'host_client.dart';
import 'hosts.dart';
import 'launch.dart';
import 'local_config.dart';
import 'platform_paths.dart';
import 'profiles.dart';

/// Pi, OpenCode and Claude Code for every model host, in that order.
List<Profile> localProfiles(List<ModelHost> hosts) => [
  for (final h in hosts)
    for (final k in kLocalAgents)
      Profile(
        id: '${k.name}-${h.id}',
        label: '${_short(k)} · ${h.label}',
        kind: k,
        backend: Backend.local,
        hostId: h.id,
      ),
];

/// Removed from local tabs on top of [kStrippedEnvKeys] and every
/// `ANTHROPIC_*`: switches that send Claude Code to a cloud provider, and
/// OpenCode config injected through the environment.
/// Native tabs keep them (a user may run their account through Bedrock).
const kLocalStrippedEnvKeys = [
  'CLAUDE_CODE_USE_BEDROCK',
  'CLAUDE_CODE_USE_VERTEX',
  'CLAUDE_CODE_USE_FOUNDRY',
  'AWS_BEARER_TOKEN_BEDROCK',
  'ANTHROPIC_VERTEX_PROJECT_ID',
  // OpenCode merges these over OPENCODE_CONFIG: a shell that set them must
  // not reroute a local tab.
  'OPENCODE_CONFIG_CONTENT',
  'OPENCODE_CONFIG_DIR',
];

String _short(AgentKind k) => switch (k) {
  AgentKind.pi => 'Pi',
  AgentKind.opencode => 'OpenCode',
  AgentKind.claude => 'Claude',
  AgentKind.codex => 'Codex',
};

String _long(AgentKind k) => k == AgentKind.claude ? 'Claude Code' : _short(k);

sealed class LocalReadiness {
  const LocalReadiness();
}

class LocalReady extends LocalReadiness {
  const LocalReady(this.target);
  final LocalTarget target;
}

class LocalBlocked extends LocalReadiness {
  const LocalBlocked(this.reason);

  /// One sentence for the sidebar and the tooltip.
  final String reason;
}

/// Whether agent [k] can open on host [h] given its status [s] (null:
/// unreachable), and if so against what.
LocalReadiness localReadiness(AgentKind k, ModelHost h, HostStatus? s) {
  final l = h.label;
  if (s == null) return LocalBlocked('$l is unreachable');
  switch (s.state) {
    case ServerState.stopped:
      return LocalBlocked('No model is running on $l: start one');
    case ServerState.loading:
      return LocalBlocked('$l is loading ${s.label ?? s.recipe ?? 'a model'}…');
    case ServerState.foreign:
      return LocalBlocked(
        'A llama-server not started by AI App is running on $l',
      );
    case ServerState.error:
      return LocalBlocked('The model failed to start on $l: open the log');
    case ServerState.ready:
      break;
  }
  final ctx = s.ctx;
  final alias = s.alias ?? s.recipe;
  if (ctx == null || alias == null) {
    return LocalBlocked('$l did not report its model and window');
  }
  final min = kMinCtx[k]!;
  if (ctx < min) {
    return LocalBlocked(
      '${_long(k)} needs a $min-token window; '
      '${s.label ?? alias} has $ctx',
    );
  }
  return LocalReady(
    LocalTarget(
      baseUrl: h.baseUrl,
      alias: alias,
      hostLabel: l,
      ctx: ctx,
      maxOutput: s.maxOutput ?? (ctx ~/ 8),
      vision: s.vision,
    ),
  );
}

/// Writes the agent's config for [target], then returns how to start it:
/// the parent environment minus every other routing variable, plus this
/// profile's own override, with [toolsBinDir] (webread) first on PATH.
Future<LaunchSpec> buildLocalLaunch(
  Profile p, {
  required ModelHost host,
  required LocalTarget target,
  required String dataRoot,
  required Map<String, String> parentEnv,
  required String exePath,
  required String cwd,
  required String toolsBinDir,
  required List<String> guardedRoots,
}) async {
  if (!p.isLocal || p.hostId != host.id) {
    throw ArgumentError('${p.id} is not a profile of host ${host.id}');
  }
  final dir = localDir(dataRoot, host.id, p.kind);
  await writeLocalConfig(p.kind, target, dir, guardedRoots: guardedRoots);
  final env = {
    for (final e in parentEnv.entries)
      if (!kStrippedEnvKeys.contains(e.key) &&
          !kLocalStrippedEnvKeys.contains(e.key) &&
          !e.key.startsWith('ANTHROPIC_'))
        e.key: e.value,
    ...overrideEnv(p.kind, dir),
    if (p.kind == AgentKind.claude) ...claudeLocalEnv(target, dir),
    'PATH': [
      toolsBinDir,
      if ((parentEnv['PATH'] ?? '').isNotEmpty) parentEnv['PATH']!,
    ].join(pathSep(currentOs())),
    'TERM': 'xterm-256color',
  };
  return LaunchSpec(
    executable: exePath,
    args: p.kind == AgentKind.claude ? claudeLocalArgs() : const [],
    env: env,
    cwd: cwd,
  );
}
