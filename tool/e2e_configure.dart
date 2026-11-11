// End-to-end check of the configure path against the real alcf-ai.
// Writes only into ~/.local/share/alcfai/home; prints the guard verdict.
//
//   dart run tool/e2e_configure.dart claude pi
import 'dart:io';

import 'package:ai_app/core/agents.dart';
import 'package:ai_app/core/alcf_cli.dart';
import 'package:ai_app/core/guard.dart';
import 'package:ai_app/core/launch.dart';
import 'package:ai_app/core/runner.dart';
import 'package:ai_app/core/sandbox.dart';

Future<void> main(List<String> agents) async {
  final env = Platform.environment;
  final home = env['HOME']!;
  final sandbox = Sandbox(
    root: '$home/.local/share/alcfai/home',
    realHome: home,
  );
  final cli = AlcfCli(
    runner: const IoRunner(),
    sandbox: sandbox,
    guard: RealConfigGuard(RealConfigGuard.defaultPaths(home)),
    alcfExe: whichOnPath('alcf-ai', env)!,
    tokensExe: whichOnPath('alcf-tokens', env)!,
    uvCacheDir: '$home/.cache/uv',
    sharedSettingsPath: '$home/.claude/settings.json',
    parentEnv: env,
  );
  for (final name in agents) {
    final kind = AgentKind.values.byName(name);
    final r = await cli.configure(kind);
    final verdict = switch (r) {
      ConfigureOk() => 'ok',
      LoginNeeded() => 'login needed',
      ConfigureFailed(:final message) => 'failed: $message',
      RealConfigTouched(:final paths) => 'REAL CONFIG TOUCHED: $paths',
    };
    stdout.writeln('$name: $verdict; configured=${sandbox.isConfigured(kind)}');
  }
}
