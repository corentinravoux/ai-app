import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/agents.dart';
import '../core/alcf_cli.dart';
import '../core/app_store.dart';
import '../core/claude_slots.dart';
import '../core/profiles.dart';
import 'theme.dart';

const kPluginsLabel = 'Include plugins & hooks (uses much more context)';

/// Picks cluster and model, then runs the sandboxed `alcf-ai agent configure`.
Future<void> showConfigureDialog(
  BuildContext context,
  AppState state,
  Profile profile,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ConfigureDialog(state: state, profile: profile),
  );
}

class _ConfigureDialog extends StatefulWidget {
  const _ConfigureDialog({required this.state, required this.profile});
  final AppState state;
  final Profile profile;

  @override
  State<_ConfigureDialog> createState() => _ConfigureDialogState();
}

sealed class _Outcome {
  const _Outcome();
}

class _Message extends _Outcome {
  const _Message(this.text, {this.login = false});
  final String text;
  final bool login;
}

class _Touched extends _Outcome {
  const _Touched(this.paths);
  final List<String> paths;
}

class _ConfigureDialogState extends State<_ConfigureDialog> {
  AlcfCli get _alcf => widget.state.alcf!;
  bool get _isClaude => widget.profile.kind == AgentKind.claude;

  String _cluster = kClusters.first;
  List<AlcfModel> _models = [];
  Map<String, ModelStatus> _status = {};
  String? _model;
  Map<ClaudeSlot, String> _slots = {};
  bool _loading = true;
  bool _experimental = false;
  bool _plugins = false;
  bool _busy = false;
  _Outcome? _outcome;

  String? _preferred;

  @override
  void initState() {
    super.initState();
    final c = widget.state.choiceFor(widget.profile);
    if (c != null && kClusters.contains(c.cluster)) {
      _cluster = c.cluster;
      _preferred = c.model;
    }
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final cluster = _cluster;
    final kind = _isClaude ? AgentKind.claude : null;
    final results = await Future.wait([
      _alcf.listModels(cluster, forAgent: kind),
      _alcf.modelStatus(cluster),
    ]);
    if (!mounted || cluster != _cluster) return;
    final models = results[0] as List<AlcfModel>;
    setState(() {
      _models = models;
      _status = results[1] as Map<String, ModelStatus>;
      _model =
          [_preferred, 'inkling-bf16'].firstWhere(
            (id) => models.any((m) => m.id == id),
            orElse: () => null,
          ) ??
          (models.isEmpty ? null : models.first.id);
      _slots = _isClaude && _model != null
          ? pickClaudeSlots(
              [for (final m in models) m.id],
              _model!,
              current: _savedSlots(cluster),
            )
          : {};
      _loading = false;
    });
  }

  /// Slots the app wrote last time on this cluster. alcf-ai alone sets
  /// every slot to the default model, without names; those are not a pick.
  Map<ClaudeSlot, String> _savedSlots(String cluster) {
    final env = widget.state.claudeEnv();
    final url = '${env['ANTHROPIC_BASE_URL'] ?? ''}';
    if (!url.contains('resource_server/$cluster/') ||
        !env.containsKey('ANTHROPIC_DEFAULT_OPUS_MODEL_NAME')) {
      return const {};
    }
    return readClaudeSlots(env);
  }

  Future<void> _submit() async {
    final model = _model;
    if (model == null) return;
    setState(() {
      _busy = true;
      _outcome = null;
    });
    final r = await _alcf.configure(
      widget.profile.kind,
      model: model,
      cluster: _cluster,
      experimental: _experimental,
      includePlugins: _isClaude && _plugins,
      claudeSlots: _isClaude ? _slots : null,
      modelNames: {for (final m in _models) m.id: m.displayName},
    );
    if (!mounted) return;
    if (r is ConfigureOk) {
      await widget.state.recordChoice(
        widget.profile,
        AgentChoice(_cluster, model),
      );
      await widget.state.refresh();
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _outcome = switch (r) {
        LoginNeeded() => const _Message(
          'ALCF login needed. Log in, then configure again.',
          login: true,
        ),
        ConfigureFailed(:final message) => _Message(message),
        RealConfigTouched(:final paths) => _Touched(paths),
        ConfigureOk() => null,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Configure ${widget.profile.label}', style: t.titleMedium),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Settings are written to the app folder, not to your own '
              '${widget.profile.kind.exe} setup.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 18),
            const Text('Cluster'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              key: const ValueKey('cluster-dropdown'),
              initialValue: _cluster,
              items: [
                for (final c in kClusters)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: _busy
                  ? null
                  : (c) {
                      if (c == null || c == _cluster) return;
                      setState(() => _cluster = c);
                      _load();
                    },
            ),
            const SizedBox(height: 14),
            const Text('Model'),
            const SizedBox(height: 6),
            _modelField(t),
            if (_isClaude) ...[
              const SizedBox(height: 6),
              Text(
                'Only models that speak the Anthropic API are listed.',
                style: t.bodySmall,
              ),
              if (!_loading && _models.isNotEmpty) ..._slotFields(t),
            ],
            const SizedBox(height: 10),
            CheckboxListTile(
              key: const ValueKey('experimental-box'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _experimental,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _experimental = v ?? false),
              title: const Text('Include experimental models'),
              subtitle: Text(
                'Models ALCF has not vetted for agents yet.',
                style: t.bodySmall,
              ),
            ),
            if (_isClaude)
              CheckboxListTile(
                key: const ValueKey('plugins-box'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                value: _plugins,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _plugins = v ?? false),
                title: const Text(kPluginsLabel),
              ),
            if (_outcome != null) ...[
              const SizedBox(height: 12),
              _OutcomeView(outcome: _outcome!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: Tok.muted),
          child: const Text('Cancel'),
        ),
        if (_outcome case _Message(login: true))
          OutlinedButton(
            onPressed: () {
              Navigator.pop(context);
              widget.state.openLogin();
            },
            child: const Text('Log in'),
          ),
        FilledButton(
          key: const ValueKey('configure-submit'),
          onPressed: (_busy || _loading || _model == null) ? null : _submit,
          child: Text(_busy ? 'Configuring' : 'Configure'),
        ),
      ],
    );
  }

  /// One dropdown per `/model` alias in Claude Code.
  List<Widget> _slotFields(TextTheme t) => [
    const SizedBox(height: 14),
    const Text('Models in the /model menu'),
    const SizedBox(height: 6),
    for (final s in ClaudeSlot.values)
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            SizedBox(width: 70, child: Text(slotLabel(s))),
            Expanded(
              child: KeyedSubtree(
                key: ValueKey('slot-${s.name}-$_cluster'),
                child: DropdownButtonFormField<String>(
                  key: ValueKey('slot-${s.name}'),
                  initialValue: _slots[s],
                  isExpanded: true,
                  isDense: true,
                  items: [
                    for (final m in _models)
                      DropdownMenuItem(
                        value: m.id,
                        child: Text(m.id, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) {
                          if (v != null) setState(() => _slots[s] = v);
                        },
                ),
              ),
            ),
          ],
        ),
      ),
    Text(
      'Haiku also runs Claude Code background tasks; Fable follows Opus.',
      style: t.bodySmall,
    ),
  ];

  Widget _modelField(TextTheme t) {
    if (_loading) {
      return Container(
        height: 40,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: Tok.line),
          borderRadius: BorderRadius.circular(Tok.radius),
        ),
        child: Text('Loading models from $_cluster', style: t.bodySmall),
      );
    }
    if (_models.isEmpty) {
      return Text(
        'No models found on $_cluster. Check your ALCF login, or pick '
        'another cluster.',
        style: t.bodySmall?.copyWith(color: Tok.queued),
      );
    }
    // Keyed by cluster: a form field reads initialValue only once, so a new
    // cluster needs a new field or it keeps showing the old model.
    return KeyedSubtree(
      key: ValueKey('models-$_cluster'),
      child: DropdownButtonFormField<String>(
        key: const ValueKey('model-dropdown'),
        initialValue: _model,
        isExpanded: true,
        items: [
          for (final m in _models)
            DropdownMenuItem(
              value: m.id,
              child: Row(
                children: [
                  Expanded(child: Text(m.id, overflow: TextOverflow.ellipsis)),
                  _StatusLabel(_status[m.id] ?? ModelStatus.unknown),
                ],
              ),
            ),
        ],
        onChanged: _busy ? null : (v) => setState(() => _model = v),
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel(this.status);
  final ModelStatus status;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (status) {
      ModelStatus.running => ('running', Tok.running),
      ModelStatus.queued => ('queued', Tok.queued),
      ModelStatus.offline => ('offline', Tok.faint),
      ModelStatus.unknown => ('', Tok.faint),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w700),
    );
  }
}

class _OutcomeView extends StatelessWidget {
  const _OutcomeView({required this.outcome});
  final _Outcome outcome;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return switch (outcome) {
      _Message(:final text) => Text(
        text,
        style: t.bodyMedium?.copyWith(color: Tok.queued),
      ),
      _Touched(:final paths) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Stopped: alcf-ai changed your own config. For each file below, '
            'a .bak.* copy sits next to it: restore it.',
            style: t.bodyMedium?.copyWith(color: Tok.danger),
          ),
          const SizedBox(height: 6),
          for (final p in paths)
            Text(
              p,
              style: const TextStyle(
                color: Tok.danger,
                fontFamily: Tok.mono,
                fontSize: 12.5,
              ),
            ),
        ],
      ),
    };
  }
}
