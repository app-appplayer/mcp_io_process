/// Recommended mcp_io policy rules for the process adapter.
library;

// PolicyRule / PolicyCondition / PolicyConstraints / RateLimit live in the
// io_policy_port contract. The mcp_bundle main barrel exports a different
// PolicyRule (models/policy.dart), so they are taken from the public ports
// catalogue with an explicit `show`.
import 'package:mcp_bundle/ports.dart'
    show PolicyRule, PolicyCondition, PolicyConstraints, RateLimit;

/// Builder for the recommended deny-by-default policy posture.
///
/// Shipping NO rules already denies everything (the engine's default
/// decision is `deny`). [recommendedRules] opts specific roles into the
/// process actions with the intended safety posture:
///   - `process.which` / `process.run` / `process.kill` → allowed (run is
///     rate-limited).
///   - `process.spawn` → allowed but `requireApproval` (forces the
///     `io.plan_execute` → `io.commit_execute` two-phase flow).
///
/// Rules match by action only — `process.*` actions are unique to this
/// adapter, so no target prefix is needed.
class ProcessPolicy {
  ProcessPolicy._();

  /// Recommended rule set. [roles] are the actor roles permitted to use the
  /// process actions; everything else falls through to the engine's default
  /// deny. [runRateLimit] caps `process.run` frequency per scope.
  static List<PolicyRule> recommendedRules({
    List<String> roles = const ['operator', 'admin'],
    RateLimit? runRateLimit,
  }) {
    final rate =
        runRateLimit ?? RateLimit(maxCalls: 30, window: const Duration(minutes: 1));
    return [
      PolicyRule(
        id: 'process.which.allow',
        name: 'Allow executable lookup',
        when: PolicyCondition(action: 'process.which', actorRoleIn: roles),
        allow: true,
        priority: 100,
      ),
      PolicyRule(
        id: 'process.run.allow',
        name: 'Allow run (rate-limited)',
        when: PolicyCondition(action: 'process.run', actorRoleIn: roles),
        allow: true,
        constraints: PolicyConstraints(rateLimit: rate),
        priority: 100,
      ),
      PolicyRule(
        id: 'process.kill.allow',
        name: 'Allow kill',
        when: PolicyCondition(action: 'process.kill', actorRoleIn: roles),
        allow: true,
        priority: 100,
      ),
      PolicyRule(
        id: 'process.spawn.approval',
        name: 'Spawn requires plan-commit',
        when: PolicyCondition(action: 'process.spawn', actorRoleIn: roles),
        allow: true,
        constraints: const PolicyConstraints(requireApproval: true),
        priority: 100,
      ),
    ];
  }
}
