import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:mcp_io_process/mcp_io_process.dart';
import 'package:test/test.dart';

import 'fake_process_runner.dart';

/// End-to-end policy gating: ProcessAdapter behind a real IoRuntime +
/// PolicyEngine, driven through the standard execute / plan / commit path.
void main() {
  final root = Directory.systemTemp.path;

  Future<IoRuntime> buildRuntime({
    required IoPolicyPort policy,
    required ProcessAdapter adapter,
  }) async {
    final runtime = IoRuntime(
      policyPort: policy,
      auditPort: StubIoAuditPort(),
    );
    await runtime.initialize();
    await runtime.registry.registerAdapter(adapter.manifest, adapter);
    await runtime.registry.discover();
    return runtime;
  }

  ProcessAdapter buildAdapter(FakeProcessRunner runner) => ProcessAdapter(
        runner: runner,
        config: ProcessSandboxConfig(
          executableAllowlist: const ['echo'],
          allowedRoots: [root],
        ),
      );

  Command run(String exe) =>
      Command(action: 'process.run', target: 'io://process', args: {'exe': exe});

  const operator = ActorContext(actorId: 'op-1', role: 'operator');
  const worker = ActorContext(actorId: 'w-1', role: 'worker');

  test('deny-by-default: no rules rejects process.run', () async {
    final runtime = await buildRuntime(
      policy: InMemoryIoPolicyPort(),
      adapter: buildAdapter(FakeProcessRunner()),
    );
    addTearDown(runtime.dispose);

    final r = await runtime.execute(run('echo'), actor: operator);
    expect(r.status, CommandStatus.rejected);
  });

  test('recommended rules allow run for an operator role', () async {
    final runner = FakeProcessRunner();
    final runtime = await buildRuntime(
      policy: InMemoryIoPolicyPort(
          initialRules: ProcessPolicy.recommendedRules()),
      adapter: buildAdapter(runner),
    );
    addTearDown(runtime.dispose);

    final r = await runtime.execute(run('echo'), actor: operator);
    expect(r.status, CommandStatus.completed);
    expect(runner.runs, hasLength(1));
  });

  test('a non-listed role is denied', () async {
    final runtime = await buildRuntime(
      policy: InMemoryIoPolicyPort(
          initialRules: ProcessPolicy.recommendedRules()),
      adapter: buildAdapter(FakeProcessRunner()),
    );
    addTearDown(runtime.dispose);

    final r = await runtime.execute(run('echo'), actor: worker);
    expect(r.status, CommandStatus.rejected);
  });

  test('process.spawn requires approval (plan-commit gate)', () async {
    final runtime = await buildRuntime(
      policy: InMemoryIoPolicyPort(
          initialRules: ProcessPolicy.recommendedRules()),
      adapter: buildAdapter(FakeProcessRunner()),
    );
    addTearDown(runtime.dispose);

    final spawn = Command(
        action: 'process.spawn', target: 'io://process', args: {'exe': 'echo'});
    final r = await runtime.execute(spawn, actor: operator);
    expect(r.status, CommandStatus.needsApproval);
  });

  test('plan then commit executes the dangerous spawn', () async {
    final runner = FakeProcessRunner()..handle = FakeProcessHandle();
    final adapter = buildAdapter(runner);
    final runtime = await buildRuntime(
      policy: InMemoryIoPolicyPort(
          initialRules: ProcessPolicy.recommendedRules()),
      adapter: adapter,
    );
    addTearDown(runtime.dispose);

    final device = await runtime.registry.get('process');
    final spawn = Command(
        action: 'process.spawn', target: 'io://process', args: {'exe': 'echo'});

    final plan = await runtime.policyEngine.planEvaluate(
      command: spawn,
      actor: operator,
      device: device!,
      adapter: adapter,
    );
    final res = await runtime.policyEngine.commitExecute(
      planId: plan.planId,
      actorId: operator.actorId,
    );
    expect(res.status, CommandStatus.completed);
    expect((res.result as Map)['handleId'], isNotNull);
    expect(runner.spawns, hasLength(1));
  });
}
