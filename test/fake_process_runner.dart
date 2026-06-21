/// Deterministic [ProcessRunner] for tests — no real OS processes.
library;

import 'dart:async';
import 'dart:convert';

import 'package:mcp_io_process/mcp_io_process.dart';

/// Records calls and returns canned outcomes.
class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner({this.outcome, this.resolvePath, this.handle});

  /// Outcome returned by [run]. Defaults to a successful empty result.
  ProcessRunOutcome? outcome;

  /// Path returned by [resolve]. Null = not found.
  String? resolvePath = '/usr/bin/echo';

  /// Handle returned by [start].
  FakeProcessHandle? handle;

  final List<RunCall> runs = [];
  final List<RunCall> spawns = [];

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
    runs.add(RunCall(
      executable: executable,
      argv: argv,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: runInShell,
    ));
    return outcome ??
        const ProcessRunOutcome(exitCode: 0, stdout: 'ok', stderr: '');
  }

  @override
  Future<ProcessHandle> start({
    required String executable,
    required List<String> argv,
    required String workingDirectory,
    required Map<String, String> environment,
    required bool runInShell,
  }) async {
    spawns.add(RunCall(
      executable: executable,
      argv: argv,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: runInShell,
    ));
    return handle ??= FakeProcessHandle();
  }

  @override
  Future<String?> resolve(String executable) async => resolvePath;
}

/// Captured arguments of a [FakeProcessRunner] call.
class RunCall {
  RunCall({
    required this.executable,
    required this.argv,
    required this.workingDirectory,
    required this.environment,
    required this.runInShell,
  });

  final String executable;
  final List<String> argv;
  final String workingDirectory;
  final Map<String, String> environment;
  final bool runInShell;
}

/// Fake spawned-process handle.
class FakeProcessHandle implements ProcessHandle {
  final Completer<int> _exit = Completer<int>();
  bool killed = false;

  @override
  int get pid => 4242;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode('out'));

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  bool kill() {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-9);
    return true;
  }
}
