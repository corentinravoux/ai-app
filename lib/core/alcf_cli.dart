import 'dart:convert';

import 'agents.dart';
import 'claude_seed.dart';
import 'claude_picker.dart';
import 'guard.dart';
import 'launch.dart';
import 'runner.dart';
import 'sandbox.dart';

/// Clusters offered in the app, default first. Tara has the most capacity
/// (many Muse Spark and Mistral 4 replicas) and needs alcf-ai >= 0.21.
/// Metis is left out: no `/messages` endpoint, and alcf-ai disables it for
/// tool calls.
const kClusters = ['tara', 'minerva', 'sophia'];

/// Models ALCF serves that `alcf-ai agent configure` (0.21) does not
/// allowlist yet on that cluster. Configure adds `--include-experimental`
/// for them, or codex, pi and opencode leave them out. Drop an entry once
/// alcf-ai lists it.
const kNotYetAllowlisted = {
  'tara': {'muse-spark-bf16', 'mistral-large-4'},
};

bool needsExperimental(String cluster, String model) =>
    kNotYetAllowlisted[cluster]?.contains(model) ?? false;

enum ModelStatus { running, queued, offline, unknown }

class AlcfModel {
  const AlcfModel({
    required this.id,
    required this.displayName,
    required this.protocols,
    this.contextTokens,
  });

  final String id;
  final String displayName;
  final List<String> protocols;
  final int? contextTokens;
}

sealed class ConfigureResult {
  const ConfigureResult();
}

class ConfigureOk extends ConfigureResult {
  const ConfigureOk();
}

class LoginNeeded extends ConfigureResult {
  const LoginNeeded();
}

class ConfigureFailed extends ConfigureResult {
  const ConfigureFailed(this.message);
  final String message;
}

class RealConfigTouched extends ConfigureResult {
  const RealConfigTouched(this.paths);
  final List<String> paths;
}

/// One plain line, with the fix, for the errors the ALCF docs list.
String explainError(String stderr) {
  final s = stderr.toLowerCase();
  if (s.contains('identitymismatcherror')) {
    return 'ALCF identity changed: run alcf-tokens clear-tokens, then log in again.';
  }
  if (s.contains('429') || s.contains('too many requests')) {
    return 'ALCF rate limit, wait and retry.';
  }
  if (s.contains('permission denied') ||
      s.contains('401') ||
      s.contains('403')) {
    return 'ALCF refused the token: run alcf-tokens login inference.';
  }
  if (s.contains('timed out') || s.contains('timeout')) {
    return 'No answer from ALCF: the model may be queued: check its status and retry.';
  }
  final lines = stderr
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty);
  return lines.isEmpty ? 'alcf-ai failed without a message.' : lines.last;
}

/// Wraps the `alcf-ai` and `alcf-tokens` CLIs. Configure runs with the
/// sandbox as HOME so alcf-ai can only write there.
class AlcfCli {
  AlcfCli({
    required this.runner,
    required this.sandbox,
    required this.guard,
    required this.alcfExe,
    required this.tokensExe,
    required this.uvCacheDir,
    required this.sharedSettingsPath,
    required this.parentEnv,
  });

  final Runner runner;
  final Sandbox sandbox;
  final RealConfigGuard guard;
  final String alcfExe;
  final String tokensExe;
  final String uvCacheDir;
  final String sharedSettingsPath;
  final Map<String, String> parentEnv;

  List<String> get loginCommand => [tokensExe, 'login', 'inference'];

  /// Parent env without any agent-routing variable.
  Map<String, String> get _cleanEnv => {
    for (final e in parentEnv.entries)
      if (!kStrippedEnvKeys.contains(e.key) && !e.key.startsWith('ANTHROPIC_'))
        e.key: e.value,
  };

  Future<bool> tokenOk() async =>
      (await runner.run(tokensExe, [
        'get-token',
        'inference',
      ], env: _cleanEnv)).exitCode ==
      0;

  Future<List<AlcfModel>> listModels(
    String cluster, {
    AgentKind? forAgent,
  }) async {
    // alcf-ai prints through rich, which wraps long lines at the terminal
    // width, inserting raw newlines inside JSON strings. Ask for wide output,
    // and drop any newline left (outside strings it is only whitespace).
    final r = await runner.run(
      alcfExe,
      ['ls-models', cluster],
      env: {..._cleanEnv, 'COLUMNS': '100000'},
    );
    final List<dynamic> raw;
    try {
      final v = jsonDecode(r.stdout.replaceAll(RegExp(r'[\r\n]'), ' '));
      if (v is! List) return [];
      raw = v;
    } on FormatException {
      return [];
    }
    final models = <AlcfModel>[];
    for (final m in raw.whereType<Map<String, dynamic>>()) {
      final id = m['id'];
      if (id is! String) continue;
      final caps = m['capabilities'] is Map
          ? m['capabilities'] as Map
          : const {};
      final protocols = [
        for (final p in (caps['api_protocols'] as List? ?? const [])) '$p',
      ];
      final ctx = caps['context_window_tokens'];
      models.add(
        AlcfModel(
          id: id,
          displayName: m['display_name'] is String ? m['display_name'] : id,
          protocols: protocols,
          contextTokens: ctx is int ? ctx : null,
        ),
      );
    }
    // Claude speaks the Anthropic messages API; codex (> 0.94) only the
    // responses API, and alcf-ai skips providers without it.
    final needs = switch (forAgent) {
      AgentKind.claude => 'messages',
      AgentKind.codex => 'responses',
      _ => null,
    };
    if (needs != null) {
      return models.where((m) => m.protocols.contains(needs)).toList();
    }
    return models;
  }

  /// Model status from `alcf-ai ls-jobs`, which prints a Python dict repr.
  Future<Map<String, ModelStatus>> modelStatus(String cluster) async {
    final r = await runner.run(alcfExe, ['ls-jobs', cluster], env: _cleanEnv);
    final groups = RegExp(r"'([\w ]+)':\s*\[").allMatches(r.stdout).toList();
    final out = <String, ModelStatus>{};
    for (var i = 0; i < groups.length; i++) {
      final end = i + 1 < groups.length ? groups[i + 1].start : r.stdout.length;
      final body = r.stdout.substring(groups[i].end, end);
      final status = switch (groups[i].group(1)!.toLowerCase()) {
        'running' => ModelStatus.running,
        'queued' || 'starting' || 'pending' => ModelStatus.queued,
        _ => ModelStatus.offline,
      };
      for (final m in RegExp(r"'Models':\s*'([^']+)'").allMatches(body)) {
        out[m.group(1)!] = status;
      }
    }
    return out;
  }

  Future<ConfigureResult> configure(
    AgentKind kind, {
    String model = 'inkling-bf16',
    String cluster = 'minerva',
    bool experimental = false,
    bool includePlugins = false,
    List<String>? claudeModels,
  }) async {
    await sandbox.ensure();
    if (!await tokenOk()) return const LoginNeeded();
    final before = await guard.snapshot();
    if (kind == AgentKind.claude) {
      await writeClaudeSeed(
        sharedSettingsPath: sharedSettingsPath,
        sandboxSettingsPath: '${sandbox.claudeDir}/settings.json',
        includePlugins: includePlugins,
      );
      await sandbox.setPluginsLink(includePlugins);
    }
    final r = await runner.run(
      alcfExe,
      [
        'agent',
        'configure',
        kind.exe,
        '-m',
        model,
        '-c',
        cluster,
        if (experimental || needsExperimental(cluster, model))
          '--include-experimental',
      ],
      env: {..._cleanEnv, 'HOME': sandbox.home, 'UV_CACHE_DIR': uvCacheDir},
    );
    final touched = await guard.changedSince(before);
    if (touched.isNotEmpty) return RealConfigTouched(touched);
    if (r.exitCode != 0) return ConfigureFailed(explainError(r.stderr));
    if (kind == AgentKind.claude && claudeModels != null) {
      await writeClaudePicker(
        '${sandbox.claudeDir}/settings.json',
        claudeModels,
        main: model,
      );
    }
    if (kind == AgentKind.codex) {
      await clearFreeformApplyPatch('${sandbox.home}/.codex/catalogs');
    }
    return const ConfigureOk();
  }
}
