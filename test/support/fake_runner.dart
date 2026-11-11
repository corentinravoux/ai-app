import 'package:ai_app/core/runner.dart';

class Call {
  Call(this.exe, this.args, this.env);
  final String exe;
  final List<String> args;
  final Map<String, String>? env;
  String get line => [exe, ...args].join(' ');
}

typedef Handler = RunResult Function(Call c);

/// Records calls; answers with the first handler whose key prefixes the
/// command line, else exit 0 with empty output.
class FakeRunner implements Runner {
  FakeRunner([Map<String, Handler>? handlers]) : handlers = handlers ?? {};

  final Map<String, Handler> handlers;
  final calls = <Call>[];

  @override
  Future<RunResult> run(
    String exe,
    List<String> args, {
    Map<String, String>? env,
  }) async {
    final c = Call(exe, args, env);
    calls.add(c);
    for (final e in handlers.entries) {
      if (c.line.startsWith(e.key)) return e.value(c);
    }
    return const RunResult(0, '', '');
  }
}
