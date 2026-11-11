import 'dart:convert';

import 'hosts.dart';
import 'runner.dart';

/// What llm-host reports about a host's server (docs/hosts.md).
enum ServerState { stopped, loading, ready, foreign, error }

class HostStatus {
  const HostStatus({
    required this.state,
    this.recipe,
    this.label,
    this.alias,
    this.ctx,
    this.maxOutput,
    this.vision = false,
    required this.port,
    this.pid,
    this.gpuUsedMib,
    this.gpuTotalMib,
    this.error,
  });

  final ServerState state;
  final String? recipe;
  final String? label;
  final String? alias;

  /// The server's per-slot window (from /props when ready).
  final int? ctx;
  final int? maxOutput;
  final bool vision;
  final int port;
  final int? pid;
  final int? gpuUsedMib;
  final int? gpuTotalMib;

  /// The log tail of a failed start, or the foreign-server sentence.
  final String? error;

  factory HostStatus.fromJson(Map<String, dynamic> j) {
    final gpu = j['gpu'];
    return HostStatus(
      state: ServerState.values.byName(j['state'] as String),
      recipe: j['recipe'] as String?,
      label: j['label'] as String?,
      alias: j['alias'] as String?,
      ctx: j['ctx'] as int?,
      maxOutput: j['max_output'] as int?,
      vision: j['vision'] == true,
      port: j['port'] as int,
      pid: j['pid'] as int?,
      gpuUsedMib: gpu is Map ? gpu['used_mib'] as int? : null,
      gpuTotalMib: gpu is Map ? gpu['total_mib'] as int? : null,
      error: j['error'] as String?,
    );
  }
}

/// One launch recipe on a host (`llm-host list`).
class Recipe {
  const Recipe({
    required this.name,
    required this.label,
    required this.ctx,
    required this.maxOutput,
    this.vision = false,
    this.notes = '',
    this.modelPresent = true,
  });

  final String name;
  final String label;
  final int ctx;
  final int maxOutput;
  final bool vision;
  final String notes;
  final bool modelPresent;

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
    name: j['name'] as String,
    label: j['label'] as String,
    ctx: j['ctx'] as int,
    maxOutput: j['max_output'] as int,
    vision: j['vision'] == true,
    notes: (j['notes'] as String?) ?? '',
    modelPresent: j['model_present'] != false,
  );
}

sealed class HostResult<T> {
  const HostResult();
}

class HostOk<T> extends HostResult<T> {
  const HostOk(this.value);
  final T value;
}

/// The host could not be reached (ssh failed or nothing answered).
class HostUnreachable<T> extends HostResult<T> {
  const HostUnreachable(this.message);
  final String message;
}

/// The host answered, but the request failed; [message] is one sentence.
class HostFailed<T> extends HostResult<T> {
  const HostFailed(this.message);
  final String message;
}

/// SSH options for every control command: no prompts, fail fast, and one
/// shared connection per host (ControlMaster) so polling is cheap.
const kSshOptions = [
  '-o',
  'BatchMode=yes',
  '-o',
  'ConnectTimeout=8',
  '-o',
  'ServerAliveInterval=5',
  '-o',
  'ServerAliveCountMax=3',
  '-o',
  'ControlMaster=auto',
  '-o',
  'ControlPersist=120',
];

final _recipeName = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

/// Talks to llm-host on a model host: directly for this machine, through
/// ssh for a remote one.
class HostClient {
  HostClient({
    required this.runner,
    required this.sshExe,
    required this.controlDir,
  });

  final Runner runner;
  final String sshExe;

  /// Folder for ssh control sockets (mode 700).
  final String controlDir;

  /// Polls run every 5 s: a dead link must not hold one for long.
  static const _short = Duration(seconds: 12);

  /// llm-host start waits up to 600 s for the server; leave it room.
  static const _start = Duration(seconds: 630);

  List<String> commandFor(ModelHost h, List<String> args) => switch (h.kind) {
    HostKind.local => [h.llmHostCmd, ...args],
    HostKind.ssh => [
      sshExe,
      ...kSshOptions,
      '-o',
      'ControlPath=$controlDir/%C',
      h.sshTarget!,
      '--',
      h.llmHostCmd,
      ...args,
    ],
  };

  Future<HostResult<HostStatus>> status(ModelHost h) async =>
      _statusCall(h, ['status', '--json'], _short);

  Future<HostResult<List<Recipe>>> recipes(ModelHost h) async {
    final r = await _run(h, ['list', '--json'], _short);
    if (r is! HostOk<RunResult>) return _same(r);
    final res = r.value;
    if (res.exitCode != 0) return HostFailed(_lastLine(res.stderr, h));
    final j = _decode(res.stdout);
    if (j == null) return HostFailed(_unknownFormat(h));
    try {
      return HostOk([
        for (final e in j['recipes'] as List)
          Recipe.fromJson(Map<String, dynamic>.from(e as Map)),
      ]);
    } on Object {
      return HostFailed(_unknownFormat(h));
    }
  }

  Future<HostResult<HostStatus>> start(
    ModelHost h,
    String recipe, {
    bool replace = false,
  }) async {
    if (!_recipeName.hasMatch(recipe)) {
      return HostFailed('"$recipe" is not a valid recipe name');
    }
    return _statusCall(h, [
      'start',
      recipe,
      if (replace) '--replace',
      '--json',
    ], _start);
  }

  Future<HostResult<HostStatus>> stop(ModelHost h) =>
      _statusCall(h, ['stop', '--json'], _short);

  Future<HostResult<String>> logTail(ModelHost h, {int lines = 80}) async {
    final r = await _run(h, ['log', '-n', '$lines'], _short);
    if (r is! HostOk<RunResult>) return _same(r);
    if (r.value.exitCode != 0) return HostFailed(_lastLine(r.value.stderr, h));
    return HostOk(r.value.stdout);
  }

  // ------------------------------------------------------------ internals

  Future<HostResult<HostStatus>> _statusCall(
    ModelHost h,
    List<String> args,
    Duration timeout,
  ) async {
    final r = await _run(h, args, timeout);
    if (r is! HostOk<RunResult>) return _same(r);
    final res = r.value;
    final j = _decode(res.stdout);
    HostStatus? s;
    if (j != null) {
      try {
        s = HostStatus.fromJson(j);
      } on Object {
        s = null;
      }
    }
    switch (res.exitCode) {
      case 0 || 3:
        // 3: start failed; the status carries state error and the log tail.
        return s == null ? HostFailed(_unknownFormat(h)) : HostOk(s);
      case 4:
        return HostFailed(
          '${s?.label ?? s?.recipe ?? 'a model'} is already running on ${h.label}',
        );
      case 5:
        return HostFailed(
          'a llama-server not started by llm-host is using port '
          '${s?.port ?? h.serverPort}',
        );
      case 6:
        return const HostFailed('unknown recipe or missing model file');
      default:
        return HostFailed(_lastLine(res.stderr, h));
    }
  }

  /// Runs llm-host; maps "could not reach" and "not installed" here so each
  /// command only handles real answers.
  Future<HostResult<RunResult>> _run(
    ModelHost h,
    List<String> args,
    Duration timeout,
  ) async {
    final cmd = commandFor(h, args);
    final r = await runner.run(cmd.first, cmd.sublist(1), timeout: timeout);
    if (r.exitCode == 124) {
      return h.isRemote
          ? HostUnreachable('no answer from ${h.label}')
          : HostFailed('llm-host did not answer on ${h.label}');
    }
    if (h.isRemote && r.exitCode == 255) {
      return HostUnreachable(_lastLine(r.stderr, h, 'cannot reach'));
    }
    if (r.exitCode == 127 ||
        r.stderr.contains('command not found') ||
        r.stderr.contains('No such file or directory') && r.stdout.isEmpty) {
      return HostFailed(
        'llm-host is not installed on ${h.label}: see docs/hosts.md',
      );
    }
    return HostOk(r);
  }

  Map<String, dynamic>? _decode(String s) {
    try {
      final v = jsonDecode(s);
      if (v is Map && v['schema'] == 1) return Map<String, dynamic>.from(v);
    } on FormatException {
      // fall through
    }
    return null;
  }

  String _unknownFormat(ModelHost h) =>
      'llm-host on ${h.label} answered in an unknown format: update it';

  String _lastLine(String s, ModelHost h, [String fallback = 'failed']) {
    final lines = s
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return lines.isEmpty ? '$fallback: ${h.label}' : lines.last;
  }

  HostResult<T> _same<T>(HostResult<RunResult> r) => switch (r) {
    HostUnreachable(:final message) => HostUnreachable<T>(message),
    HostFailed(:final message) => HostFailed<T>(message),
    HostOk() => throw StateError('not an error'),
  };
}
