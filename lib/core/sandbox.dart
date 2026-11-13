import 'dart:io';

import 'package:path/path.dart' as p;

import 'agents.dart';

/// The app-owned fake HOME that `alcf-ai agent configure` writes into.
///
/// Agents are launched with the real HOME; only the per-agent override
/// variable points here (see [overrideValue]).
class Sandbox {
  Sandbox({required String root, required this.realHome})
    : home = p.normalize(root);

  final String home;
  final String realHome;

  String get claudeDir => '$home/.claude';

  /// Creates the sandbox and links `.globus` so alcf-ai finds the user's
  /// ALCF tokens. Refuses any root inside a real Claude home (`~/.claude*`).
  Future<void> ensure() async {
    if (p.isWithin(realHome, home)) {
      final top = p.split(p.relative(home, from: realHome)).first;
      if (top.startsWith('.claude')) {
        throw StateError(
          'Sandbox root $home is inside ${p.join(realHome, top)}',
        );
      }
    }
    await Directory(home).create(recursive: true);
    final globus = Link('$home/.globus');
    if (!await globus.exists()) {
      await globus.create('$realHome/.globus');
    }
  }

  /// Value of the agent's config-location variable at launch time.
  String overrideValue(AgentKind k) => switch (k) {
    AgentKind.claude => claudeDir,
    AgentKind.codex => '$home/.codex',
    AgentKind.pi => '$home/.pi/agent',
    AgentKind.opencode => '$home/.config/opencode/opencode.jsonc',
    // Qwen Code is only offered on model hosts, never on ALCF.
    AgentKind.qwen => '$home/.qwen',
  };

  /// True once alcf-ai has written this agent's config into the sandbox.
  bool isConfigured(AgentKind k) => switch (k) {
    AgentKind.claude => _contains(
      '$claudeDir/settings.json',
      'ANTHROPIC_BASE_URL',
    ),
    AgentKind.pi => _contains(
      '$home/.pi/agent/models.json',
      'alcf-inference-service-',
    ),
    AgentKind.codex => _contains(
      '$home/.codex/config.toml',
      'alcf-inference-service-',
    ),
    AgentKind.opencode => _contains(
      overrideValue(k),
      'alcf-inference-service-',
    ),
    AgentKind.qwen => false,
  };

  /// True when `install.sh --alcf` has linked the shared CLAUDE.md.
  bool get sharedConfigLinked =>
      FileSystemEntity.isLinkSync('$claudeDir/CLAUDE.md');

  /// Links (or unlinks) `<claudeDir>/plugins` to the real plugin folder.
  /// Never touches the target folder.
  Future<void> setPluginsLink(bool on) async {
    final link = Link('$claudeDir/plugins');
    final exists = FileSystemEntity.isLinkSync(link.path);
    if (on && !exists) {
      await Directory(claudeDir).create(recursive: true);
      await link.create('$realHome/.claude/plugins');
    } else if (!on && exists) {
      await link.delete();
    }
  }

  static bool _contains(String path, String needle) {
    final f = File(path);
    return f.existsSync() && f.readAsStringSync().contains(needle);
  }
}
