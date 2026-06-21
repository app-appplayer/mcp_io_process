/// Process / shell execution adapter for mcp_io.
///
/// Registers an OS process-execution "device" with an [IoRuntime] so that
/// the existing `io.*` tool surface (`io.execute`, `io.plan_execute`,
/// `io.commit_execute`, `io.cancel_job`, `io.emergency_stop`) drives
/// sandboxed command execution — no new tool verbs.
///
/// Two security layers cooperate:
///   1. mcp_io [PolicyEngine] — deny-by-default authorization by
///      action/role (see [ProcessPolicy] for recommended rules).
///   2. [ProcessSandboxConfig] — execution boundary: executable + working
///      directory allowlists, environment allowlist, output cap, timeout,
///      and a shell-evaluation gate.
///
/// Desktop / VM only (uses `dart:io` [Process]). Web and headless hosts do
/// not register this adapter.
library;

export 'src/process_config.dart';
export 'src/process_runner.dart';
export 'src/process_adapter.dart';
export 'src/process_policy.dart';
