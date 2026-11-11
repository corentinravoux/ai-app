import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'app/app_state.dart';
import 'core/alcf_cli.dart';
import 'core/app_store.dart';
import 'core/guard.dart';
import 'core/host_client.dart';
import 'core/hosts.dart';
import 'core/launch.dart';
import 'core/platform_paths.dart';
import 'core/profiles.dart';
import 'core/pty.dart';
import 'core/runner.dart';
import 'core/sandbox.dart';
import 'core/tunnel.dart';
import 'ui/configure_dialog.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  final os = currentOs();
  final realHome = homeDir(Platform.environment, os);
  // Agents installed in ~/.opencode/bin and the like are often missing from
  // a desktop session's PATH: add them for lookup, configure and launch.
  final env = {
    ...Platform.environment,
    'PATH': agentPath(Platform.environment, realHome),
  };
  final sandbox = Sandbox(
    root: '$realHome/.local/share/alcfai/home',
    realHome: realHome,
  );
  final store = AppStore('$realHome/.local/share/alcfai/state.json');
  await store.load();
  final accounts = store.accounts ?? detectClaudeAccounts(realHome);

  // alcf-ai is redirected by setting HOME and finds its login through a
  // symlink: both POSIX-only, so ALCF is off on Windows.
  final alcfExe = os == HostOs.windows ? null : whichOnPath('alcf-ai', env);
  final tokensExe = os == HostOs.windows
      ? null
      : whichOnPath('alcf-tokens', env);

  final alcf = (alcfExe == null || tokensExe == null)
      ? null
      : AlcfCli(
          runner: const IoRunner(),
          sandbox: sandbox,
          guard: RealConfigGuard(
            RealConfigGuard.defaultPaths(realHome, [
              for (final a in accounts) a.dir,
            ]),
          ),
          alcfExe: alcfExe,
          tokensExe: tokensExe,
          uvCacheDir: _uvCacheDir(env, realHome),
          sharedSettingsPath: '$realHome/.claude/settings.json',
          parentEnv: env,
        );

  // Model hosts (docs/hosts.md): this machine when llm-host is installed,
  // plus the hosts added in the app.
  final dataRoot = '${dataHome(Platform.environment, os)}/ai-app';
  final registry = HostRegistry(
    '${configHome(Platform.environment, os)}/ai-app/hosts.json',
  );
  var hosts = await registry.load();
  if (hosts.isEmpty) {
    final here = defaultLocalHost((exe) => whichOnPath(exe, env));
    if (here != null) {
      hosts = [here];
      await registry.save(hosts);
    }
  }
  final sshExe = whichOnPath('ssh', env);
  final controlDir = '$dataRoot/ssh';
  await Directory(controlDir).create(recursive: true);
  if (os != HostOs.windows) await Process.run('chmod', ['700', controlDir]);
  final claudeDirs = [for (final a in accounts) a.dir];

  // New sessions start in the last folder used, else the home folder.
  final defaultCwd =
      store.recentFolders.where((f) => Directory(f).existsSync()).firstOrNull ??
      realHome;

  final state = AppState(
    profiles: defaultProfiles(realHome, accounts: accounts),
    which: (exe) => whichOnPath(exe, env),
    sandbox: sandbox,
    alcf: alcf,
    start: startFlutterPty,
    parentEnv: env,
    defaultCwd: defaultCwd,
    store: store,
    hosts: hosts,
    registry: registry,
    hostClient: HostClient(
      runner: const IoRunner(),
      sshExe: sshExe ?? 'ssh',
      controlDir: controlDir,
      controlMaster: supportsSshControlMaster(os),
    ),
    tunnels: TunnelManager(
      start: startIoProc,
      probe: tcpProbe,
      sshExe: sshExe ?? 'ssh',
    ),
    dataRoot: dataRoot,
    sshAvailable: sshExe != null,
    alcfMissing: os == HostOs.windows
        ? 'ALCF needs Linux or macOS'
        : 'alcf-ai is not installed',
    guardPaths: RealConfigGuard.defaultPaths(realHome, claudeDirs),
    guardedRoots: [
      '$realHome/.claude',
      ...claudeDirs,
      '$realHome/.pi',
      '$realHome/.config/opencode',
      '$realHome/.codex',
      '$realHome/Software/claude_config/claude',
    ],
  );

  runApp(AiApp(state: state, onConfigure: showConfigureDialog));
  sandbox.ensure().then((_) => state.refresh());
  state.startLoginChecks();
  state.startHostPolling();
  // Close the ssh forwards when the window closes, or they outlive the app
  // and hold their local ports.
  AppLifecycleListener(
    onExitRequested: () async {
      await state.tunnels?.dispose();
      return AppExitResponse.exit;
    },
  );
}

String _uvCacheDir(Map<String, String> env, String realHome) {
  final fromEnv = env['UV_CACHE_DIR'];
  if (fromEnv != null) return fromEnv;
  final uv = whichOnPath('uv', env);
  if (uv != null) {
    try {
      final r = Process.runSync(uv, ['cache', 'dir']);
      if (r.exitCode == 0) return '${r.stdout}'.trim();
    } on ProcessException {
      // fall through to the default
    }
  }
  return '$realHome/.cache/uv';
}

class AiApp extends StatelessWidget {
  const AiApp({super.key, required this.state, this.onConfigure});

  final AppState state;
  final ConfigureAction? onConfigure;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AI App',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: HomePage(state: state, onConfigure: onConfigure),
  );
}
