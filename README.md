# mcp_io_process

Policy-gated, sandboxed OS process / shell execution adapter for
[`mcp_io`](https://pub.dev/packages/mcp_io).

It registers a process-execution "device" with an `IoRuntime`, so the existing
`io.*` tool surface drives sandboxed command execution — **no new tool verbs**.
Desktop / VM only (uses `dart:io`).

## Security model

Two layers cooperate:

1. **Authorization — `mcp_io` PolicyEngine.** Deny-by-default. Rules opt
   specific actor roles into the process actions. `process.spawn` is forced
   through the `io.plan_execute` → `io.commit_execute` two-phase flow.
2. **Execution sandbox — `ProcessSandboxConfig`.** Even when authorized, a
   command is constrained by:
   - executable allowlist (empty = nothing runs),
   - working-directory allowlist (a `cwd` must sit within an allowed root),
   - environment allowlist (the full parent environment is never inherited),
   - per-stream output cap and a wall-clock timeout,
   - an off-by-default shell-evaluation gate (`argv`-only by default).

## Actions

| Action | Safety | Args |
|---|---|---|
| `process.which` | safe | `exe` |
| `process.run` | guarded | `exe`, `argv?`, `cwd?`, `env?`, `stdin?`, `timeoutMs?`, `shell?` |
| `process.spawn` | dangerous | as `process.run` |
| `process.kill` | guarded | `handleId` |

## Usage

```dart
import 'package:mcp_io/mcp_io.dart';
import 'package:mcp_io_process/mcp_io_process.dart';

final runtime = IoRuntime(
  policyPort: InMemoryIoPolicyPort(
    initialRules: ProcessPolicy.recommendedRules(roles: const ['operator']),
  ),
  auditPort: myAuditPort,
);
await runtime.initialize();

final adapter = ProcessAdapter(
  config: const ProcessSandboxConfig(
    executableAllowlist: ['git', 'flutter'],
    allowedRoots: ['/work/project'],
  ),
);
await runtime.registry.registerAdapter(adapter.manifest, adapter);
await runtime.registry.discover();

// Now reachable through io.execute / io.plan_execute / io.commit_execute.
```

The embedding host (AppPlayer / Studio) opts in by registering the adapter; web
and headless hosts simply do not.
