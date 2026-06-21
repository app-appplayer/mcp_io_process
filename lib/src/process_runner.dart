/// Low-level process execution primitive (injectable seam).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Outcome of a completed [ProcessRunner.run].
class ProcessRunOutcome {
  const ProcessRunOutcome({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.stdoutTruncated = false,
    this.stderrTruncated = false,
    this.timedOut = false,
    this.pid,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool stdoutTruncated;
  final bool stderrTruncated;
  final bool timedOut;
  final int? pid;
}

/// Handle to a long-running spawned process.
abstract class ProcessHandle {
  /// OS process id.
  int get pid;

  /// Completes with the exit code when the process terminates.
  Future<int> get exitCode;

  /// Standard output byte stream.
  Stream<List<int>> get stdout;

  /// Standard error byte stream.
  Stream<List<int>> get stderr;

  /// Request termination. Returns true when the signal was delivered.
  bool kill();
}

/// Process execution primitive. Injectable so [ProcessAdapter] stays
/// testable without spawning real OS processes and so platform specifics
/// are isolated here.
abstract class ProcessRunner {
  /// Run a command to completion, capturing bounded output.
  Future<ProcessRunOutcome> run({
    required String executable,
    required List<String> argv,
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
    required Duration timeout,
    required int maxOutputBytes,
    String? stdin,
  });

  /// Start a long-running process and return a handle.
  Future<ProcessHandle> start({
    required String executable,
    required List<String> argv,
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
  });

  /// Resolve [executable] to an absolute path, or null when not found.
  Future<String?> resolve(String executable);
}

/// Default [ProcessRunner] backed by `dart:io` [Process]. Desktop / VM only.
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ProcessRunOutcome> run({
    required String executable,
    required List<String> argv,
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
    required Duration timeout,
    required int maxOutputBytes,
    String? stdin,
  }) async {
    final proc = await Process.start(
      executable,
      argv,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: runInShell,
    );

    if (stdin != null) {
      proc.stdin.write(stdin);
    }
    await proc.stdin.close();

    final out = _CappedCollector(maxOutputBytes);
    final err = _CappedCollector(maxOutputBytes);
    final outDone = proc.stdout.forEach(out.add);
    final errDone = proc.stderr.forEach(err.add);

    var timedOut = false;
    int exit;
    try {
      exit = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
      exit = await proc.exitCode;
    }

    // Drain remaining output; ignore stream errors after a kill.
    await outDone.catchError((_) {});
    await errDone.catchError((_) {});

    return ProcessRunOutcome(
      exitCode: exit,
      stdout: out.text,
      stderr: err.text,
      stdoutTruncated: out.truncated,
      stderrTruncated: err.truncated,
      timedOut: timedOut,
      pid: proc.pid,
    );
  }

  @override
  Future<ProcessHandle> start({
    required String executable,
    required List<String> argv,
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
  }) async {
    final proc = await Process.start(
      executable,
      argv,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: runInShell,
    );
    return _SystemProcessHandle(proc);
  }

  @override
  Future<String?> resolve(String executable) async {
    final locator = Platform.isWindows ? 'where' : 'which';
    try {
      final result = await Process.run(locator, [executable]);
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim();
      if (out.isEmpty) return null;
      return out.split(RegExp(r'\r?\n')).first.trim();
    } on Object {
      return null;
    }
  }
}

class _SystemProcessHandle implements ProcessHandle {
  _SystemProcessHandle(this._proc);

  final Process _proc;

  @override
  int get pid => _proc.pid;

  @override
  Future<int> get exitCode => _proc.exitCode;

  @override
  Stream<List<int>> get stdout => _proc.stdout;

  @override
  Stream<List<int>> get stderr => _proc.stderr;

  @override
  bool kill() => _proc.kill(ProcessSignal.sigkill);
}

/// Accumulates byte chunks up to a hard cap, flagging truncation.
class _CappedCollector {
  _CappedCollector(this.maxBytes);

  final int maxBytes;
  final List<int> _bytes = [];
  bool truncated = false;

  void add(List<int> chunk) {
    if (_bytes.length >= maxBytes) {
      truncated = true;
      return;
    }
    final remaining = maxBytes - _bytes.length;
    if (chunk.length <= remaining) {
      _bytes.addAll(chunk);
    } else {
      _bytes.addAll(chunk.take(remaining));
      truncated = true;
    }
  }

  String get text => utf8.decode(_bytes, allowMalformed: true);
}
