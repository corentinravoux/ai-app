import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/host_client.dart';
import '../core/hosts.dart';
import '../core/tunnel.dart';
import 'log_dialog.dart';
import 'theme.dart';

/// One model host in the sidebar: what runs there, and start / switch /
/// stop / log.
class HostTile extends StatelessWidget {
  const HostTile({
    super.key,
    required this.state,
    required this.host,
    this.onEdit,
  });

  final AppState state;
  final ModelHost host;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final id = host.id;
    final s = state.statusOfHost(id);
    final problem = state.unreachableReason(id);
    final small = Theme.of(context).textTheme.bodySmall;

    final (Color dot, String line2) = switch (s?.state) {
      null => (Tok.faint, problem ?? 'Checking ${host.label}…'),
      ServerState.stopped => (
        Tok.faint,
        'No model is running on ${host.label}: start one',
      ),
      ServerState.loading => (
        Tok.queued,
        '${host.label} is loading ${s!.label ?? s.recipe ?? 'a model'}…',
      ),
      ServerState.ready => (Tok.running, s!.label ?? s.recipe ?? 'Ready'),
      ServerState.foreign => (
        Tok.danger,
        'A llama-server not started by AI App is running on ${host.label}',
      ),
      ServerState.error => (
        Tok.danger,
        'The model failed to start on ${host.label}: open the log',
      ),
    };

    String? line3;
    if (s?.state == ServerState.ready && s!.ctx != null) {
      line3 = '${s.ctx! ~/ 1024}K window';
      if (s.gpuUsedMib != null && s.gpuTotalMib != null) {
        String gb(int mib) => (mib / 1024).toStringAsFixed(1);
        line3 += ' · VRAM ${gb(s.gpuUsedMib!)} / ${gb(s.gpuTotalMib!)} GB';
      }
    }

    final tunnel = state.tunnelOf(id);
    final tunnelLine =
        host.isRemote && tunnel.phase != TunnelPhase.up && tunnel.error != null
        ? 'Tunnel: ${tunnel.error}'
        : null;

    final usable = s != null && s.state != ServerState.foreign;
    final running =
        s?.state == ServerState.ready || s?.state == ServerState.loading;
    final canStop = usable && (running || s.state == ServerState.error);

    Widget smallButton(
      String key,
      String tip,
      IconData icon,
      VoidCallback? on,
    ) => IconButton(
      key: ValueKey(key),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      onPressed: on,
      icon: Icon(icon),
    );

    // Two lines of controls: the 260 px sidebar has room for two buttons
    // beside the name; the others go below the status lines.
    return Padding(
      key: ValueKey('host-$id'),
      padding: const EdgeInsets.fromLTRB(8, 6, 2, 2),
      child: IconTheme(
        data: const IconThemeData(color: Tok.muted, size: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                Expanded(
                  child: Text(
                    host.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: Tok.text,
                    ),
                  ),
                ),
                _RecipeMenu(state: state, host: host, enabled: usable),
                IconButton(
                  key: ValueKey('host-stop-$id'),
                  tooltip: 'Stop the model',
                  visualDensity: VisualDensity.compact,
                  onPressed: canStop ? () => _stop(context) : null,
                  icon: const Icon(Icons.stop_rounded),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line2, style: small?.copyWith(color: Tok.muted)),
                  if (line3 != null) ...[
                    const SizedBox(height: 1),
                    Text(line3, style: small?.copyWith(color: Tok.faint)),
                  ],
                  if (tunnelLine != null) ...[
                    const SizedBox(height: 1),
                    Text(tunnelLine, style: small?.copyWith(color: Tok.danger)),
                  ],
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                smallButton(
                  'host-probe-$id',
                  'Probe: tool call, Claude API, speed',
                  Icons.fact_check_outlined,
                  s?.state == ServerState.ready
                      ? () => showTextDialog(
                          context,
                          title:
                              'Probe of ${s!.label ?? s.recipe} on ${host.label}',
                          text: state.probeText(id),
                        )
                      : null,
                ),
                smallButton(
                  'host-log-$id',
                  'Server log',
                  Icons.article_outlined,
                  s == null
                      ? null
                      : () => showTextDialog(
                          context,
                          title: 'llama-server log on ${host.label}',
                          text: state.logTail(id),
                        ),
                ),
                if (onEdit != null)
                  smallButton(
                    'host-edit-$id',
                    'Edit host',
                    Icons.edit_outlined,
                    onEdit,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _stop(BuildContext context) async {
    final n = state.openTabsOn(host.id);
    if (n > 0 && !await _confirmLoss(context, state, host, n, 'Stop')) return;
    final err = await state.stopModel(host.id);
    if (err != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }
}

Future<bool> _confirmLoss(
  BuildContext context,
  AppState state,
  ModelHost host,
  int n,
  String action,
) async {
  final text = n == 1
      ? '1 open tab uses ${host.label}. It will lose its model.'
      : '$n open tabs use ${host.label}. They will lose their model.';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

class _RecipeMenu extends StatelessWidget {
  const _RecipeMenu({
    required this.state,
    required this.host,
    required this.enabled,
  });

  final AppState state;
  final ModelHost host;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final s = state.statusOfHost(host.id);
    final switching =
        s?.state == ServerState.ready || s?.state == ServerState.loading;
    final recipes = state.recipesOf(host.id);
    return PopupMenuButton<String>(
      key: ValueKey('host-menu-${host.id}'),
      enabled: enabled,
      tooltip: switching ? 'Switch model' : 'Start a model',
      icon: Icon(
        switching ? Icons.swap_horiz_rounded : Icons.play_circle_outline,
      ),
      onOpened: () => state.refreshRecipes(host.id),
      onSelected: (name) => _start(context, name),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 32,
          child: Text(
            switching ? 'Switch model' : 'Start',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (recipes.isEmpty)
          const PopupMenuItem<String>(
            enabled: false,
            child: Text('No recipes on this host: see docs/hosts.md'),
          ),
        for (final r in recipes)
          PopupMenuItem<String>(
            key: ValueKey('recipe-${r.name}'),
            value: r.name,
            enabled: r.modelPresent,
            child: r.modelPresent
                ? Text(r.label)
                : Tooltip(
                    message: 'model file missing on ${host.label}',
                    child: Text(r.label),
                  ),
          ),
      ],
    );
  }

  Future<void> _start(BuildContext context, String name) async {
    final n = state.openTabsOn(host.id);
    if (n > 0 && !await _confirmLoss(context, state, host, n, 'Switch')) {
      return;
    }
    final err = await state.startModel(host.id, name);
    if (err != null && context.mounted) {
      await showTextDialog(
        context,
        title: 'Could not start the model on ${host.label}',
        text: Future.value(err),
      );
    }
  }
}
