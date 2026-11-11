import 'dart:convert';
import 'dart:io';

import 'package:ai_app/core/hosts.dart';
import 'package:flutter_test/flutter_test.dart';

ModelHost local({String id = 'local', int port = 9931}) => ModelHost(
  id: id,
  label: 'This machine',
  kind: HostKind.local,
  serverPort: port,
);

ModelHost ssh({
  String id = 'pc',
  String label = 'PC',
  String? target = 'pc',
  int? localPort = 19931,
  int serverPort = 9931,
}) => ModelHost(
  id: id,
  label: label,
  kind: HostKind.ssh,
  sshTarget: target,
  serverPort: serverPort,
  localPort: localPort,
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('aiapp_hosts_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('HostRegistry', () {
    test('load returns [] when the file is missing', () async {
      expect(await HostRegistry('${tmp.path}/none/hosts.json').load(), isEmpty);
    });

    test('save then load round-trips, creating the parent dir', () async {
      final path = '${tmp.path}/cfg/ai-app/hosts.json';
      final r = HostRegistry(path);
      await r.save([local(), ssh()]);
      final back = await r.load();
      expect(back.map((h) => h.id), ['local', 'pc']);
      expect(back[1].kind, HostKind.ssh);
      expect(back[1].sshTarget, 'pc');
      expect(back[1].localPort, 19931);
      expect(back[0].llmHostCmd, 'llm-host');
      expect(
        Directory('${tmp.path}/cfg/ai-app').listSync().map((e) => e.path),
        ['$path'],
        reason: 'no temp file left behind',
      );
    });

    test('load skips entries it cannot parse and keeps the rest', () async {
      final path = '${tmp.path}/hosts.json';
      File(path).writeAsStringSync(
        jsonEncode({
          'hosts': [
            {'id': 'x'},
            'junk',
            local().toJson(),
          ],
        }),
      );
      expect((await HostRegistry(path).load()).map((h) => h.id), ['local']);
    });

    test('load of a corrupt file returns []', () async {
      final path = '${tmp.path}/hosts.json';
      File(path).writeAsStringSync('{not json');
      expect(await HostRegistry(path).load(), isEmpty);
    });
  });

  test('baseUrl is always a 127.0.0.1 address', () {
    expect(local().baseUrl, 'http://127.0.0.1:9931');
    expect(local().agentPort, 9931);
    expect(ssh().baseUrl, 'http://127.0.0.1:19931');
    expect(ssh().agentPort, 19931);
  });

  group('validateHost', () {
    test('a valid pair has no problems', () {
      expect(validateHost(ssh(), [local()]), isEmpty);
      expect(validateHost(local(), [ssh()]), isEmpty);
    });

    test('id format and uniqueness', () {
      expect(validateHost(ssh(id: 'PC 1'), []), isNotEmpty);
      expect(validateHost(ssh(id: '-pc'), []), isNotEmpty);
      expect(
        validateHost(ssh(), [ssh(label: 'Other', localPort: 19932)]),
        contains(contains('already')),
      );
    });

    test('ssh target rules', () {
      expect(validateHost(ssh(target: null), []), isNotEmpty);
      expect(validateHost(ssh(target: ''), []), isNotEmpty);
      expect(validateHost(ssh(target: 'a b'), []), isNotEmpty);
      expect(validateHost(ssh(target: '-oProxyCommand=x'), []), isNotEmpty);
      expect(validateHost(ssh(target: 'me@pc.tail1234.ts.net'), []), isEmpty);
    });

    test('ssh local port rules', () {
      expect(validateHost(ssh(localPort: null), []), isNotEmpty);
      expect(validateHost(ssh(localPort: 80), []), isNotEmpty);
      expect(validateHost(ssh(localPort: 70000), []), isNotEmpty);
      expect(
        validateHost(ssh(), [ssh(id: 'mini', label: 'Mini')]),
        contains(contains('19931')),
      );
      expect(validateHost(ssh(localPort: 9931), [local()]), isNotEmpty);
    });

    test('local host has no ssh target', () {
      final h = ModelHost(
        id: 'local',
        label: 'Me',
        kind: HostKind.local,
        serverPort: 9931,
        sshTarget: 'pc',
      );
      expect(validateHost(h, []), isNotEmpty);
    });

    test('label must not be empty', () {
      expect(validateHost(ssh(label: '  '), []), isNotEmpty);
    });
  });

  test('nextLocalPort skips ports in use by other hosts', () {
    expect(nextLocalPort([]), 19931);
    expect(nextLocalPort([local()]), 19931);
    expect(nextLocalPort([ssh(), ssh(id: 'b', localPort: 19932)]), 19933);
    expect(nextLocalPort([ssh(localPort: 19932)]), 19931);
  });

  test('hostIdFromLabel derives a valid id', () {
    expect(hostIdFromLabel('Mini PC'), 'mini-pc');
    expect(hostIdFromLabel('  PC (home)! '), 'pc-home');
    expect(hostIdFromLabel('###'), 'host');
  });

  test('defaultLocalHost is null when llm-host is not installed', () {
    expect(defaultLocalHost((_) => null), isNull);
    final h = defaultLocalHost(
      (exe) => exe == 'llm-host' ? '/x/llm-host' : null,
    )!;
    expect((h.id, h.kind, h.serverPort), ('local', HostKind.local, 9931));
    expect(h.label, 'This machine');
  });
}
