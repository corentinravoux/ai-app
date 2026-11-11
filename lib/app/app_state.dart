import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'layout.dart';

import '../core/agents.dart';
import '../core/alcf_cli.dart';
import '../core/app_store.dart';
import '../core/guard.dart';
import '../core/host_client.dart';
import '../core/hosts.dart';
import '../core/launch.dart';
import '../core/local_launch.dart';
import '../core/profiles.dart';
import '../core/pty.dart';
import '../core/sandbox.dart';
import '../core/term_tools.dart';
import '../core/tunnel.dart';

class ProfileStatus {
  const ProfileStatus(this.profile, this.exePath, this.configured);
  final Profile profile;
  final String? exePath;

  /// Native and local profiles are always configured.
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
    required List<Profile> profiles,
    required this.which,
    required this.sandbox,
    required this.alcf,
    required this.start,
    required this.parentEnv,
    required this.defaultCwd,
    required this.store,
    List<ModelHost> hosts = const [],
    this.hostClient,
    this.tunnels,
    this.registry,
    this.dataRoot = '',
    this.guardedRoots = const [],
    this.guardPaths = const [],
    this.sshAvailable = true,
  }) : baseProfiles = profiles,
       hosts = List.of(hosts),
       _offer = List.of(store.lastTabs) {
    tunnels?.changes.listen((_) => notifyListeners());
  }

  /// ALCF and native profiles; local ones come from [hosts].
  final List<Profile> baseProfiles;

  List<Profile> get profiles => [...baseProfiles, ...localProfiles(hosts)];

  /// Model hosts (hosts.dart), in sidebar order.
  final List<ModelHost> hosts;

  /// Null when the app runs without model-host support (tests, ALCF only).
  final HostClient? hostClient;
  final TunnelManager? tunnels;
  final HostRegistry? registry;

  /// `~/.local/share/ai-app`: local sandboxes and the tools folder.
  final String dataRoot;

  /// The user's real agent config folders; never written into.
  final List<String> guardedRoots;

  /// Files hashed around every local launch (RealConfigGuard).
  final List<String> guardPaths;

  /// False when ssh is missing: remote hosts cannot be reached.
  final bool sshAvailable;
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
    _pollTimer?.cancel();
    tunnels?.dispose();
    super.dispose();
  }

  bool canOpen(ProfileStatus s) {
    if (!s.installed) return false;
    if (s.profile.isLocal) return readinessOf(s.profile) is LocalReady;
    return s.configured && (!s.profile.isAlcf || alcfAvailable);
  }

  // ------------------------------------------------------------ model hosts

  /// A sentence for the user (a local tab that could not restart); the
  /// home page shows it once and clears it.
  String? notice;

  final _hostStatus = <String, HostStatus>{};
  final _hostProblem = <String, String>{};

  /// Hosts whose last problem was "could not reach" (vs "llm-host failed").
  final _unreachable = <String>{};
  final _recipes = <String, List<Recipe>>{};
  final _inFlight = <String>{};
  final _lastPoll = <String, DateTime>{};
  Timer? _pollTimer;

  ModelHost? hostById(String? id) => hosts.where((h) => h.id == id).firstOrNull;

  /// The host's last status; null while unknown or unreachable.
  HostStatus? statusOfHost(String hostId) => _hostStatus[hostId];

  /// Why the host gave no status (unreachable, llm-host missing…).
  String? unreachableReason(String hostId) => _hostProblem[hostId];

  List<Recipe> recipesOf(String hostId) => _recipes[hostId] ?? const [];

  TunnelState tunnelOf(String hostId) =>
      tunnels?.stateOf(hostId) ?? const TunnelState(TunnelPhase.down);

  LocalReadiness readinessOf(Profile p) {
    final h = hostById(p.hostId);
    if (h == null) return const LocalBlocked('This host was removed');
    final problem = _hostProblem[h.id];
    final s = _hostStatus[h.id];
    if (s == null && problem != null && !_unreachable.contains(h.id)) {
      // llm-host missing or answering garbage: say so, not "unreachable".
      return LocalBlocked(problem);
    }
    return localReadiness(p.kind, h, s);
  }

  int openTabsOn(String hostId) =>
      tabs.where((t) => t.running && t.profile?.hostId == hostId).length;

  /// Asks llm-host for the host's status (and its recipes the first time),
  /// opening the ssh forward first for a remote host.
  Future<void> refreshHost(String hostId) async {
    final h = hostById(hostId);
    final client = hostClient;
    if (h == null || client == null || !_inFlight.add(hostId)) return;
    try {
      _lastPoll[hostId] = DateTime.now();
      if (h.isRemote && !sshAvailable) {
        _setProblem(h, 'ssh is not installed', reachable: true);
        return;
      }
      if (h.isRemote) await tunnels?.ensure(h);
      final r = await client.status(h);
      switch (r) {
        case HostOk(:final value):
          _hostStatus[hostId] = value;
          _hostProblem.remove(hostId);
          _unreachable.remove(hostId);
          if (!_recipes.containsKey(hostId)) await refreshRecipes(hostId);
        case HostUnreachable(:final message):
          _setProblem(h, message);
        case HostFailed(:final message):
          _setProblem(h, message, reachable: true);
      }
    } finally {
      _inFlight.remove(hostId);
      notifyListeners();
    }
  }

  void _setProblem(ModelHost h, String message, {bool reachable = false}) {
    _hostStatus.remove(h.id);
    _hostProblem[h.id] = message;
    if (reachable) {
      _unreachable.remove(h.id);
    } else {
      _unreachable.add(h.id);
    }
  }

  Future<void> refreshRecipes(String hostId) async {
    final h = hostById(hostId);
    final client = hostClient;
    if (h == null || client == null) return;
    final r = await client.recipes(h);
    if (r case HostOk(:final value)) _recipes[hostId] = value;
    notifyListeners();
  }

  /// Polls every host: every 5 s, every 2 s while a model loads.
  void startHostPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      for (final h in hosts) {
        final loading = _hostStatus[h.id]?.state == ServerState.loading;
        final every = Duration(seconds: loading ? 2 : 5);
        final last = _lastPoll[h.id];
        if (last == null || now.difference(last) >= every) {
          refreshHost(h.id);
        }
      }
    });
  }

  /// Starts [recipe] on the host (replacing what runs). Returns null on
  /// success, else the text to show: the log tail of a failed start, or
  /// one sentence.
  Future<String?> startModel(String hostId, String recipe) async {
    final h = hostById(hostId);
    final client = hostClient;
    if (h == null || client == null) return 'Unknown host';
    final cur = _hostStatus[hostId]?.state;
    _hostStatus[hostId] = HostStatus(
      state: ServerState.loading,
      recipe: recipe,
      label: recipesOf(hostId)
          .where((r) => r.name == recipe)
          .firstOrNull
          ?.label,
      port: h.serverPort,
    );
    notifyListeners();
    final r = await client.start(
      h,
      recipe,
      replace: cur == ServerState.ready || cur == ServerState.loading,
    );
    String? out;
    switch (r) {
      case HostOk(:final value):
        _hostStatus[hostId] = value;
        if (value.state == ServerState.error) {
          out = value.error ?? 'The model failed to start';
        }
      case HostUnreachable(:final message):
        out = message;
      case HostFailed(:final message):
        out = message;
    }
    await refreshHost(hostId);
    return out;
  }

  Future<String?> stopModel(String hostId) async {
    final h = hostById(hostId);
    final client = hostClient;
    if (h == null || client == null) return 'Unknown host';
    final r = await client.stop(h);
    String? out;
    switch (r) {
      case HostOk(:final value):
        _hostStatus[hostId] = value;
      case HostUnreachable(:final message):
        out = message;
      case HostFailed(:final message):
        out = message;
    }
    notifyListeners();
    return out;
  }

  Future<String> logTail(String hostId) async {
    final h = hostById(hostId);
    final client = hostClient;
    if (h == null || client == null) return '';
    return switch (await client.logTail(h)) {
      HostOk(:final value) => value.isEmpty ? '(the log is empty)' : value,
      HostUnreachable(:final message) => message,
      HostFailed(:final message) => message,
    };
  }

  /// Opens a local profile in a new tab. Returns null on success, else the
  /// reason it cannot open.
  Future<String?> openLocal(Profile p, String cwd, {String? title}) async {
    final tab = await _makeLocalTab(p, cwd, title ?? _titleFor(p));
    if (tab is String) return tab;
    _offer = [];
    defaultCwd = cwd;
    store.addRecent(cwd);
    _add(tab as OpenTab);
    return null;
  }

  /// An [OpenTab], or a String saying why not.
  Future<Object> _makeLocalTab(Profile p, String cwd, String title) async {
    final h = hostById(p.hostId);
    if (h == null) return 'This host was removed';
    final exe = which(p.kind.exe);
    if (exe == null) return '${p.kind.exe} is not installed';
    await refreshHost(h.id);
    final r = readinessOf(p);
    if (r is LocalBlocked) return r.reason;
    final target = (r as LocalReady).target;
    final guard = RealConfigGuard(guardPaths);
    final before = await guard.snapshot();
    final LaunchSpec spec;
    try {
      spec = await buildLocalLaunch(
        p,
        host: h,
        target: target,
        dataRoot: dataRoot,
        parentEnv: parentEnv,
        exePath: exe,
        cwd: cwd,
        toolsBinDir: '$dataRoot/bin',
        guardedRoots: guardedRoots,
      );
    } on StateError catch (e) {
      return e.message;
    }
    final changed = await guard.changedSince(before);
    if (changed.isNotEmpty) {
      return 'A real config file changed: ${changed.join(', ')}';
    }
    return OpenTab(
      id: _nextId++,
      title: title,
      profile: p,
      spec: spec,
      route:
          '${h.label}, model ${target.alias} (${target.ctx ~/ 1024}K window)',
    );
  }

  String _titleFor(Profile p) {
    final same = tabs.where((t) => t.profile?.id == p.id).length;
    return same == 0 ? p.label : '${p.label} (${same + 1})';
  }

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
    if (p.isLocal) {
      openLocal(p, cwd);
      return;
    }
    final title = _titleFor(p);
    _offer = [];
    defaultCwd = cwd;
    store.addRecent(cwd);
    _add(_makeTab(p, cwd, title));
  }

  /// Replaces tab [i] with a fresh session of the same agent and folder.
  /// A local tab gets a config rebuilt from the host's current model.
  Future<void> restart(int i) async {
    final old = tabs[i];
    final p = old.profile;
    if (p != null && p.isLocal) {
      final t = await _makeLocalTab(p, old.spec.cwd, old.title);
      if (t is! OpenTab) {
        notice = t as String;
        notifyListeners();
        return;
      }
      final at = tabs.indexWhere((x) => x.id == old.id);
      if (at < 0) return;
      tabs[at] = t;
      final pane = panes.where((x) => x.tab == old.id).firstOrNull;
      (pane ?? focusedPane).tab = t.id;
      focus = (pane ?? focusedPane).id;
      _save();
      notifyListeners();
      return;
    }
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
    if (p.isLocal) {
      final h = hostById(p.hostId);
      final s = h == null ? null : _hostStatus[h.id];
      final model = s?.alias ?? s?.recipe;
      return model == null
          ? (h?.label ?? 'a removed host')
          : '${h!.label}, model $model';
    }
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
