import 'dart:io';

import 'package:ai_app/core/runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a per-call timeout kills the command and returns 124', () async {
    final tmp = Directory.systemTemp.createTempSync('aiapp_runner_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final marker = '${tmp.path}/done';
    final sw = Stopwatch()..start();
    final r = await const IoRunner().run('sh', [
      '-c',
      'sleep 1; touch $marker',
    ], timeout: const Duration(milliseconds: 200));
    expect(r.exitCode, 124);
    expect(r.stderr, contains('timed out'));
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 900)));
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(File(marker).existsSync(), isFalse, reason: 'process was killed');
  });

  test('output and exit code pass through', () async {
    final r = await const IoRunner().run('sh', [
      '-c',
      'echo out; echo err >&2; exit 3',
    ]);
    expect((r.exitCode, r.stdout.trim(), r.stderr.trim()), (3, 'out', 'err'));
  });

  test('a missing executable returns 127', () async {
    final r = await const IoRunner().run('/nonexistent/x', []);
    expect(r.exitCode, 127);
  });

  test('malformed output does not throw', () async {
    final r = await const IoRunner().run('sh', ['-c', r"printf '\377ok'"]);
    expect(r.exitCode, 0);
    expect(r.stdout, contains('ok'));
  });

  test('a background grandchild does not hold a finished command', () async {
    final sw = Stopwatch()..start();
    final r = await const IoRunner().run('sh', ['-c', 'sleep 3 & echo hi']);
    expect(r.stdout.trim(), 'hi');
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 1500)));
  });
}
