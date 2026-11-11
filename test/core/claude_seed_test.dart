import 'dart:convert';
import 'dart:io';

import 'package:ai_app/core/claude_seed.dart';
import 'package:flutter_test/flutter_test.dart';

const shared = {
  'model': 'opus',
  'hooks': {'PreToolUse': []},
  'enabledPlugins': {'caveman@caveman': true},
  'extraKnownMarketplaces': {'caveman': {}},
  'outputStyle': 'Concise',
  'effortLevel': 'xhigh',
  'modelSettings': {'claude-opus-5-5': {}},
  'theme': 'dark',
};

void main() {
  test('seed keeps only safe keys', () {
    final s = buildClaudeSeed(shared, includePlugins: false);
    expect(s.keys.toSet(), {'outputStyle', 'theme'});
    expect(s['outputStyle'], 'Concise');
  });

  test('seed adds plugin keys when includePlugins', () {
    final s = buildClaudeSeed(shared, includePlugins: true);
    expect(s.keys.toSet(), {
      'outputStyle',
      'theme',
      'hooks',
      'enabledPlugins',
      'extraKnownMarketplaces',
    });
  });

  group('writeClaudeSeed', () {
    late Directory tmp;
    late String sharedPath;
    late String sandboxPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('aiapp_seed_');
      sharedPath = '${tmp.path}/shared/settings.json';
      File(sharedPath)
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(shared));
      sandboxPath = '${tmp.path}/sandbox/.claude/settings.json';
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    Map<String, dynamic> read() =>
        jsonDecode(File(sandboxPath).readAsStringSync())
            as Map<String, dynamic>;

    test('writes a fresh file when none exists', () async {
      await writeClaudeSeed(
        sharedSettingsPath: sharedPath,
        sandboxSettingsPath: sandboxPath,
        includePlugins: false,
      );
      expect(read().keys.toSet(), {'outputStyle', 'theme'});
    });

    test('seed keeps alcf-ai keys already in the sandbox file', () async {
      File(sandboxPath)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'env': {'ANTHROPIC_BASE_URL': 'u'},
            'apiKeyHelper': 'alcf-ai auth get-access-token',
            'hooks': {'old': 1},
            'enabledPlugins': {'x': true},
          }),
        );
      await writeClaudeSeed(
        sharedSettingsPath: sharedPath,
        sandboxSettingsPath: sandboxPath,
        includePlugins: false,
      );
      final s = read();
      expect(s['env'], {'ANTHROPIC_BASE_URL': 'u'});
      expect(s['apiKeyHelper'], 'alcf-ai auth get-access-token');
      expect(s.containsKey('hooks'), isFalse);
      expect(s.containsKey('enabledPlugins'), isFalse);
    });

    test(
      'seed replaces a symlinked settings.json without touching its target',
      () async {
        final before = File(sharedPath).readAsBytesSync();
        Directory(File(sandboxPath).parent.path).createSync(recursive: true);
        Link(sandboxPath).createSync(sharedPath);
        await writeClaudeSeed(
          sharedSettingsPath: sharedPath,
          sandboxSettingsPath: sandboxPath,
          includePlugins: true,
        );
        expect(FileSystemEntity.isLinkSync(sandboxPath), isFalse);
        expect(File(sandboxPath).existsSync(), isTrue);
        expect(File(sharedPath).readAsBytesSync(), before);
        expect(read().containsKey('model'), isFalse);
      },
    );
  });
}
