# Changelog

## 0.1.0

- Initial release. `ProcessAdapter` — a policy-gated, sandboxed OS process /
  shell execution device for `mcp_io`.
- Drives the existing `io.*` tool surface (`io.execute`, `io.plan_execute`,
  `io.commit_execute`, `io.cancel_job`, `io.emergency_stop`) — no new tool
  verbs.
- Actions: `process.which` (safe), `process.run` (guarded), `process.spawn`
  (dangerous, plan→commit), `process.kill` (guarded).
- `ProcessSandboxConfig` execution boundary: deny-by-default executable and
  working-directory allowlists, environment allowlist (no full parent-env
  inheritance), per-stream output cap, wall-clock timeout, and an off-by-default
  shell-evaluation gate.
- `ProcessRunner` seam (`SystemProcessRunner` backed by `dart:io`) for
  injectable, testable execution.
- `ProcessPolicy.recommendedRules` — opt-in deny-by-default policy posture.
