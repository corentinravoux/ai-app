import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/hosts.dart';
import 'theme.dart';

/// Adds a model host, or edits / removes [editing].
Future<void> showHostDialog(
  BuildContext context,
  AppState state, {
  ModelHost? editing,
}) => showDialog<void>(
  context: context,
  builder: (_) => _HostDialog(state: state, editing: editing),
);

class _HostDialog extends StatefulWidget {
  const _HostDialog({required this.state, this.editing});
  final AppState state;
  final ModelHost? editing;

  @override
  State<_HostDialog> createState() => _HostDialogState();
}

class _HostDialogState extends State<_HostDialog> {
  late final _label = TextEditingController(text: widget.editing?.label ?? '');
  late final _target = TextEditingController(
    text: widget.editing?.sshTarget ?? '',
  );
  late final _serverPort = TextEditingController(
    text: '${widget.editing?.serverPort ?? 9931}',
  );
  late final _localPort = TextEditingController(
    text: '${widget.editing?.localPort ?? nextLocalPort(_others)}',
  );
  late final _cmd = TextEditingController(
    text: widget.editing?.llmHostCmd ?? 'llm-host',
  );
  late HostKind _kind = widget.editing?.kind ?? HostKind.local;
  String? _testResult;
  bool _testing = false;
  String? _error;

  List<ModelHost> get _others => [
    for (final h in widget.state.hosts)
      if (h.id != widget.editing?.id) h,
  ];

  ModelHost get _host => ModelHost(
    id: widget.editing?.id ?? hostIdFromLabel(_label.text),
    label: _label.text.trim(),
    kind: _kind,
    sshTarget: _kind == HostKind.ssh ? _target.text.trim() : null,
    serverPort: int.tryParse(_serverPort.text.trim()) ?? -1,
    localPort: _kind == HostKind.ssh
        ? int.tryParse(_localPort.text.trim())
        : null,
    llmHostCmd: _cmd.text.trim().isEmpty ? 'llm-host' : _cmd.text.trim(),
  );

  @override
  void dispose() {
    for (final c in [_label, _target, _serverPort, _localPort, _cmd]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(
    String key,
    String label,
    TextEditingController c, {
    String? hint,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: ValueKey(key),
      controller: c,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      onChanged: (_) => setState(() => _testResult = null),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final problems = validateHost(_host, _others);
    final small = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      title: Text(
        widget.editing == null
            ? 'Add a model host'
            : 'Edit ${widget.editing!.label}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field('host-label', 'Name', _label, hint: 'PC, Mini PC…'),
              SegmentedButton<HostKind>(
                segments: const [
                  ButtonSegment(
                    value: HostKind.local,
                    label: Text('This machine', key: ValueKey('kind-local')),
                  ),
                  ButtonSegment(
                    value: HostKind.ssh,
                    label: Text('Over SSH', key: ValueKey('kind-ssh')),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (v) => setState(() {
                  _kind = v.first;
                  // install-host.sh puts llm-host in ~/.local/bin, which a
                  // non-interactive ssh shell often lacks on PATH; the
                  // remote shell expands ~.
                  final c = _cmd.text.trim();
                  if (_kind == HostKind.ssh && c == 'llm-host') {
                    _cmd.text = '~/.local/bin/llm-host';
                  } else if (_kind == HostKind.local &&
                      c == '~/.local/bin/llm-host') {
                    _cmd.text = 'llm-host';
                  }
                  _testResult = null;
                }),
              ),
              const SizedBox(height: 14),
              if (_kind == HostKind.ssh)
                _field(
                  'host-target',
                  'SSH target',
                  _target,
                  hint: 'user@pc or an ~/.ssh/config name',
                ),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      'host-server-port',
                      'Server port (on the host)',
                      _serverPort,
                      number: true,
                    ),
                  ),
                  if (_kind == HostKind.ssh) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: _field(
                        'host-local-port',
                        'Local port (here)',
                        _localPort,
                        number: true,
                      ),
                    ),
                  ],
                ],
              ),
              _field(
                'host-cmd',
                'llm-host command',
                _cmd,
                hint: 'llm-host, or /home/<user>/.local/bin/llm-host',
              ),
              for (final p in problems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(p, style: small?.copyWith(color: Tok.danger)),
                ),
              Row(
                children: [
                  OutlinedButton(
                    key: const ValueKey('host-test'),
                    onPressed: _testing || problems.isNotEmpty ? null : _test,
                    child: const Text('Test'),
                  ),
                  const SizedBox(width: 12),
                  if (_testing)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (_testResult != null)
                    Expanded(
                      child: Text(
                        _testResult!,
                        style: small?.copyWith(
                          color:
                              _testResult!.startsWith('ready') ||
                                  _testResult!.startsWith('reachable')
                              ? Tok.running
                              : Tok.danger,
                        ),
                      ),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: small?.copyWith(color: Tok.danger)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (widget.editing != null)
          TextButton(
            key: const ValueKey('host-remove'),
            onPressed: _remove,
            style: TextButton.styleFrom(foregroundColor: Tok.danger),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('host-save'),
          onPressed: problems.isEmpty ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final r = await widget.state.testHost(_host);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = r;
    });
  }

  Future<void> _save() async {
    final nav = Navigator.of(context);
    final f = widget.state.saveHost(_host, replacingId: widget.editing?.id);
    nav.pop();
    await f;
  }

  Future<void> _remove() async {
    final err = await widget.state.removeHost(widget.editing!.id);
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
    } else {
      Navigator.pop(context);
    }
  }
}
