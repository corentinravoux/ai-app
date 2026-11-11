import 'dart:io';

/// The desktop the app runs on. The one place that asks `Platform.isX`:
/// everything else takes a [HostOs], so it is tested on every OS from Linux.
enum HostOs { linux, macos, windows }

HostOs currentOs() => Platform.isWindows
    ? HostOs.windows
    : Platform.isMacOS
    ? HostOs.macos
    : HostOs.linux;

/// The user's home folder.
String homeDir(Map<String, String> env, HostOs os) =>
    env['HOME'] ??
    (os == HostOs.windows ? env['USERPROFILE'] : null) ??
    (throw StateError('no home folder in the environment'));

/// Separator of PATH entries.
String pathSep(HostOs os) => os == HostOs.windows ? ';' : ':';

/// Where the app keeps its data (`~/.local/share` on Linux).
String dataHome(Map<String, String> env, HostOs os) => switch (os) {
  HostOs.linux => env['XDG_DATA_HOME'] ?? '${homeDir(env, os)}/.local/share',
  HostOs.macos => '${homeDir(env, os)}/Library/Application Support',
  HostOs.windows =>
    env['LOCALAPPDATA'] ?? '${homeDir(env, os)}\\AppData\\Local',
};

/// Where the app keeps its settings (`~/.config` on Linux).
String configHome(Map<String, String> env, HostOs os) => switch (os) {
  HostOs.linux => env['XDG_CONFIG_HOME'] ?? '${homeDir(env, os)}/.config',
  HostOs.macos => '${homeDir(env, os)}/Library/Application Support',
  HostOs.windows => env['APPDATA'] ?? '${homeDir(env, os)}\\AppData\\Roaming',
};

/// Command that opens [url] in the default browser.
List<String> openUrlCommand(String url, HostOs os) => switch (os) {
  HostOs.linux => ['xdg-open', url],
  HostOs.macos => ['open', url],
  HostOs.windows => ['rundll32', 'url.dll,FileProtocolHandler', url],
};

/// OpenSSH for Windows has no ControlMaster (shared connections).
bool supportsSshControlMaster(HostOs os) => os != HostOs.windows;

/// Full path of [exe] found on `env['PATH']`, or null. POSIX: a file with an
/// execute bit. Windows: also tries each `PATHEXT` extension (`.cmd` shims
/// from npm), without mode bits.
String? whichOn(String exe, Map<String, String> env, HostOs os) {
  final names = <String>[exe];
  if (os == HostOs.windows) {
    final exts = (env['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
        .split(';')
        .where((e) => e.isNotEmpty);
    final lower = exe.toLowerCase();
    if (!exts.any((e) => lower.endsWith(e.toLowerCase()))) {
      names
        ..clear()
        ..addAll([
          for (final e in exts) ...{'$exe${e.toLowerCase()}', '$exe$e'},
        ]);
    }
  }
  for (final dir in (env['PATH'] ?? '').split(pathSep(os))) {
    if (dir.isEmpty) continue;
    for (final n in names) {
      final f = File('$dir/$n');
      if (!f.existsSync()) continue;
      if (os == HostOs.windows || f.statSync().mode & 0x49 != 0) return f.path;
    }
  }
  return null;
}
