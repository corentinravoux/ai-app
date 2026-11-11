import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/agents.dart';
import 'theme.dart';

/// Shown while the ALCF Claude has no CLAUDE.md of its own (README:
/// "Share your Claude instructions").
const kSharedConfigHint =
    'To reuse your CLAUDE.md, commands and skills, link them in: see README';

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.state,
    required this.onOpen,
    required this.onConfigure,
  });

  final AppState state;
  final void Function(ProfileStatus) onOpen;
  final void Function(ProfileStatus) onConfigure;

  @override
  Widget build(BuildContext context) {
    final alcf = state.statuses.where((s) => s.profile.isAlcf);
    final native = state.statuses.where((s) => !s.profile.isAlcf);
    return Container(
      width: 260,
      decoration: const BoxDecoration(
        color: Tok.rail,
        border: Border(right: BorderSide(color: Tok.line)),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(10, 18, 10, 18),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'AI App',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontSize: 17),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _LoginLine(state: state),
          ),
          const SizedBox(height: 22),
          const _Group('ALCF inference'),
          for (final s in alcf) _tile(context, s),
          const SizedBox(height: 18),
          const _Group('Your Claude accounts'),
          for (final s in native) _tile(context, s),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, ProfileStatus s) => _ProfileTile(
    state: state,
    status: s,
    onOpen: onOpen,
    onConfigure: onConfigure,
  );
}

class _LoginLine extends StatelessWidget {
  const _LoginLine({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final (text, color) = !state.alcfAvailable
        ? ('alcf-ai is not installed', Tok.danger)
        : state.alcfLoggedIn
        ? ('Signed in to ALCF', Tok.running)
        : ('Not signed in to ALCF', Tok.queued);
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
    child: Text(
      label,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Tok.faint, fontWeight: FontWeight.w700),
    ),
  );
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.state,
    required this.status,
    required this.onOpen,
    required this.onConfigure,
  });

  final AppState state;
  final ProfileStatus status;
  final void Function(ProfileStatus) onOpen;
  final void Function(ProfileStatus) onConfigure;

  String get _detail {
    final p = status.profile;
    if (!status.installed) return 'Not installed';
    if (!p.isAlcf) {
      return state.describeRoute(p).replaceFirst('Anthropic, account in ', '');
    }
    if (!state.alcfAvailable) return 'Needs alcf-ai';
    if (!status.configured) return 'Not set up for ALCF yet';
    final route = state.describeRoute(p);
    return route.startsWith('ALCF ') && route.contains('model')
        ? route.substring(5)
        : 'Ready';
  }

  @override
  Widget build(BuildContext context) {
    final p = status.profile;
    final id = p.id;
    final canOpen = state.canOpen(status);
    final canConfigure = status.installed && state.alcfAvailable;
    final dim = !status.installed;
    final hint =
        p.isAlcf &&
        p.kind == AgentKind.claude &&
        status.installed &&
        !state.sandbox.sharedConfigLinked;

    final List<Widget> actions;
    if (!status.installed) {
      actions = [
        if (p.isAlcf)
          IconButton(
            key: ValueKey('configure-$id'),
            onPressed: null,
            icon: const Icon(Icons.tune_rounded, size: 18),
          ),
        IconButton(
          key: ValueKey('open-$id'),
          onPressed: null,
          icon: const Icon(Icons.play_arrow_rounded),
        ),
      ];
    } else if (p.isAlcf && !status.configured) {
      actions = [
        TextButton(
          key: ValueKey('setup-$id'),
          onPressed: canConfigure ? () => onConfigure(status) : null,
          child: const Text('Configure'),
        ),
      ];
    } else {
      actions = [
        if (p.isAlcf)
          IconButton(
            key: ValueKey('configure-$id'),
            tooltip: 'Change model or cluster',
            onPressed: canConfigure ? () => onConfigure(status) : null,
            icon: const Icon(Icons.tune_rounded, size: 18),
          ),
        IconButton(
          key: ValueKey('open-$id'),
          tooltip: 'New session',
          onPressed: canOpen ? () => onOpen(status) : null,
          icon: const Icon(Icons.play_arrow_rounded),
        ),
      ];
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(Tok.radius),
        hoverColor: Tok.raised,
        onTap: canOpen ? () => onOpen(status) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 2, 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.label,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: dim ? Tok.faint : Tok.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _detail,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: dim ? Tok.faint : Tok.muted),
                    ),
                    if (hint) ...[
                      const SizedBox(height: 4),
                      Text(
                        kSharedConfigHint,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: Tok.faint, fontSize: 11.5),
                      ),
                    ],
                  ],
                ),
              ),
              IconTheme(
                data: IconThemeData(
                  color: dim ? Tok.faint : Tok.muted,
                  size: 20,
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: actions),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
