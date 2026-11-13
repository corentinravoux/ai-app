import 'dart:io';

import 'package:crypto/crypto.dart';

/// Hashes the user's real agent config files so the app can prove a
/// configure run left them untouched.
class RealConfigGuard {
  RealConfigGuard(this.paths);

  final List<String> paths;

  /// Settings of every Claude home in [claudeDirs] (default `~/.claude`)
  /// and the files alcf-ai or a local agent would write in the real home.
  static List<String> defaultPaths(
    String realHome, [
    List<String>? claudeDirs,
  ]) => [
    for (final d in claudeDirs ?? ['$realHome/.claude']) '$d/settings.json',
    '$realHome/.codex/config.toml',
    '$realHome/.pi/agent/models.json',
    '$realHome/.pi/agent/settings.json',
    '$realHome/.config/opencode/opencode.jsonc',
    '$realHome/.qwen/settings.json',
  ];

  /// sha256 per path (through symlinks); null for a missing file.
  Future<Map<String, String?>> snapshot() async => {
    for (final path in paths) path: await _hash(path),
  };

  /// Paths whose content, existence or absence changed since [before].
  Future<List<String>> changedSince(Map<String, String?> before) async {
    final now = await snapshot();
    return [
      for (final path in paths)
        if (now[path] != before[path]) path,
    ];
  }

  static Future<String?> _hash(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    return sha256.convert(await f.readAsBytes()).toString();
  }
}
