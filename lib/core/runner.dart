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
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    final limit = timeout ?? this.timeout;
    try {
      final code = await p.exitCode.timeout(limit);
      return RunResult(code, await out, await err);
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
      await p.exitCode;
      // A grandchild may keep the pipes open: do not wait for it.
      const grace = Duration(milliseconds: 200);
      final o = await out.timeout(grace, onTimeout: () => '');
      return RunResult(124, o, 'timed out after ${limit.inSeconds} s');
    }
  }
}
