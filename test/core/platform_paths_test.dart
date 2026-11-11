import 'dart:io';

import 'package:ai_app/core/launch.dart' show agentPathFor, kMacExtraBinDirs;
import 'package:ai_app/core/platform_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('homeDir uses HOME, else USERPROFILE on Windows', () {
    expect(homeDir({'HOME': '/h'}, HostOs.linux), '/h');
    expect(homeDir({'HOME': '/Users/c'}, HostOs.macos), '/Users/c');
    expect(
      homeDir({'USERPROFILE': r'C:\Users\c'}, HostOs.windows),
      r'C:\Users\c',
    );
    expect(
      homeDir({'HOME': '/x', 'USERPROFILE': r'C:\Users\c'}, HostOs.windows),
      '/x',
    );
  });

  test('pathSep', () {
    expect(pathSep(HostOs.linux), ':');
    expect(pathSep(HostOs.macos), ':');
    expect(pathSep(HostOs.windows), ';');
  });

  test('dataHome and configHome per platform', () {
    expect(dataHome({'HOME': '/h'}, HostOs.linux), '/h/.local/share');
    expect(dataHome({'HOME': '/h', 'XDG_DATA_HOME': '/x'}, HostOs.linux), '/x');
    expect(configHome({'HOME': '/h'}, HostOs.linux), '/h/.config');
    expect(
      configHome({'HOME': '/h', 'XDG_CONFIG_HOME': '/c'}, HostOs.linux),
      '/c',
    );
    expect(
      dataHome({'HOME': '/Users/c'}, HostOs.macos),
      '/Users/c/Library/Application Support',
    );
    expect(
      configHome({'HOME': '/Users/c'}, HostOs.macos),
      '/Users/c/Library/Application Support',
    );
    expect(
      dataHome({
        'USERPROFILE': r'C:\Users\c',
        'LOCALAPPDATA': r'C:\Users\c\AppData\Local',
      }, HostOs.windows),
      r'C:\Users\c\AppData\Local',
    );
    expect(
      configHome({
        'USERPROFILE': r'C:\Users\c',
        'APPDATA': r'C:\Users\c\AppData\Roaming',
      }, HostOs.windows),
      r'C:\Users\c\AppData\Roaming',
    );
  });

  test('openUrlCommand per platform', () {
    expect(openUrlCommand('https://x', HostOs.linux), [
      'xdg-open',
      'https://x',
    ]);
    expect(openUrlCommand('https://x', HostOs.macos), ['open', 'https://x']);
    expect(openUrlCommand('https://x', HostOs.windows), [
      'rundll32',
      'url.dll,FileProtocolHandler',
      'https://x',
    ]);
  });

  test('ssh ControlMaster is POSIX-only', () {
    expect(supportsSshControlMaster(HostOs.linux), isTrue);
    expect(supportsSshControlMaster(HostOs.macos), isTrue);
    expect(supportsSshControlMaster(HostOs.windows), isFalse);
  });

  group('whichOn', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('aiapp_which_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('POSIX needs the execute bit and splits on :', () {
      final a = Directory('${tmp.path}/a')..createSync();
      final b = Directory('${tmp.path}/b')..createSync();
      File('${a.path}/pi').writeAsStringSync('x');
      File('${b.path}/pi')
        ..writeAsStringSync('x')
        ..createSync();
      Process.runSync('chmod', ['+x', '${b.path}/pi']);
      expect(
        whichOn('pi', {'PATH': '${a.path}:${b.path}'}, HostOs.linux),
        '${b.path}/pi',
      );
      expect(whichOn('nope', {'PATH': a.path}, HostOs.linux), isNull);
    });

    test('Windows tries PATHEXT, splits on ; and ignores mode bits', () {
      final a = Directory('${tmp.path}/a')..createSync();
      final b = Directory('${tmp.path}/b')..createSync();
      File('${b.path}/claude.cmd').writeAsStringSync('@echo off');
      final env = {
        'PATH': '${a.path};${b.path}',
        'PATHEXT': '.COM;.EXE;.BAT;.CMD',
      };
      final found = whichOn('claude', env, HostOs.windows);
      expect(found, isNotNull);
      expect(found!.toLowerCase(), '${b.path}/claude.cmd'.toLowerCase());
      expect(
        whichOn('claude', {'PATH': b.path}, HostOs.windows),
        isNotNull,
        reason: 'default PATHEXT',
      );
    });
  });

  test('agentPath on Windows adds the npm folder and joins with ;', () {
    final tmp = Directory.systemTemp.createTempSync('aiapp_ap_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Directory('${tmp.path}/Roaming/npm').createSync(recursive: true);
    final p = agentPathFor(
      {'PATH': r'C:\Windows;C:\Tools', 'APPDATA': '${tmp.path}/Roaming'},
      tmp.path,
      HostOs.windows,
    );
    expect(p.split(';'), [
      r'C:\Windows',
      r'C:\Tools',
      '${tmp.path}/Roaming/npm',
    ]);
  });

  test('agentPath on macOS adds Homebrew folders that exist', () {
    final p = agentPathFor(
      {'PATH': '/usr/bin:/bin'},
      '/nonexistent-home',
      HostOs.macos,
    );
    final parts = p.split(':');
    expect(parts.take(2), ['/usr/bin', '/bin']);
    for (final d in parts.skip(2)) {
      expect(['/opt/homebrew/bin', '/usr/local/bin'], contains(d));
    }
    expect(kMacExtraBinDirs, ['/opt/homebrew/bin', '/usr/local/bin']);
  });

  test('currentOs matches the test machine', () {
    expect(
      currentOs(),
      Platform.isWindows
          ? HostOs.windows
          : Platform.isMacOS
          ? HostOs.macos
          : HostOs.linux,
    );
  });
}
