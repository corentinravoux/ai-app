import 'dart:convert';
import 'dart:io';

/// The model aliases Claude Code offers in `/model`. alcf-ai points every
/// one of them at the default model; the app maps each to its own ALCF
/// model so the menu is a real choice.
enum ClaudeSlot { opus, sonnet, haiku }

/// Models tried, in order, when the user has not picked one for a slot.
/// Haiku also runs Claude Code's background work (titles, summaries), so
/// it gets a lighter model.
const kSlotPreference = {
  ClaudeSlot.opus: ['muse-spark-bf16', 'inkling-bf16'],
  ClaudeSlot.sonnet: [
    'mistral-large-4',
    'mistral-large-4-nvfp4',
    'inkling-bf16',
  ],
  ClaudeSlot.haiku: ['nemotron-3-ultra', 'inkling-bf16'],
};

/// Claude Code also has a Fable alias; it gets the Opus model.
const _envSlots = {
  'OPUS': ClaudeSlot.opus,
  'FABLE': ClaudeSlot.opus,
  'SONNET': ClaudeSlot.sonnet,
  'HAIKU': ClaudeSlot.haiku,
};

String slotLabel(ClaudeSlot s) => switch (s) {
  ClaudeSlot.opus => 'Opus',
  ClaudeSlot.sonnet => 'Sonnet',
  ClaudeSlot.haiku => 'Haiku',
};

/// One model per slot: [current] when still served, else the first
/// preferred model served, else [main].
Map<ClaudeSlot, String> pickClaudeSlots(
  List<String> available,
  String main, {
  Map<ClaudeSlot, String> current = const {},
}) => {
  for (final s in ClaudeSlot.values)
    s: [
      current[s],
      ...kSlotPreference[s]!,
    ].firstWhere((id) => available.contains(id), orElse: () => main)!,
};

/// Slots as written in a Claude settings `env` block.
Map<ClaudeSlot, String> readClaudeSlots(Map<String, dynamic> env) => {
  for (final s in ClaudeSlot.values)
    if (env['ANTHROPIC_DEFAULT_${s.name.toUpperCase()}_MODEL']
        case final String id)
      s: id,
};

/// Writes the slot models, with display names for the `/model` menu, into
/// the sandbox settings.json `env`. Other keys are kept.
Future<void> writeClaudeSlots(
  String settingsPath,
  Map<ClaudeSlot, String> slots, {
  required String cluster,
  Map<String, String> names = const {},
}) async {
  final f = File(settingsPath);
  final v = await f.exists() ? jsonDecode(await f.readAsString()) : null;
  final settings = v is Map<String, dynamic> ? v : <String, dynamic>{};
  final env = settings['env'] is Map
      ? Map<String, dynamic>.from(settings['env'] as Map)
      : <String, dynamic>{};
  for (final MapEntry(key: slot, value: s) in _envSlots.entries) {
    final id = slots[s];
    if (id == null) continue;
    final k = 'ANTHROPIC_DEFAULT_${slot}_MODEL';
    env[k] = id;
    env['${k}_NAME'] = names[id] ?? id;
    env['${k}_DESCRIPTION'] = '$id on ALCF $cluster';
  }
  settings['env'] = env;
  await f.parent.create(recursive: true);
  final tmp = File('${f.parent.path}/.settings.json.tmp');
  await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(settings));
  await tmp.rename(f.path);
}
