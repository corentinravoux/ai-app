import 'dart:async';
import 'dart:convert';
import 'dart:io';

class RunResult {
  const RunResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs a command to completion. [env], when given, is the child's whole
/// environment (the parent's is not merged in). [timeout], when given,
/// replaces the runner's default; on expiry the command is killed and the
/// result is exit code 124 with "timed out" on stderr.
abstract class Runner {
  Future<RunResult> run(
    String exe,
    List<String> args, {
    Map<String, String>? env,
    Duration? timeout,
  });
}

class IoRunner implements Runner {
  const IoRunner({this.timeout = const Duration(minutes: 2)});
  final Duration timeout;

  @override
  Future<RunResult> run(
    String exe,
    List<String> args, {
    Map<String, String>? env,
    Duration? timeout,
  }) async {
    final Process p;
    try {
      p = await Process.start(
        exe,
        args,
        environment: env,
        includeParentEnvironment: env == null,
      );
    } on ProcessException catch (e) {
      return RunResult(127, '', e.message);
    }
    p.stdin.close().ignore();
    final out = _Collector(p.stdout);
    final err = _Collector(p.stderr);
    final limit = timeout ?? this.timeout;
    try {
      final code = await p.exitCode.timeout(limit);
      return RunResult(code, await out.text(), await err.text());
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
      await p.exitCode;
      return RunResult(
        124,
        await out.text(),
        'timed out after ${limit.inSeconds} s',
      );
    }
  }
}

/// Collects a process stream as text while it arrives. [text] waits a
/// short grace for the end of the stream, then returns what came: a
/// grandchild left running (a background job, ssh's ControlMaster) may keep
/// the pipe open after the command itself has exited.
class _Collector {
  _Collector(Stream<List<int>> s) {
    s
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_buf.write, onDone: _done.complete, onError: (_) {});
  }

  final _buf = StringBuffer();
  final _done = Completer<void>();

  Future<String> text() async {
    await _done.future.timeout(
      const Duration(milliseconds: 300),
      onTimeout: () {},
    );
    return _buf.toString();
  }
}
