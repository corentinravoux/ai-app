import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hosts.dart';

/// A running process the supervisor watches (an `ssh -N -L` forward).
abstract class Proc {
  Future<int> get exitCode;
  Stream<String> get stderrLines;
  void kill();
}

typedef ProcStarter = Future<Proc> Function(String exe, List<String> args);

/// True when a TCP connect to `127.0.0.1:port` succeeds.
typedef PortProbe = Future<bool> Function(int port);

class _IoProc implements Proc {
  _IoProc(this._p)
    : stderrLines = _p.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream() {
    _p.stdout.drain<void>().ignore();
  }

  final Process _p;
  @override
  final Stream<String> stderrLines;
  @override
  Future<int> get exitCode => _p.exitCode;
  @override
  void kill() => _p.kill();
}

Future<Proc> startIoProc(String exe, List<String> args) async =>
    _IoProc(await Process.start(exe, args));

Future<bool> tcpProbe(int port) async {
  try {
    final s = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(seconds: 1),
    );
    s.destroy();
    return true;
  } on Object {
    return false;
  }
}

enum TunnelPhase { down, connecting, up }

class TunnelState {
  const TunnelState(this.phase, [this.error]);
  final TunnelPhase phase;
  final String? error;
}

/// Seconds between restarts; the last value repeats.
const kTunnelBackoff = [1, 2, 4, 8, 15];

class _Tunnel {
  _Tunnel(this.host);
  ModelHost host;
  TunnelPhase phase = TunnelPhase.down;
  String? error;
  Proc? proc;
  int attempt = 0;
  DateTime? upSince;
  bool closed = false;
  bool fatal = false;
  bool restarting = false;
  Future<void>? connecting;
}

/// Keeps one `ssh -N -L 127.0.0.1:<localPort>:127.0.0.1:<serverPort>`
/// forward open per remote host, restarting it with backoff when it dies.
/// Local hosts need no forward and always report [TunnelPhase.up].
class TunnelManager {
  TunnelManager({
    required this._start,
    required this._probe,
    required this.sshExe,
    Duration Function(int attempt)? delay,
    this.probeEvery = const Duration(milliseconds: 250),
    this.probeTries = 40,
    this.resetAfter = const Duration(seconds: 30),
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  }) : _delay =
           delay ??
           ((a) => Duration(
             seconds:
                 kTunnelBackoff[a < kTunnelBackoff.length
                     ? a
                     : kTunnelBackoff.length - 1],
           )),
       _sleep = sleep ?? Future<void>.delayed,
       _now = now ?? DateTime.now;

  final ProcStarter _start;
  final PortProbe _probe;
  final String sshExe;
  final Duration Function(int attempt) _delay;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;
  final Duration probeEvery;

  /// Probes before a forward that never listens is killed (40 × 250 ms).
  final int probeTries;

  /// A forward up this long counts as healthy: the backoff starts over.
  final Duration resetAfter;

  final _tunnels = <String, _Tunnel>{};
  final _changes = StreamController<String>.broadcast();

  /// Host ids whose [stateOf] changed.
  Stream<String> get changes => _changes.stream;

  List<String> argsFor(ModelHost h) => [
    '-N',
    '-o',
    'ExitOnForwardFailure=yes',
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=8',
    '-o',
    'ServerAliveInterval=15',
    '-o',
    'ServerAliveCountMax=3',
    '-o',
    'ControlPath=none',
    '-L',
    '127.0.0.1:${h.localPort}:127.0.0.1:${h.serverPort}',
    h.sshTarget!,
  ];

  TunnelState stateOf(String hostId) {
    final t = _tunnels[hostId];
    if (t == null) return const TunnelState(TunnelPhase.down);
    if (!t.host.isRemote) return const TunnelState(TunnelPhase.up);
    return TunnelState(t.phase, t.error);
  }

  /// Makes sure [h]'s forward is up or coming up. Completes when it is up,
  /// or when this attempt failed (see [stateOf] for why).
  Future<void> ensure(ModelHost h) async {
    final t = _tunnels.putIfAbsent(h.id, () => _Tunnel(h));
    t.host = h;
    t.closed = false;
    if (!h.isRemote) {
      t.phase = TunnelPhase.up;
      return;
    }
    if (t.connecting != null) return t.connecting;
    if (t.phase == TunnelPhase.up || t.restarting) return;
    // A fresh request after a fatal error (key fixed, port freed) retries.
    t.fatal = false;
    t.attempt = 0;
    return _connect(t);
  }

  Future<void> _connect(_Tunnel t) {
    final f = _doConnect(t);
    t.connecting = f;
    return f.whenComplete(() => t.connecting = null);
  }

  Future<void> _doConnect(_Tunnel t) async {
    t.phase = TunnelPhase.connecting;
    t.error = null;
    _notify(t);
    final Proc p;
    try {
      p = await _start(sshExe, argsFor(t.host));
    } on Object catch (e) {
      t.phase = TunnelPhase.down;
      t.error = 'cannot start ssh: $e';
      _notify(t);
      return;
    }
    t.proc = p;
    String? last;
    p.stderrLines.listen((line) {
      if (line.trim().isEmpty) return;
      last = line.trim();
      if (line.contains('Address already in use') ||
          line.contains('cannot listen to port')) {
        t.fatal = true;
        t.error = 'port ${t.host.localPort} is already in use on this machine';
      } else if (line.contains('Permission denied')) {
        t.fatal = true;
        t.error = 'SSH key not accepted by ${t.host.sshTarget}';
      }
    });
    var exited = false;
    p.exitCode.then((_) {
      exited = true;
      _onExit(t, p, () => last);
    });

    for (var i = 0; i < probeTries && !exited && !t.closed; i++) {
      if (await _probe(t.host.localPort!)) {
        if (exited || t.closed) return;
        t.phase = TunnelPhase.up;
        t.upSince = _now();
        t.error = null;
        _notify(t);
        return;
      }
      await Future<void>.delayed(probeEvery);
    }
    if (!exited && !t.closed) {
      t.error ??= 'the forward to ${t.host.label} never opened';
      p.kill();
    }
    // Wait for the exit handler so callers see the final state.
    await p.exitCode;
    await Future<void>.delayed(Duration.zero);
  }

  void _onExit(_Tunnel t, Proc p, String? Function() last) {
    if (!identical(t.proc, p)) return;
    t.proc = null;
    final wasUp = t.upSince;
    t.upSince = null;
    t.phase = TunnelPhase.down;
    if (t.closed) {
      _notify(t);
      return;
    }
    if (!t.fatal) t.error = last() ?? t.error ?? 'the forward closed';
    _notify(t);
    if (t.fatal) return;
    if (wasUp != null && _now().difference(wasUp) >= resetAfter) {
      t.attempt = 0;
    }
    final d = _delay(t.attempt);
    t.attempt++;
    t.restarting = true;
    _sleep(d).then((_) {
      t.restarting = false;
      if (t.closed || t.proc != null || t.connecting != null) return;
      _connect(t);
    });
  }

  /// Stops [hostId]'s forward and any pending restart.
  Future<void> close(String hostId) async {
    final t = _tunnels[hostId];
    if (t == null) return;
    t.closed = true;
    final p = t.proc;
    t.proc = null;
    t.phase = TunnelPhase.down;
    p?.kill();
    _notify(t);
  }

  Future<void> dispose() async {
    for (final id in _tunnels.keys.toList()) {
      await close(id);
    }
    await _changes.close();
  }

  void _notify(_Tunnel t) {
    if (!_changes.isClosed) _changes.add(t.host.id);
  }
}
