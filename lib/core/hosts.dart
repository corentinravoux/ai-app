import 'dart:convert';
import 'dart:io';

import 'launch.dart' show Which;

/// How the app reaches a model host's llm-host.
enum HostKind { local, ssh }

/// A machine running llama-server under llm-host (docs/hosts.md).
///
/// Agents always talk to `127.0.0.1`: directly on [serverPort] for the
/// local machine, or through an `ssh -L` forward on [localPort] for a
/// remote host.
class ModelHost {
  const ModelHost({
    required this.id,
    required this.label,
    required this.kind,
    this.sshTarget,
    this.serverPort = 9931,
    this.localPort,
    this.llmHostCmd = 'llm-host',
  });

  final String id;
  final String label;
  final HostKind kind;

  /// `user@host` or an `~/.ssh/config` name; ssh hosts only.
  final String? sshTarget;

  /// llama-server's port on the host itself.
  final int serverPort;

  /// The forward's port on this machine; ssh hosts only.
  final int? localPort;

  /// How to call llm-host on the host (a name on PATH or an absolute path).
  final String llmHostCmd;

  int get agentPort => kind == HostKind.local ? serverPort : localPort!;

  String get baseUrl => 'http://127.0.0.1:$agentPort';

  bool get isRemote => kind == HostKind.ssh;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'kind': kind.name,
    if (sshTarget != null) 'sshTarget': sshTarget,
    'serverPort': serverPort,
    if (localPort != null) 'localPort': localPort,
    'llmHostCmd': llmHostCmd,
  };

  factory ModelHost.fromJson(Map<String, dynamic> j) => ModelHost(
    id: j['id'] as String,
    label: j['label'] as String,
    kind: HostKind.values.byName(j['kind'] as String),
    sshTarget: j['sshTarget'] as String?,
    serverPort: (j['serverPort'] as int?) ?? 9931,
    localPort: j['localPort'] as int?,
    llmHostCmd: (j['llmHostCmd'] as String?) ?? 'llm-host',
  );

  ModelHost copyWith({
    String? label,
    HostKind? kind,
    String? sshTarget,
    int? serverPort,
    int? localPort,
    String? llmHostCmd,
  }) => ModelHost(
    id: id,
    label: label ?? this.label,
    kind: kind ?? this.kind,
    sshTarget: sshTarget ?? this.sshTarget,
    serverPort: serverPort ?? this.serverPort,
    localPort: localPort ?? this.localPort,
    llmHostCmd: llmHostCmd ?? this.llmHostCmd,
  );
}

/// The list of model hosts, `~/.config/ai-app/hosts.json`.
class HostRegistry {
  HostRegistry(this.path);

  final String path;

  /// Hosts in file order; unreadable entries (or a corrupt file) are skipped.
  Future<List<ModelHost>> load() async {
    final f = File(path);
    if (!await f.exists()) return [];
    Object? v;
    try {
      v = jsonDecode(await f.readAsString());
    } on FormatException {
      return [];
    }
    final list = v is Map ? v['hosts'] : null;
    if (list is! List) return [];
    final out = <ModelHost>[];
    for (final e in list) {
      try {
        out.add(ModelHost.fromJson(Map<String, dynamic>.from(e as Map)));
      } on Object {
        // Skip what we cannot read; keep the others.
      }
    }
    return out;
  }

  /// Writes atomically (temp file + rename), creating the folder.
  Future<void> save(List<ModelHost> hosts) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'hosts': [for (final h in hosts) h.toJson()],
      }),
    );
    await tmp.rename(path);
  }
}

final _idRe = RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$');

/// Problems with [h] given the [others] hosts, as plain sentences; empty
/// when [h] can be saved.
List<String> validateHost(ModelHost h, List<ModelHost> others) {
  final p = <String>[];
  if (h.label.trim().isEmpty) p.add('Give the host a name.');
  if (!_idRe.hasMatch(h.id)) {
    p.add('The id "${h.id}" must be lowercase letters, digits and dashes.');
  }
  if (others.any((o) => o.id == h.id)) {
    p.add('A host with the id "${h.id}" already exists.');
  }
  if (h.serverPort < 1 || h.serverPort > 65535) {
    p.add('The server port must be between 1 and 65535.');
  }
  switch (h.kind) {
    case HostKind.local:
      if (h.sshTarget != null && h.sshTarget!.isNotEmpty) {
        p.add('This machine needs no SSH target.');
      }
    case HostKind.ssh:
      final t = h.sshTarget ?? '';
      if (t.trim().isEmpty) {
        p.add('Enter the SSH target (user@host or an ~/.ssh/config name).');
      } else if (t.contains(RegExp(r'\s')) || t.startsWith('-')) {
        p.add('The SSH target cannot contain spaces or start with "-".');
      }
      final lp = h.localPort;
      if (lp == null || lp < 1024 || lp > 65535) {
        p.add('The local port must be between 1024 and 65535.');
      } else {
        final taken = {
          for (final o in others)
            if (o.kind == HostKind.ssh && o.localPort != null) o.localPort!,
          for (final o in others)
            if (o.kind == HostKind.local) o.serverPort,
        };
        if (taken.contains(lp)) {
          p.add('Port $lp is already used by another host on this machine.');
        }
      }
  }
  return p;
}

/// The first free forward port from 19931 up.
int nextLocalPort(List<ModelHost> hosts) {
  final used = {for (final h in hosts) h.agentPort};
  var p = 19931;
  while (used.contains(p)) {
    p++;
  }
  return p;
}

/// A valid host id from a label: lowercase, other characters become dashes.
String hostIdFromLabel(String label) {
  final s = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.isEmpty) return 'host';
  return s.length > 32 ? s.substring(0, 32).replaceAll(RegExp(r'-+$'), '') : s;
}

/// "This machine", when llm-host is installed here.
ModelHost? defaultLocalHost(Which which) => which('llm-host') == null
    ? null
    : const ModelHost(
        id: 'local',
        label: 'This machine',
        kind: HostKind.local,
        serverPort: 9931,
      );
