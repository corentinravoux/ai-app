import 'dart:convert';
import 'dart:io';

import 'package:alcfai_app/core/claude_slots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('alcfai_slots_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const tara = [
    'inkling-bf16',
    'mistral-large-4',
    'muse-spark-bf16',
    'nemotron-3-ultra',
  ];

  test('pickClaudeSlots takes the first preferred model served', () {
    expect(pickClaudeSlots(tara, 'inkling-bf16'), {
      ClaudeSlot.opus: 'muse-spark-bf16',
      ClaudeSlot.sonnet: 'mistral-large-4',
      ClaudeSlot.haiku: 'nemotron-3-ultra',
    });
  });

  test(
    'pickClaudeSlots keeps a current pick still served, else falls back',
    () {
      final s = pickClaudeSlots(
        ['beam'],
        'beam',
        current: {ClaudeSlot.opus: 'gone', ClaudeSlot.haiku: 'beam'},
      );
      expect(s.values.toSet(), {'beam'});
      expect(
        pickClaudeSlots(
          tara,
          'inkling-bf16',
          current: {ClaudeSlot.opus: 'inkling-bf16'},
        )[ClaudeSlot.opus],
        'inkling-bf16',
      );
    },
  );

  test(
    'writeClaudeSlots fills the four aliases and keeps other keys',
    () async {
      final f = File('${tmp.path}/settings.json')
        ..writeAsStringSync(
          jsonEncode({
            'theme': 'dark',
            'env': {'ANTHROPIC_MODEL': 'inkling-bf16', 'X': '1'},
          }),
        );
      await writeClaudeSlots(
        f.path,
        pickClaudeSlots(tara, 'inkling-bf16'),
        cluster: 'tara',
        names: {'muse-spark-bf16': 'Muse Spark'},
      );
      final v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final env = v['env'] as Map<String, dynamic>;
      expect(v['theme'], 'dark');
      expect(env['X'], '1');
      expect(env['ANTHROPIC_MODEL'], 'inkling-bf16');
      expect(env['ANTHROPIC_DEFAULT_OPUS_MODEL'], 'muse-spark-bf16');
      expect(env['ANTHROPIC_DEFAULT_OPUS_MODEL_NAME'], 'Muse Spark');
      expect(env['ANTHROPIC_DEFAULT_FABLE_MODEL'], 'muse-spark-bf16');
      expect(env['ANTHROPIC_DEFAULT_SONNET_MODEL'], 'mistral-large-4');
      expect(env['ANTHROPIC_DEFAULT_SONNET_MODEL_NAME'], 'mistral-large-4');
      expect(env['ANTHROPIC_DEFAULT_HAIKU_MODEL'], 'nemotron-3-ultra');
      expect(
        env['ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION'],
        'nemotron-3-ultra on ALCF tara',
      );
      expect(readClaudeSlots(env), pickClaudeSlots(tara, 'inkling-bf16'));
    },
  );
}
