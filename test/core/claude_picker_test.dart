import 'dart:convert';
import 'dart:io';

import 'package:ai_app/core/claude_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('aiapp_picker_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, dynamic> read(File f) =>
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;

  test('adds every model but the main one after the built-in rows, '
      'leaving alcf-ai settings as they are', () async {
    final env = {
      'ANTHROPIC_MODEL': 'inkling-bf16',
      'ANTHROPIC_DEFAULT_OPUS_MODEL': 'inkling-bf16',
      'ANTHROPIC_DEFAULT_SONNET_MODEL': 'inkling-bf16',
      'ANTHROPIC_DEFAULT_HAIKU_MODEL': 'inkling-bf16',
    };
    final f = File('${tmp.path}/settings.json')
      ..writeAsStringSync(
        jsonEncode({'theme': 'dark', 'model': 'opus', 'env': env}),
      );
    await writeClaudePicker(f.path, [
      'inkling-bf16',
      'mistral-large-4',
      'muse-spark-bf16',
    ], main: 'inkling-bf16');
    final v = read(f);
    expect(v['theme'], 'dark');
    expect(v['model'], 'opus');
    expect(v['env'], env);
    expect(v['modelPicker'], {
      'options': [
        {'model': 'mistral-large-4'},
        {'model': 'muse-spark-bf16'},
      ],
    });
  });

  test('removes alias remaps an earlier version wrote', () async {
    final f = File('${tmp.path}/settings.json')
      ..writeAsStringSync(
        jsonEncode({
          'env': {
            'ANTHROPIC_DEFAULT_SONNET_MODEL': 'inkling-bf16',
            'ANTHROPIC_DEFAULT_SONNET_MODEL_NAME': 'Mistral',
            'ANTHROPIC_DEFAULT_FABLE_MODEL': 'muse-spark-bf16',
            'ANTHROPIC_DEFAULT_FABLE_MODEL_NAME': 'Muse',
            'ANTHROPIC_CUSTOM_MODEL_OPTION': 'beam-1.0-fp8',
            'ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION': 'Beam',
          },
        }),
      );
    await writeClaudePicker(f.path, ['m'], main: 'm');
    final v = read(f);
    expect(v['env'], {'ANTHROPIC_DEFAULT_SONNET_MODEL': 'inkling-bf16'});
    expect(v.containsKey('modelPicker'), isFalse);
  });
}
