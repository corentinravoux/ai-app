import 'dart:async';
import 'dart:io';

import 'package:ai_app/core/hosts.dart';
import 'package:ai_app/core/tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

const local = ModelHost(
  id: 'local',
  label: 'This machine',
  kind: HostKind.local,
);
const pc = ModelHost(
  id: 'pc',
  label: 'PC',
  kind: HostKind.ssh,
  sshTarget: 'me@pc',
  localPort: 19931,
);

class FakeProc implements Proc {
  final _exit = Completer<int>();
  final _err = StreamController<String>.broadcast();
  bool killed = false;

  @override
  Future<int> get exitCode => _exit.future;
  @override
  Stream<String> get stderrLines => _err.stream;
  @override
  void kill() {
    killed = true;
    exit(-9);
  }

  void exit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void say(String line) => _err.add(line);
}

class Rig {
  Rig({this.probeUp = true});

  bool probeUp;
  final procs = <FakeProc>[];
  final starts = <List<String>>[];
  final sleeps = <Duration>[];
  var now = DateTime(2026, 11, 11);

  /// Each sleep is released by the test, so restarts happen one at a time.
  final _gates = <Completer<void>>[];

  late final m = TunnelManager(
    start: (exe, args) async {
      starts.add([exe, ...args]);
      final p = FakeProc();
      procs.add(p);
      return p;
    },
    probe: (port) async => probeUp,
    sshExe: '/usr/bin/ssh',
    probeEvery: Duration.zero,
    sleep: (d) {
      sleeps.add(d);
      final c = Completer<void>();
      _gates.add(c);
      return c.future;
    },
    now: () => now,
  );

  /// Lets the pending restart run.
  Future<void> release() async {
    _gates.removeAt(0).complete();
    await pump();
  }

  Future<void> pump() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

void main() {
  test('ensure on a local host starts nothing', () async {
    final r = Rig();
    await r.m.ensure(local);
    expect(r.starts, isEmpty);
    expect(r.m.stateOf('local').phase, TunnelPhase.up);
  });

  test('argsFor binds 127.0.0.1 on both sides', () {
    final a = Rig().m.argsFor(pc);
    expect(a.first, '-N');
    expect(
      a,
      containsAllInOrder(['-L', '127.0.0.1:19931:127.0.0.1:9931', 'me@pc']),
    );
    expect(a.last, 'me@pc');
    expect(
      a,
      containsAll([
        'ExitOnForwardFailure=yes',
        'BatchMode=yes',
        'ControlPath=none',
        'ServerAliveInterval=5',
        'ServerAliveCountMax=3',
      ]),
    );
  });

  test('phase goes connecting then up once the probe succeeds', () async {
    final r = Rig(probeUp: false);
    final seen = <TunnelPhase>[];
    r.m.changes.listen((_) => seen.add(r.m.stateOf('pc').phase));
    final f = r.m.ensure(pc);
    await r.pump();
    expect(r.m.stateOf('pc').phase, TunnelPhase.connecting);
    r.probeUp = true;
    await f;
    await r.pump();
    expect(r.m.stateOf('pc').phase, TunnelPhase.up);
    expect(seen, containsAllInOrder([TunnelPhase.connecting, TunnelPhase.up]));
  });

  test('ensure twice starts one process', () async {
    final r = Rig();
    await Future.wait([r.m.ensure(pc), r.m.ensure(pc)]);
    await r.m.ensure(pc);
    expect(r.starts, hasLength(1));
  });

  test('tunnel restarts after the process exits', () async {
    final r = Rig();
    await r.m.ensure(pc);
    r.procs.last.exit(255);
    await r.pump();
    expect(r.m.stateOf('pc').phase, TunnelPhase.down);
    await r.release();
    expect(r.starts, hasLength(2));
    expect(r.m.stateOf('pc').phase, TunnelPhase.up);
  });

  test('backoff is 1,2,4,8,15,15', () async {
    final r = Rig();
    await r.m.ensure(pc);
    for (var i = 0; i < 6; i++) {
      r.procs.last.exit(255);
      await r.pump();
      await r.release();
    }
    expect(r.sleeps.map((d) => d.inSeconds), [1, 2, 4, 8, 15, 15]);
  });

  test('attempt counter resets after 30 s up', () async {
    final r = Rig();
    await r.m.ensure(pc);
    r.procs.last.exit(255);
    await r.pump();
    await r.release(); // slept 1 s, up again
    r.procs.last.exit(255);
    await r.pump();
    await r.release(); // slept 2 s: it was up only 0 s
    r.now = r.now.add(const Duration(seconds: 31));
    r.procs.last.exit(255);
    await r.pump();
    expect(r.sleeps.map((d) => d.inSeconds), [1, 2, 1]);
  });

  test('port in use stops retrying and names the port', () async {
    final r = Rig(probeUp: false);
    final f = r.m.ensure(pc);
    await r.pump();
    r.procs.last.say('bind [127.0.0.1]:19931: Address already in use');
    r.procs.last.say(
      'channel_setup_fwd_listener_tcpip: cannot listen to port: 19931',
    );
    r.procs.last.exit(255);
    await f;
    await r.pump();
    final s = r.m.stateOf('pc');
    expect(s.phase, TunnelPhase.down);
    expect(s.error, 'port 19931 is already in use on this machine');
    expect(r.sleeps, isEmpty);
    expect(r.starts, hasLength(1));
  });

  test('permission denied stops retrying', () async {
    final r = Rig(probeUp: false);
    final f = r.m.ensure(pc);
    await r.pump();
    r.procs.last.say('me@pc: Permission denied (publickey).');
    r.procs.last.exit(255);
    await f;
    await r.pump();
    expect(r.m.stateOf('pc').error, 'SSH key not accepted by me@pc');
    expect(r.sleeps, isEmpty);
  });

  test('other errors keep the last stderr line and retry', () async {
    final r = Rig(probeUp: false);
    final f = r.m.ensure(pc);
    await r.pump();
    r.procs.last.say('ssh: connect to host pc port 22: Connection timed out');
    r.procs.last.exit(255);
    await f;
    await r.pump();
    expect(
      r.m.stateOf('pc').error,
      'ssh: connect to host pc port 22: Connection timed out',
    );
    expect(r.sleeps, hasLength(1));
  });

  test(
    'polling does not retry a fatal error; an explicit retry does',
    () async {
      final r = Rig(probeUp: false);
      final f = r.m.ensure(pc);
      await r.pump();
      r.procs.last.say('Permission denied (publickey).');
      r.procs.last.exit(255);
      await f;
      r.probeUp = true;
      // Polls call ensure() every few seconds: no new ssh login each time.
      await r.m.ensure(pc);
      await r.m.ensure(pc);
      expect(r.starts, hasLength(1));
      expect(r.m.stateOf('pc').error, 'SSH key not accepted by me@pc');
      // Test / Save in the host dialog retry on purpose.
      await r.m.ensure(pc, retry: true);
      expect(r.starts, hasLength(2));
      expect(r.m.stateOf('pc').phase, TunnelPhase.up);
      expect(r.m.stateOf('pc').error, isNull);
    },
  );

  test('close kills the process and cancels the pending restart', () async {
    final r = Rig();
    await r.m.ensure(pc);
    final p = r.procs.last;
    await r.m.close('pc');
    expect(p.killed, isTrue);
    await r.pump();
    expect(r.sleeps, isEmpty, reason: 'no restart after close');
    expect(r.m.stateOf('pc').phase, TunnelPhase.down);

    await r.m.ensure(pc);
    r.procs.last.exit(255);
    await r.pump();
    await r.m.close('pc');
    await r.release();
    expect(r.starts, hasLength(2), reason: 'pending restart cancelled');
  });

  test(
    'real processes: a stand-in ssh that listens comes up, then is killed',
    () async {
      final tmp = Directory.systemTemp.createTempSync('aiapp_tunnel_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final fake = File('${tmp.path}/ssh')
        ..writeAsStringSync(r'''#!/bin/sh
# stand-in for ssh -N -L 127.0.0.1:PORT:...: listen on PORT
for a in "$@"; do case "$a" in 127.0.0.1:*:127.0.0.1:*) spec="$a";; esac; done
port=$(echo "$spec" | cut -d: -f2)
exec python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', $port)); s.listen(); time.sleep(60)"
''');
      Process.runSync('chmod', ['+x', fake.path]);
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final port = probe.port;
      await probe.close();
      final m = TunnelManager(
        start: startIoProc,
        probe: tcpProbe,
        sshExe: fake.path,
      );
      final h = pc.copyWith(localPort: port);
      await m.ensure(h);
      expect(m.stateOf('pc').phase, TunnelPhase.up);
      expect(await tcpProbe(port), isTrue);
      await m.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await tcpProbe(port), isFalse);
    },
  );

  test('a port that already answers is refused before ssh starts', () async {
    final starts = <List<String>>[];
    final m = TunnelManager(
      start: (exe, args) async {
        starts.add(args);
        return FakeProc();
      },
      probe: (_) async => true,
      sshExe: '/usr/bin/ssh',
      probeEvery: Duration.zero,
      portInUse: (port) async => port == 19931,
    );
    await m.ensure(pc);
    expect(starts, isEmpty);
    expect(m.stateOf('pc').phase, TunnelPhase.down);
    expect(
      m.stateOf('pc').error,
      'port 19931 is already in use on this machine',
    );
    // fatal: polling does not try again, an explicit retry checks again
    await m.ensure(pc);
    expect(starts, isEmpty);
    await m.ensure(pc.copyWith(localPort: 19932), retry: true);
    expect(starts, hasLength(1));
    expect(m.stateOf('pc').phase, TunnelPhase.up);
    await m.dispose();
  });

  test('a forward started after close is killed, not left running', () async {
    final gate = Completer<void>();
    final procs = <FakeProc>[];
    final m = TunnelManager(
      start: (exe, args) async {
        await gate.future;
        final p = FakeProc();
        procs.add(p);
        return p;
      },
      probe: (_) async => true,
      sshExe: '/usr/bin/ssh',
      probeEvery: Duration.zero,
    );
    final f = m.ensure(pc);
    await Future<void>.delayed(Duration.zero);
    await m.close('pc'); // ssh has not started yet: nothing to kill here
    gate.complete();
    await f;
    expect(procs.single.killed, isTrue);
    expect(m.stateOf('pc').phase, TunnelPhase.down);
    await m.dispose();
  });

  test('dispose closes all', () async {
    final r = Rig();
    await r.m.ensure(pc);
    await r.m.ensure(pc.copyWith(localPort: 19932).withId('mini'));
    await r.m.dispose();
    expect(r.procs.every((p) => p.killed), isTrue);
  });

  test('ssh target comes after --', () {
    final a = Rig().m.argsFor(pc);
    expect(a.sublist(a.length - 2), ['--', 'me@pc']);
  });
}

extension on ModelHost {
  ModelHost withId(String id) => ModelHost(
    id: id,
    label: label,
    kind: kind,
    sshTarget: sshTarget,
    serverPort: serverPort,
    localPort: localPort,
  );
}
