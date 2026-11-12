import 'dart:convert';
import 'dart:io';

/// Env keys an earlier app version wrote to remap the `/model` aliases.
/// Removed so the built-in rows stay as alcf-ai left them.
const _staleKeys = [
  'ANTHROPIC_DEFAULT_FABLE_MODEL',
  'ANTHROPIC_CUSTOM_MODEL_OPTION',
];
const _staleSuffixes = ['', '_NAME', '_DESCRIPTION'];
const _staleLabelPrefixes = [
  'ANTHROPIC_DEFAULT_OPUS_MODEL',
  'ANTHROPIC_DEFAULT_SONNET_MODEL',
  'ANTHROPIC_DEFAULT_HAIKU_MODEL',
];

/// Adds [models] as extra rows of Claude Code's `/model` menu, after the
/// built-in rows alcf-ai sets up (Default, Opus, Sonnet, Haiku on the
/// default model), through the `modelPicker` user setting (Claude Code
/// >= 2.1.242). [main] is left out: a built-in row already runs it.
/// Other keys are kept.
Future<void> writeClaudePicker(
  String settingsPath,
  List<String> models, {
  required String main,
}) async {
  final f = File(settingsPath);
  final v = await f.exists() ? jsonDecode(await f.readAsString()) : null;
  final settings = v is Map<String, dynamic> ? v : <String, dynamic>{};
  final env = settings['env'] is Map
      ? Map<String, dynamic>.from(settings['env'] as Map)
      : <String, dynamic>{};
  for (final k in _staleKeys) {
    for (final s in _staleSuffixes) {
      env.remove('$k$s');
    }
  }
  for (final k in _staleLabelPrefixes) {
    env.remove('${k}_NAME');
    env.remove('${k}_DESCRIPTION');
  }
  settings['env'] = env;

  final extra = [
    for (final id in models)
      if (id != main) {'model': id},
  ];
  if (extra.isEmpty) {
    settings.remove('modelPicker');
  } else {
    settings['modelPicker'] = {'options': extra};
  }
  await f.parent.create(recursive: true);
  final tmp = File('${f.parent.path}/.settings.json.tmp');
  await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(settings));
  await tmp.rename(f.path);
}
