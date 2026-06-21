/// Execution-sandbox boundary for the process adapter.
library;

/// ProcessSandboxConfig — the *second* security layer for [ProcessAdapter].
///
/// The first layer is the mcp_io `PolicyEngine` (deny-by-default
/// authorization by action/role). Even when policy authorizes an action,
/// the sandbox constrains *how* it runs: which executables, which working
/// directories, which environment variables, output size, wall-clock, and
/// whether a shell interpreter may be used.
///
/// Every default is deny-by-default: with the shipped defaults nothing runs
/// ([executableAllowlist] and [allowedRoots] are empty). The embedding host
/// populates the allowlists for its trusted use cases.
class ProcessSandboxConfig {
  const ProcessSandboxConfig({
    this.executableAllowlist = const <String>[],
    this.allowedRoots = const <String>[],
    this.envAllowlist = const <String>['PATH'],
    this.defaultTimeout = const Duration(seconds: 30),
    this.maxOutputBytes = 1024 * 1024,
    this.allowShell = false,
  });

  /// Executable names (or absolute paths) permitted to run / spawn / look up.
  /// Matched against the `exe` argument verbatim. Empty = nothing runs.
  final List<String> executableAllowlist;

  /// Absolute directory roots a command may use as its working directory.
  /// A requested `cwd` must equal one of these or be nested within one.
  /// Empty = no working directory is permitted (filesystem deny-by-default).
  final List<String> allowedRoots;

  /// Parent-environment variable names forwarded to the child. The full
  /// parent environment is never inherited; only these keys pass through,
  /// plus any explicit per-command `env`.
  final List<String> envAllowlist;

  /// Wall-clock limit applied when a command does not specify `timeoutMs`.
  final Duration defaultTimeout;

  /// Maximum bytes captured per output stream (stdout / stderr). Output
  /// beyond the cap is dropped and the result is flagged truncated.
  final int maxOutputBytes;

  /// Whether `shell:true` commands (interpreter string evaluation) are
  /// permitted at all. Off by default — shell evaluation is an injection
  /// vector. When enabled, such commands remain classed `dangerous`
  /// (plan→commit) by the recommended policy rules.
  final bool allowShell;

  /// Return a copy with selected fields overridden.
  ProcessSandboxConfig copyWith({
    List<String>? executableAllowlist,
    List<String>? allowedRoots,
    List<String>? envAllowlist,
    Duration? defaultTimeout,
    int? maxOutputBytes,
    bool? allowShell,
  }) {
    return ProcessSandboxConfig(
      executableAllowlist: executableAllowlist ?? this.executableAllowlist,
      allowedRoots: allowedRoots ?? this.allowedRoots,
      envAllowlist: envAllowlist ?? this.envAllowlist,
      defaultTimeout: defaultTimeout ?? this.defaultTimeout,
      maxOutputBytes: maxOutputBytes ?? this.maxOutputBytes,
      allowShell: allowShell ?? this.allowShell,
    );
  }
}
