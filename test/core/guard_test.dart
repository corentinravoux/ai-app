import 'dart:io';

import 'package:ai_app/core/guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('aiapp_guard_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('defaultPaths lists every account and agent config', () {
    const h = '/h';
    expect(RealConfigGuard.defaultPaths(h, ['$h/.claude', '$h/.claude-alt']), [
      '$h/.claude/settings.json',
      '$h/.claude-alt/settings.json',
      '$h/.codex/config.toml',
      '$h/.pi/agent/models.json',
      '$h/.config/opencode/opencode.jsonc',
    ]);
  });

  test('snapshot hashes through symlinks; missing file is null', () async {
    final target = File('${tmp.path}/t.json')..writeAsStringSync('{}');
    Link('${tmp.path}/l.json').createSync(target.path);
    final g = RealConfigGuard([
      target.path,
      '${tmp.path}/l.json',
      '${tmp.path}/missing',
    ]);
    final s = await g.snapshot();
    expect(s[target.path], isNotNull);
    expect(s['${tmp.path}/l.json'], s[target.path]);
    expect(s['${tmp.path}/missing'], isNull);
  });

  test('changedSince detects edit, creation, deletion', () async {
    final a = File('${tmp.path}/a')..writeAsStringSync('1');
    final b = File('${tmp.path}/b')..writeAsStringSync('2');
    final c = '${tmp.path}/c';
    final d = File('${tmp.path}/d')..writeAsStringSync('4');
    final g = RealConfigGuard([a.path, b.path, c, d.path]);
    final before = await g.snapshot();
    expect(await g.changedSince(before), isEmpty);
    a.writeAsStringSync('changed');
    File(c).writeAsStringSync('new');
    d.deleteSync();
    expect(await g.changedSince(before), [a.path, c, d.path]);
    expect(b.existsSync(), isTrue);
  });
}
