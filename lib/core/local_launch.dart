import 'agents.dart';
import 'host_client.dart';
import 'hosts.dart';
import 'launch.dart';
import 'local_config.dart';
import 'platform_paths.dart';
import 'profiles.dart';

/// Every [LocalAgent] for every model host, in that order.
/// Ids start with `local-`: `<agent>-<host id>` alone collides with native
/// and ALCF ids for hosts named "default", "alcf" or like a Claude account.
List<Profile> localProfiles(List<ModelHost> hosts) => [
  for (final h in hosts)
    for (final a in LocalAgent.values)
      Profile(
        id: localProfileId(a, h.id),
        label: '${a.label} · ${h.label}',
        kind: a.kind,
        backend: Backend.local,
        hostId: h.id,
        localAgent: a,
      ),
];

String localProfileId(LocalAgent a, String hostId) =>
    'local-${a.dirName}-$hostId';

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

/// Whether a variable of the window AI App was started from is dropped
/// from local tabs: other agents' routing, cloud-provider switches, and the
/// OpenAI / Qwen / Gemini settings that Qwen Code would read first.
bool isLocalStripped(String key) =>
    kStrippedEnvKeys.contains(key) ||
    kLocalStrippedEnvKeys.contains(key) ||
    key.startsWith('ANTHROPIC_') ||
    key.startsWith('OPENAI_') ||
    key.startsWith('QWEN_') ||
    key.startsWith('GEMINI_');

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

/// Whether agent [a] can open on host [h] given its status [s] (null:
/// unreachable), and if so against what.
LocalReadiness localReadiness(LocalAgent a, ModelHost h, HostStatus? s) {
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
  // Agents are pointed at the saved port: a server on another one (llm-host
  // installed with --port, the host saved with the default) is not reachable.
  if (s.port != h.serverPort) {
    return LocalBlocked(
      'The model on $l serves on port ${s.port}, '
      'but the host is set to ${h.serverPort}: edit the host',
    );
  }
  final ctx = s.ctx;
  final alias = s.alias ?? s.recipe;
  if (ctx == null || alias == null) {
    return LocalBlocked('$l did not report its model and window');
  }
  final min = a.minCtx;
  if (ctx < min) {
    return LocalBlocked(
      '${a.longName} needs a $min-token window; '
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
  String? claudeSourceDir,
}) async {
  final a = p.localAgent;
  if (!p.isLocal || a == null || p.hostId != host.id) {
    throw ArgumentError('${p.id} is not a profile of host ${host.id}');
  }
  final dir = localDir(dataRoot, host.id, a);
  await writeLocalConfig(
    a,
    target,
    dir,
    guardedRoots: guardedRoots,
    claudeSourceDir: claudeSourceDir,
  );
  final full = a == LocalAgent.claudeFull;
  final env = {
    for (final e in parentEnv.entries)
      if (!isLocalStripped(e.key)) e.key: e.value,
    ...overrideEnv(a, dir),
    if (a.kind == AgentKind.claude) ...claudeLocalEnv(target, dir, full: full),
    'PATH': [
      toolsBinDir,
      if ((parentEnv['PATH'] ?? '').isNotEmpty) parentEnv['PATH']!,
    ].join(pathSep(currentOs())),
    'TERM': 'xterm-256color',
  };
  return LaunchSpec(
    executable: exePath,
    args: a.kind == AgentKind.claude ? claudeLocalArgs(full: full) : const [],
    env: env,
    cwd: cwd,
  );
}
