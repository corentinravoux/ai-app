import 'dart:convert';

import 'package:ai_app/core/host_client.dart';
import 'package:ai_app/core/hosts.dart';
import 'package:ai_app/core/runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_runner.dart';

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

Map<String, dynamic> statusJson({
  String state = 'ready',
  Object? gpu = const {
    'name': 'RTX 3060',
    'used_mib': 10035,
    'total_mib': 12288,
  },
  String? error,
}) => {
  'schema': 1,
  'host': 'pc',
  'state': state,
  'recipe': 'qwen36-35b-64k',
  'label': 'Qwen3.6 35B-A3B · 64K',
  'alias': 'qwen36-35b-64k',
  'ctx': 65536,
  'max_output': 8192,
  'vision': false,
  'port': 9931,
  'pid': 1234,
  'started': '2026-11-11T16:58:02+00:00',
  'gpu': gpu,
  'error': error,
};

RunResult ok(Object json, [int code = 0]) =>
    RunResult(code, jsonEncode(json), '');

HostClient client(FakeRunner r) =>
    HostClient(runner: r, sshExe: '/usr/bin/ssh', controlDir: '/c');

void main() {
  test('commandFor local has no ssh', () {
    expect(client(FakeRunner()).commandFor(local, ['status', '--json']), [
      'llm-host',
      'status',
      '--json',
    ]);
  });

  test(
    'commandFor ssh puts options before the target and -- before the command',
    () {
      final c = client(FakeRunner()).commandFor(pc, ['status', '--json']);
      expect(c.first, '/usr/bin/ssh');
      expect(c.sublist(1, 1 + kSshOptions.length), kSshOptions);
      final t = c.indexOf('me@pc');
      expect(c[t - 1], 'ControlPath=/c/%C');
      expect(c.sublist(t + 1), ['--', 'llm-host', 'status', '--json']);
    },
  );

  test('status parses every field', () async {
    final r = FakeRunner({'llm-host status': (_) => ok(statusJson())});
    final s = (await client(r).status(local) as HostOk<HostStatus>).value;
    expect(s.state, ServerState.ready);
    expect(
      (s.recipe, s.label, s.alias),
      ('qwen36-35b-64k', 'Qwen3.6 35B-A3B · 64K', 'qwen36-35b-64k'),
    );
    expect(
      (s.ctx, s.maxOutput, s.vision, s.port, s.pid),
      (65536, 8192, false, 9931, 1234),
    );
    expect((s.gpuUsedMib, s.gpuTotalMib), (10035, 12288));
    expect(s.error, isNull);
    expect(r.calls.single.args, ['status', '--json']);
    expect(r.calls.single.timeout, const Duration(seconds: 12));
  });

  test('gpu null leaves both gpu fields null', () async {
    final r = FakeRunner({'llm-host status': (_) => ok(statusJson(gpu: null))});
    final s = (await client(r).status(local) as HostOk<HostStatus>).value;
    expect((s.gpuUsedMib, s.gpuTotalMib), (null, null));
  });

  test('ssh exit 255 maps to HostUnreachable', () async {
    final r = FakeRunner({
      '/usr/bin/ssh': (_) => const RunResult(
        255,
        '',
        'ssh: connect to host pc port 22: No route to host\n',
      ),
    });
    final res = await client(r).status(pc);
    expect(res, isA<HostUnreachable<HostStatus>>());
    expect((res as HostUnreachable).message, contains('No route to host'));
  });

  test('timeout maps to HostUnreachable', () async {
    final r = FakeRunner({
      '/usr/bin/ssh': (_) => const RunResult(124, '', 'timed out'),
    });
    final res = await client(r).status(pc);
    expect((res as HostUnreachable).message, 'no answer from PC');
  });

  test('missing llm-host maps to HostFailed with the docs hint', () async {
    final r = FakeRunner({
      '/usr/bin/ssh': (_) =>
          const RunResult(127, '', 'bash: llm-host: command not found'),
    });
    final res = await client(r).status(pc);
    expect(
      (res as HostFailed).message,
      'llm-host is not installed on PC: see docs/hosts.md',
    );
    final r2 = FakeRunner({
      'llm-host': (_) => const RunResult(127, '', 'No such file'),
    });
    expect(await client(r2).status(local), isA<HostFailed<HostStatus>>());
  });

  test(
    'start exit 3 returns HostOk with state error and the log tail',
    () async {
      final r = FakeRunner({
        'llm-host start': (_) =>
            ok(statusJson(state: 'error', error: 'cudaMalloc failed'), 3),
      });
      final s = (await client(
        r,
      ).start(local, 'qwen36-35b-64k') as HostOk<HostStatus>).value;
      expect(s.state, ServerState.error);
      expect(s.error, 'cudaMalloc failed');
      expect(r.calls.single.timeout, const Duration(seconds: 630));
    },
  );

  test('start exits 4, 5, 6 map to their messages', () async {
    Future<String> msg(int code) async {
      final r = FakeRunner({'llm-host start': (_) => ok(statusJson(), code)});
      return ((await client(r).start(local, 'x')) as HostFailed).message;
    }

    expect(await msg(4), contains('already running'));
    expect(
      await msg(5),
      'a llama-server not started by llm-host is using port 9931',
    );
    expect(await msg(6), 'unknown recipe or missing model file');
  });

  test('start passes --replace only when asked', () async {
    final r = FakeRunner({'llm-host start': (_) => ok(statusJson())});
    await client(r).start(local, 'a');
    await client(r).start(local, 'b', replace: true);
    expect(r.calls[0].args, ['start', 'a', '--json']);
    expect(r.calls[1].args, ['start', 'b', '--replace', '--json']);
  });

  test('stop and logTail', () async {
    final r = FakeRunner({
      'llm-host stop': (_) => ok(statusJson(state: 'stopped')),
      'llm-host log': (_) => const RunResult(0, 'line1\nline2\n', ''),
    });
    final s = (await client(r).stop(local) as HostOk<HostStatus>).value;
    expect(s.state, ServerState.stopped);
    final log =
        (await client(r).logTail(local, lines: 2) as HostOk<String>).value;
    expect(log, 'line1\nline2\n');
    expect(r.calls.last.args, ['log', '-n', '2']);
  });

  test('stop exit 5 is a HostFailed naming the foreign server', () async {
    final r = FakeRunner({
      'llm-host stop': (_) => ok(statusJson(state: 'foreign'), 5),
    });
    expect(
      ((await client(r).stop(local)) as HostFailed).message,
      contains('not started by llm-host'),
    );
  });

  test('recipes parses the list and ignores the invalid array', () async {
    final r = FakeRunner({
      'llm-host list': (_) => ok({
        'schema': 1,
        'recipes': [
          {
            'name': 'qwen36-35b-64k',
            'label': 'Qwen 64K',
            'model': 'x.gguf',
            'ctx': 65536,
            'max_output': 8192,
            'vision': false,
            'notes': 'n',
            'model_present': true,
          },
          {
            'name': 'gone',
            'label': 'Gone',
            'model': 'y.gguf',
            'ctx': 4096,
            'max_output': 512,
            'vision': true,
            'notes': '',
            'model_present': false,
          },
        ],
        'invalid': [
          {'name': 'bad', 'reason': 'x'},
        ],
      }),
    });
    final list = (await client(r).recipes(local) as HostOk<List<Recipe>>).value;
    expect(list.map((x) => x.name), ['qwen36-35b-64k', 'gone']);
    expect(
      (list[0].ctx, list[0].maxOutput, list[0].modelPresent),
      (65536, 8192, true),
    );
    expect((list[1].vision, list[1].modelPresent), (true, false));
  });

  test('a recipe name with a space or a semicolon is rejected before any process runs', () async {
    final r = FakeRunner();
    expect(await client(r).start(pc, 'a b'), isA<HostFailed<HostStatus>>());
    expect(
      await client(r).start(pc, 'a;rm -rf ~'),
      isA<HostFailed<HostStatus>>(),
    );
    expect(r.calls, isEmpty);
  });

  test('unknown schema maps to HostFailed', () async {
    final r = FakeRunner({
      'llm-host status': (_) => ok({...statusJson(), 'schema': 2}),
      'llm-host list': (_) => const RunResult(0, 'not json', ''),
    });
    final a = await client(r).status(local);
    expect((a as HostFailed).message, contains('unknown format'));
    expect(await client(r).recipes(local), isA<HostFailed<List<Recipe>>>());
  });

  test('without ControlMaster (Windows) no control options are passed', () {
    final c = HostClient(
      runner: FakeRunner(),
      sshExe: 'ssh',
      controlDir: '/c',
      controlMaster: false,
    ).commandFor(pc, ['status', '--json']);
    expect(c.where((a) => a.startsWith('Control')), isEmpty);
    expect(c, containsAllInOrder(['BatchMode=yes', 'me@pc', '--', 'llm-host']));
  });

  test('dead links are noticed within about 15 s', () {
    expect(kSshOptions, containsAllInOrder(['-o', 'ServerAliveInterval=5']));
    expect(kSshOptions, containsAllInOrder(['-o', 'ServerAliveCountMax=3']));
  });
}
