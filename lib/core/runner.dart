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
      err.finish(); // its text is replaced by the timeout message
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
///
/// Once the text is taken (or [finish] is called) later output is drained
/// and dropped: the pipe stays read, so the grandchild never blocks on it,
/// but nothing is kept for a result that has already been returned.
class _Collector {
  _Collector(Stream<List<int>> s) {
    s
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((d) => _buf?.write(d), onDone: _done.complete, onError: (_) {});
  }

  StringBuffer? _buf = StringBuffer();
  final _done = Completer<void>();

  Future<String> text() async {
    await _done.future.timeout(
      const Duration(milliseconds: 300),
      onTimeout: () {},
    );
    final t = _buf?.toString() ?? '';
    finish();
    return t;
  }

  /// Stops keeping output; what is already collected is dropped.
  void finish() => _buf = null;
}
