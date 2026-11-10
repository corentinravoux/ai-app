import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'layout.dart';

import '../core/agents.dart';
import '../core/alcf_cli.dart';
import '../core/app_store.dart';
import '../core/launch.dart';
import '../core/profiles.dart';
import '../core/pty.dart';
import '../core/sandbox.dart';
import '../core/term_tools.dart';

class ProfileStatus {
  const ProfileStatus(this.profile, this.exePath, this.configured);
  final Profile profile;
  final String? exePath;

  /// Native profiles are always configured.
  final bool configured;
  bool get installed => exePath != null;
}

class OpenTab {
  OpenTab({
    required this.id,
    required this.title,
    required this.profile,
    required this.spec,
    required this.route,
  });

  final int id;
  final String title;

  /// Null for the ALCF login tab.
  final Profile? profile;
  final LaunchSpec spec;

  /// Where requests go, shown above the terminal.
  final String route;
  int? exitCode;
  bool get running => exitCode == null;
}

class AppState extends ChangeNotifier {
  AppState({
    required this.profiles,
    required this.which,
    required this.sandbox,
    required this.alcf,
    required this.start,
    required this.parentEnv,
    required this.defaultCwd,
    required this.store,
  }) : _offer = List.of(store.lastTabs);

  final List<Profile> profiles;
  final Which which;
  final Sandbox sandbox;

  /// Null when alcf-ai or alcf-tokens is missing: ALCF profiles are disabled.
  final AlcfCli? alcf;
  final PtyStarter start;
  final Map<String, String> parentEnv;
  final AppStore store;
  String defaultCwd;

  List<ProfileStatus> statuses = [];
  final List<OpenTab> tabs = [];

  /// The terminal area: a tree of panes (see layout.dart). Each pane shows
  /// one tab, or nothing. Every tab keeps running whether shown or not.
  LayoutNode layout = PaneNode(0);
  int _nextPaneId = 1;

  /// Id of the pane that receives tab clicks and new sessions.
  int focus = 0;

  List<PaneNode> get panes => panesOf(layout);

  bool get isSplit => layout is SplitNode;

  PaneNode get focusedPane =>
      panes.firstWhere((p) => p.id == focus, orElse: () => panes.first);

  /// Position of the focused pane in [panes].
  int get focusIndex => panes.indexOf(focusedPane);

  /// The tab each pane shows, in [panes] order.
  List<OpenTab?> get paneTabs => [for (final p in panes) _byId(p.tab)];

  /// Index of the tab in the focused pane (0 when it is empty).
  int get active {
    final i = tabs.indexWhere((t) => t.id == focusedPane.tab);
    return i < 0 ? 0 : i;
  }

  /// Id of the pane showing tab [i], or null when it is hidden.
  int? paneOf(int i) => panes.where((p) => p.tab == tabs[i].id).firstOrNull?.id;

  PaneNode? _pane(int id) => panes.where((p) => p.id == id).firstOrNull;

  OpenTab? _byId(int? id) =>
      id == null ? null : tabs.where((t) => t.id == id).firstOrNull;

  /// The first tab no pane shows, preferring index [from] then earlier ones.
  int? _hiddenFrom(int from) {
    final shown = {for (final p in panes) p.tab};
    final order = [
      for (var i = from; i < tabs.length; i++) i,
      for (var i = from - 1; i >= 0; i--) i,
    ];
    for (final i in order) {
      if (i >= 0 && !shown.contains(tabs[i].id)) return tabs[i].id;
    }
    return null;
  }

  /// Gives every empty pane a hidden tab while there are some.
  void _fillEmpty(int from) {
    for (final p in panes) {
      p.tab ??= _hiddenFrom(from);
    }
  }

  /// Splits pane [paneId] on [side]. The new pane shows tab [tabIndex]
  /// (moved there from wherever it was shown), or else a hidden tab, or
  /// nothing; it takes the focus.
  void splitPane(int paneId, Side side, {int? tabIndex}) {
    final old = _pane(paneId);
    if (old == null) return;
    final fresh = PaneNode(_nextPaneId++);
    if (tabIndex != null) {
      final id = tabs[tabIndex].id;
      for (final p in panes) {
        if (p.tab == id) p.tab = null;
      }
      fresh.tab = id;
    }
    final before = side == Side.left || side == Side.top;
    layout = replaceNode(
      layout,
      old,
      SplitNode(
        sideBySide: side == Side.left || side == Side.right,
        first: before ? fresh : old,
        second: before ? old : fresh,
      ),
    );
    _fillEmpty(tabIndex ?? 0);
    focus = fresh.id;
    notifyListeners();
  }

  /// Removes pane [paneId]; its tab keeps running, hidden. The last pane
  /// stays.
  void closePane(int paneId) {
    if (!isSplit) return;
    final pane = _pane(paneId);
    if (pane == null) return;
    final parent = parentOf(layout, pane)!;
    final sibling = identical(parent.first, pane)
        ? parent.second
        : parent.first;
    layout = replaceNode(layout, parent, sibling);
    if (focus == paneId) focus = panesOf(sibling).first.id;
    notifyListeners();
  }

  void focusPane(int paneId) {
    if (paneId == focus || _pane(paneId) == null) return;
    focus = paneId;
    notifyListeners();
  }

  /// Shows tab [i] in pane [paneId] (a tab dropped in a pane's middle). A
  /// tab already shown in another pane swaps places with this pane's tab;
  /// a pane left without a tab gets a hidden one, or stays empty.
  void showInPane(int paneId, int i) {
    final target = _pane(paneId);
    if (target == null) return;
    final id = tabs[i].id;
    final from = panes.where((p) => p.tab == id).firstOrNull;
    if (from != null && from != target) from.tab = target.tab;
    target.tab = id;
    _fillEmpty(i);
    focus = paneId;
    notifyListeners();
  }

  /// Moves the divider of [split] to [ratio] (kept between 15 and 85 %).
  void setRatio(SplitNode split, double ratio) {
    split.ratio = ratio.clamp(0.15, 0.85);
    notifyListeners();
  }

  bool alcfLoggedIn = true;
  int _nextId = 0;

  /// Tabs from the previous run, offered once on the empty screen.
  List<SavedTab> _offer;
  Timer? _loginTimer;

  /// Completes when the last store write has finished.
  Future<void> saving = Future.value();

  bool get alcfAvailable => alcf != null;
  double get fontSize => store.fontSize ?? kTermFontSize;
  List<String> get recentFolders => store.recentFolders;
  int get canReopen => _offer.length;

  ProfileStatus statusOf(Profile p) =>
      statuses.firstWhere((s) => s.profile.id == p.id);

  Future<void> refresh() async {
    statuses = [
      for (final p in profiles)
        ProfileStatus(
          p,
          which(p.kind.exe),
          !p.isAlcf || sandbox.isConfigured(p.kind),
        ),
    ];
    alcfLoggedIn = alcf == null ? false : await alcf!.tokenOk();
    notifyListeners();
  }

  /// Re-checks the ALCF login regularly: access tokens last 48 h and the
  /// login itself 30 days, so it can lapse while the app stays open.
  void startLoginChecks([Duration every = const Duration(hours: 3)]) {
    _loginTimer?.cancel();
    _loginTimer = Timer.periodic(every, (_) => refresh());
  }

  @override
  void dispose() {
    _loginTimer?.cancel();
    super.dispose();
  }

  bool canOpen(ProfileStatus s) =>
      s.installed && s.configured && (!s.profile.isAlcf || alcfAvailable);

  /// Cluster and model for an ALCF profile: the one picked in Configure, or
  /// for Claude what alcf-ai wrote into the sandbox settings.
  AgentChoice? choiceFor(Profile p) {
    if (!p.isAlcf) return null;
    final saved = store.choices[p.id];
    if (saved != null) return saved;
    if (p.kind == AgentKind.claude) {
      final env = _claudeEnv();
      final cluster = RegExp(r'resource_server/([^/]+)/')
          .firstMatch('${env['ANTHROPIC_BASE_URL'] ?? ''}')
          ?.group(1);
      final model = env['ANTHROPIC_MODEL'];
      if (cluster != null && model is String) {
        return AgentChoice(cluster, model);
      }
    }
    return null;
  }

  Future<void> recordChoice(Profile p, AgentChoice c) {
    store.choices[p.id] = c;
    _save();
    notifyListeners();
    return saving;
  }

  /// Status of the profile's model on its cluster; null when unknown.
  Future<ModelStatus?> statusFor(Profile p) async {
    final c = choiceFor(p);
    final cli = alcf;
    if (c == null || cli == null) return null;
    return (await cli.modelStatus(c.cluster))[c.model];
  }

  OpenTab _makeTab(Profile p, String cwd, String title) {
    final s = statusOf(p);
    final spec = buildLaunch(
      p,
      sandbox: sandbox,
      parentEnv: parentEnv,
      exePath: s.exePath!,
      cwd: cwd,
      sessionId: const Uuid().v4(),
      args: p.isAlcf
          ? [
              ...alcfCompatArgs(p.kind),
              ...modelArgs(p.kind, sandbox, choiceFor(p)),
            ]
          : const [],
    );
    return OpenTab(
      id: _nextId++,
      title: title,
      profile: p,
      spec: spec,
      route: describeRoute(p),
    );
  }

  void open(Profile p, String cwd) {
    final same = tabs.where((t) => t.profile?.id == p.id).length;
    final title = same == 0 ? p.label : '${p.label} (${same + 1})';
    _offer = [];
    defaultCwd = cwd;
    store.addRecent(cwd);
    _add(_makeTab(p, cwd, title));
  }

  /// Replaces tab [i] with a fresh session of the same agent and folder.
  void restart(int i) {
    final old = tabs[i];
    final p = old.profile;
    if (p == null) {
      tabs[i] = OpenTab(
        id: _nextId++,
        title: old.title,
        profile: null,
        spec: old.spec,
        route: old.route,
      );
    } else {
      tabs[i] = _makeTab(p, old.spec.cwd, old.title);
    }
    final pane = panes.where((p) => p.tab == old.id).firstOrNull;
    (pane ?? focusedPane).tab = tabs[i].id;
    focus = (pane ?? focusedPane).id;
    _save();
    notifyListeners();
  }

  /// Opens the tabs of the previous run whose agent can still start.
  void reopenLast() {
    final saved = _offer;
    _offer = [];
    for (final t in saved) {
      final p = profiles.where((x) => x.id == t.profileId).firstOrNull;
      if (p == null || !canOpen(statusOf(p))) continue;
      if (!Directory(t.cwd).existsSync()) continue;
      open(p, t.cwd);
    }
    notifyListeners();
  }

  /// Opens a tab running `alcf-tokens login inference`.
  void openLogin() {
    final cli = alcf;
    if (cli == null) return;
    final cmd = cli.loginCommand;
    final env = {
      for (final e in parentEnv.entries)
        if (!kStrippedEnvKeys.contains(e.key) &&
            !e.key.startsWith('ANTHROPIC_'))
          e.key: e.value,
    };
    _add(
      OpenTab(
        id: _nextId++,
        title: 'ALCF login',
        profile: null,
        spec: LaunchSpec(
          executable: cmd.first,
          args: cmd.sublist(1),
          env: env,
          cwd: sandbox.realHome,
        ),
        route: 'Signs you in to the ALCF inference service',
      ),
    );
  }

  void _add(OpenTab t) {
    tabs.add(t);
    focusedPane.tab = t.id;
    _save();
    notifyListeners();
  }

  /// Shows tab [i]: focuses the pane already showing it, else puts it in
  /// the focused pane.
  void select(int i) {
    final pane = paneOf(i);
    if (pane != null) {
      focus = pane;
    } else {
      focusedPane.tab = tabs[i].id;
    }
    notifyListeners();
  }

  void close(int i) {
    final id = tabs.removeAt(i).id;
    if (tabs.isEmpty) {
      layout = PaneNode(_nextPaneId++);
      focus = (layout as PaneNode).id;
    } else {
      for (final p in panes.where((p) => p.tab == id).toList()) {
        p.tab = _hiddenFrom(i);
        // A pane whose tab closed and has nothing to show goes away.
        if (p.tab == null) closePane(p.id);
      }
    }
    _save();
    notifyListeners();
  }

  void markExited(OpenTab t, int code) {
    t.exitCode = code;
    notifyListeners();
  }

  /// step +1 / -1 zooms all terminals, 0 resets.
  void zoom(int step) {
    store.fontSize = zoomed(fontSize, step);
    _save();
    notifyListeners();
  }

  void _save() {
    store.lastTabs = [
      for (final t in tabs)
        if (t.profile != null) SavedTab(t.profile!.id, t.spec.cwd),
    ];
    saving = saving.then((_) => store.save()).catchError((_) {});
  }

  /// Plain sentence saying where a profile's requests go.
  String describeRoute(Profile p) {
    if (!p.isAlcf) {
      return 'Anthropic, account in ${_tilde(p.nativeConfigDir!)}';
    }
    final c = choiceFor(p);
    if (c != null) return 'ALCF ${c.cluster}, model ${c.model}';
    return 'ALCF, config in ${_tilde(sandbox.overrideValue(p.kind))}';
  }

  /// The `env` block of the ALCF Claude settings, empty when unreadable.
  Map<String, dynamic> claudeEnv() => _claudeEnv();

  Map<String, dynamic> _claudeEnv() {
    try {
      final f = File('${sandbox.claudeDir}/settings.json');
      final v = jsonDecode(f.readAsStringSync());
      return (v is Map && v['env'] is Map)
          ? Map<String, dynamic>.from(v['env'] as Map)
          : {};
    } on Object {
      return {};
    }
  }

  String _tilde(String path) => path.startsWith(sandbox.realHome)
      ? '~${path.substring(sandbox.realHome.length)}'
      : path;
}
