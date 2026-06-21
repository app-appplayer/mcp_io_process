import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io_process/mcp_io_process.dart';
import 'package:test/test.dart';

import 'fake_process_runner.dart';

void main() {
  final root = Directory.systemTemp.path;

  ProcessAdapter buildAdapter(FakeProcessRunner runner, {
    List<String> exes = const ['echo'],
    bool allowShell = false,
  }) {
    return ProcessAdapter(
      runner: runner,
      config: ProcessSandboxConfig(
        executableAllowlist: exes,
        allowedRoots: [root],
        allowShell: allowShell,
      ),
    );
  }

  Command cmd(String action, Map<String, dynamic> args) =>
      Command(action: action, target: 'io://process', args: args);

  group('describe', () {
    test('exposes the four process capabilities with safety classes', () async {
      final adapter = buildAdapter(FakeProcessRunner());
      final desc = await adapter.describe();
      final byAction = {for (final c in desc.capabilities) c.action: c.safetyClass};
      expect(byAction['process.which'], SafetyClass.safe);
      expect(byAction['process.run'], SafetyClass.guarded);
      expect(byAction['process.spawn'], SafetyClass.dangerous);
      expect(byAction['process.kill'], SafetyClass.guarded);
    });
  });

  group('process.which', () {
    test('resolves an allowlisted executable', () async {
      final runner = FakeProcessRunner()..resolvePath = '/usr/bin/echo';
      final adapter = buildAdapter(runner);
      final r = await adapter.execute(cmd('process.which', {'exe': 'echo'}));
      expect(r.status, CommandStatus.completed);
      expect((r.result as Map)['path'], '/usr/bin/echo');
    });

    test('rejects a non-allowlisted executable', () async {
      final adapter = buildAdapter(FakeProcessRunner());
      final r = await adapter.execute(cmd('process.which', {'exe': 'rm'}));
      expect(r.status, CommandStatus.rejected);
      expect(r.error!.code, 'policy.exe_not_allowed');
    });
  });

  group('process.run sandbox', () {
    test('runs an allowlisted exe and returns captured output', () async {
      final runner = FakeProcessRunner()
        ..outcome = const ProcessRunOutcome(
            exitCode: 0, stdout: 'hello', stderr: '');
      final adapter = buildAdapter(runner);
      final r = await adapter.execute(
          cmd('process.run', {'exe': 'echo', 'argv': ['hello']}));
      expect(r.status, CommandStatus.completed);
      expect((r.result as Map)['stdout'], 'hello');
      expect(runner.runs.single.argv, ['hello']);
      expect(runner.runs.single.runInShell, isFalse);
    });

    test('rejects executable outside allowlist', () async {
      final adapter = buildAdapter(FakeProcessRunner());
      final r = await adapter.execute(cmd('process.run', {'exe': 'curl'}));
      expect(r.status, CommandStatus.rejected);
      expect(r.error!.code, 'policy.exe_not_allowed');
    });

    test('rejects cwd outside the allowed roots', () async {
      final adapter = buildAdapter(FakeProcessRunner());
      final outside = Platform.isWindows ? r'C:\Windows' : '/etc';
      final r = await adapter
          .execute(cmd('process.run', {'exe': 'echo', 'cwd': outside}));
      expect(r.status, CommandStatus.rejected);
      expect(r.error!.code, 'policy.cwd_outside_root');
    });

    test('accepts cwd nested within an allowed root', () async {
      final runner = FakeProcessRunner();
      final adapter = buildAdapter(runner);
      final nested = '$root${Platform.pathSeparator}sub';
      final r = await adapter
          .execute(cmd('process.run', {'exe': 'echo', 'cwd': nested}));
      expect(r.status, CommandStatus.completed);
    });

    test('rejects shell:true when the sandbox disables shell', () async {
      final adapter = buildAdapter(FakeProcessRunner());
      final r = await adapter
          .execute(cmd('process.run', {'exe': 'echo', 'shell': true}));
      expect(r.status, CommandStatus.rejected);
      expect(r.error!.code, 'policy.shell_disabled');
    });

    test('allows shell:true only when explicitly enabled', () async {
      final runner = FakeProcessRunner();
      final adapter = buildAdapter(runner, allowShell: true);
      final r = await adapter
          .execute(cmd('process.run', {'exe': 'echo', 'shell': true}));
      expect(r.status, CommandStatus.completed);
      expect(runner.runs.single.runInShell, isTrue);
    });

    test('forwards only allowlisted parent env plus explicit env', () async {
      final runner = FakeProcessRunner();
      final adapter = ProcessAdapter(
        runner: runner,
        config: ProcessSandboxConfig(
          executableAllowlist: const ['echo'],
          allowedRoots: [root],
          envAllowlist: const ['PATH'],
        ),
      );
      await adapter.execute(cmd('process.run', {
        'exe': 'echo',
        'env': {'CUSTOM': 'v'},
      }));
      final env = runner.runs.single.environment;
      expect(env.containsKey('CUSTOM'), isTrue);
      // A parent-only secret-ish var that is not on the allowlist must not leak.
      expect(env.containsKey('HOME'), isFalse);
    });

    test('surfaces timeout as failed with exec.timeout', () async {
      final runner = FakeProcessRunner()
        ..outcome = const ProcessRunOutcome(
            exitCode: -1, stdout: '', stderr: '', timedOut: true);
      final adapter = buildAdapter(runner);
      final r = await adapter.execute(cmd('process.run', {'exe': 'echo'}));
      expect(r.status, CommandStatus.failed);
      expect(r.error!.code, 'exec.timeout');
    });

    test('propagates output truncation flags', () async {
      final runner = FakeProcessRunner()
        ..outcome = const ProcessRunOutcome(
            exitCode: 0, stdout: 'x', stderr: '', stdoutTruncated: true);
      final adapter = buildAdapter(runner);
      final r = await adapter.execute(cmd('process.run', {'exe': 'echo'}));
      expect((r.result as Map)['stdoutTruncated'], isTrue);
    });
  });

  group('spawn / kill / emergencyStop', () {
    test('spawn returns a handle and kill terminates it', () async {
      final handle = FakeProcessHandle();
      final runner = FakeProcessRunner()..handle = handle;
      final adapter = buildAdapter(runner);

      final spawn = await adapter.execute(cmd('process.spawn', {'exe': 'echo'}));
      expect(spawn.status, CommandStatus.completed);
      final id = (spawn.result as Map)['handleId'] as String;

      final kill = await adapter.execute(cmd('process.kill', {'handleId': id}));
      expect(kill.status, CommandStatus.completed);
      expect(handle.killed, isTrue);
    });

    test('kill of an unknown handle fails', () async {
      final adapter = buildAdapter(FakeProcessRunner());
      final r =
          await adapter.execute(cmd('process.kill', {'handleId': 'nope'}));
      expect(r.status, CommandStatus.failed);
      expect(r.error!.code, 'process.not_found');
    });

    test('emergencyStop kills all running processes', () async {
      final handle = FakeProcessHandle();
      final runner = FakeProcessRunner()..handle = handle;
      final adapter = buildAdapter(runner);
      await adapter.execute(cmd('process.spawn', {'exe': 'echo'}));
      final r = await adapter.emergencyStop(
        const EmergencyStopRequest(reason: 'test', actorId: 'op'),
      );
      expect(r.success, isTrue);
      expect(handle.killed, isTrue);
    });
  });

  group('unknown action', () {
    test('is rejected', () async {
      final adapter = buildAdapter(FakeProcessRunner());
      final r = await adapter.execute(cmd('process.nope', {'exe': 'echo'}));
      expect(r.status, CommandStatus.rejected);
      expect(r.error!.code, 'exec.unknown_action');
    });
  });
}
