/// ProcessAdapter — sandboxed OS process / shell execution device.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:path/path.dart' as p;

import 'process_config.dart';
import 'process_runner.dart';

/// Internal sandbox rejection — surfaced to callers as a `rejected`
/// [CommandResult], distinct from execution failures.
class _SandboxDenied implements Exception {
  _SandboxDenied(this.code, this.message);
  final String code;
  final String message;
}

/// `AdapterBase` implementation that runs OS processes under a two-layer
/// security model (mcp_io policy + [ProcessSandboxConfig]).
///
/// Actions (driven through the existing `io.*` tool surface):
///   - `process.which` (safe) — resolve an allowlisted executable's path.
///     args: `{exe}`.
///   - `process.run` (guarded) — run to completion, capture bounded output.
///     args: `{exe, argv?, cwd?, env?, stdin?, timeoutMs?, shell?}`.
///   - `process.spawn` (dangerous) — start a long-running process; the
///     recommended policy forces plan→commit. args: as `process.run`.
///   - `process.kill` (guarded) — terminate a spawned process.
///     args: `{handleId}`.
class ProcessAdapter extends AdapterBase {
  ProcessAdapter({
    this.deviceId = 'process',
    ProcessSandboxConfig config = const ProcessSandboxConfig(),
    ProcessRunner runner = const SystemProcessRunner(),
    AdapterManifest? manifest,
  })  : _config = config,
        _runner = runner,
        super(manifest: manifest ?? _defaultManifest);

  final String deviceId;
  final ProcessSandboxConfig _config;
  final ProcessRunner _runner;

  final Map<String, ProcessHandle> _running = {};
  int _handleSeq = 0;

  static const List<CapabilityDescriptor> capabilities = [
    CapabilityDescriptor(
      action: 'process.which',
      safetyClass: SafetyClass.safe,
      description: 'Resolve an allowlisted executable to its absolute path.',
    ),
    CapabilityDescriptor(
      action: 'process.run',
      safetyClass: SafetyClass.guarded,
      description: 'Run an allowlisted executable to completion (sandboxed).',
    ),
    CapabilityDescriptor(
      action: 'process.spawn',
      safetyClass: SafetyClass.dangerous,
      description: 'Start a long-running process (plan→commit recommended).',
    ),
    CapabilityDescriptor(
      action: 'process.kill',
      safetyClass: SafetyClass.guarded,
      description: 'Terminate a spawned process by handle.',
    ),
  ];

  static final AdapterManifest _defaultManifest = AdapterManifest(
    adapterId: 'mcp_io_process',
    adapterVersion: '0.1.0',
    contractVersionRange: '>=0.1.0 <1.0.0',
    displayName: 'Process Execution Adapter',
    description:
        'Policy-gated, sandboxed OS process / shell execution device for '
        'mcp_io. argv-only by default (no shell), deny-by-default executable '
        'and working-directory allowlists, environment allowlist, output cap, '
        'and wall-clock timeout. Desktop / VM only (dart:io).',
    capabilities: capabilities,
  );

  // === Lifecycle ===

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {
    await _killAll();
  }

  @override
  Future<List<DeviceDescriptor>> probe(dynamic transport) async => const [];

  // === 4-Primitive Contract ===

  @override
  Future<DeviceDescriptor> describe() async {
    return const DeviceDescriptor(
      deviceId: 'process',
      manufacturer: 'mcp_io',
      model: 'process',
      transport: 'process',
      connectionState: IoConnectionState.connected,
      capabilities: capabilities,
    );
  }

  @override
  Future<ReadResult> read(ReadSpec spec) async {
    final now = DateTime.now();
    return ReadResult(
      items: [
        for (final t in spec.targets)
          ReadResultItem(
            uri: t,
            error: IoError(
              code: 'device.unsupported',
              message: 'Process adapter has no readable resources; '
                  'use execute(process.*)',
              timestamp: now,
            ),
          ),
      ],
    );
  }

  @override
  Future<CommandResult> execute(Command command) async {
    try {
      switch (command.action) {
        case 'process.which':
          return await _doWhich(command);
        case 'process.run':
          return await _doRun(command);
        case 'process.spawn':
          return await _doSpawn(command);
        case 'process.kill':
          return await _doKill(command);
        default:
          return CommandResult(
            status: CommandStatus.rejected,
            error: IoError(
              code: 'exec.unknown_action',
              message: 'Unknown action: ${command.action}',
              timestamp: DateTime.now(),
            ),
          );
      }
    } on _SandboxDenied catch (denied) {
      return CommandResult(
        status: CommandStatus.rejected,
        error: IoError(
          code: denied.code,
          message: denied.message,
          timestamp: DateTime.now(),
        ),
      );
    } catch (e) {
      return CommandResult(
        status: CommandStatus.failed,
        error: AdapterBase.mapException(e),
      );
    }
  }

  // === Action handlers ===

  Future<CommandResult> _doWhich(Command command) async {
    final exe = _requireExe(command);
    final path = await _runner.resolve(exe);
    if (path == null) {
      return CommandResult(
        status: CommandStatus.failed,
        error: IoError(
          code: 'exec.not_found',
          message: 'Executable not found: $exe',
          timestamp: DateTime.now(),
        ),
      );
    }
    return CommandResult(
      status: CommandStatus.completed,
      result: {'exe': exe, 'path': path},
    );
  }

  Future<CommandResult> _doRun(Command command) async {
    final exe = _requireExe(command);
    final shell = _requireShellAllowed(command);
    final cwd = _resolveCwd(command);
    final env = _buildEnv(command);
    final argv =
        (command.args['argv'] as List?)?.cast<String>() ?? const <String>[];
    final stdin = command.args['stdin'] as String?;
    final timeout = _timeout(command);

    final outcome = await _runner.run(
      executable: exe,
      argv: argv,
      workingDirectory: cwd,
      environment: env,
      runInShell: shell,
      timeout: timeout,
      maxOutputBytes: _config.maxOutputBytes,
      stdin: stdin,
    );

    return CommandResult(
      status: outcome.timedOut ? CommandStatus.failed : CommandStatus.completed,
      result: {
        'exitCode': outcome.exitCode,
        'stdout': outcome.stdout,
        'stderr': outcome.stderr,
        'stdoutTruncated': outcome.stdoutTruncated,
        'stderrTruncated': outcome.stderrTruncated,
        'timedOut': outcome.timedOut,
        if (outcome.pid != null) 'pid': outcome.pid,
      },
      error: outcome.timedOut
          ? IoError(
              code: 'exec.timeout',
              message: 'Process exceeded ${timeout.inMilliseconds}ms '
                  'and was killed',
              timestamp: DateTime.now(),
            )
          : null,
    );
  }

  Future<CommandResult> _doSpawn(Command command) async {
    final exe = _requireExe(command);
    final shell = _requireShellAllowed(command);
    final cwd = _resolveCwd(command);
    final env = _buildEnv(command);
    final argv =
        (command.args['argv'] as List?)?.cast<String>() ?? const <String>[];

    final handle = await _runner.start(
      executable: exe,
      argv: argv,
      workingDirectory: cwd,
      environment: env,
      runInShell: shell,
    );

    final id = '$deviceId-${++_handleSeq}';
    _running[id] = handle;
    // Drop the handle from the live set once the process exits on its own.
    unawaited(
      handle.exitCode.then<void>((_) {
        _running.remove(id);
      }).catchError((_) {}),
    );

    return CommandResult(
      status: CommandStatus.completed,
      result: {'handleId': id, 'pid': handle.pid},
    );
  }

  Future<CommandResult> _doKill(Command command) async {
    final id = command.args['handleId'] as String?;
    if (id == null) {
      throw _SandboxDenied(
        'exec.invalid_args',
        'args["handleId"] (String) is required',
      );
    }
    final handle = _running.remove(id);
    if (handle == null) {
      return CommandResult(
        status: CommandStatus.failed,
        error: IoError(
          code: 'process.not_found',
          message: 'No running process for handle: $id',
          timestamp: DateTime.now(),
        ),
      );
    }
    final killed = handle.kill();
    return CommandResult(
      status: CommandStatus.completed,
      result: {'handleId': id, 'killed': killed},
    );
  }

  // === Sandbox enforcement ===

  String _requireExe(Command command) {
    final exe = command.args['exe'];
    if (exe is! String || exe.isEmpty) {
      throw _SandboxDenied(
        'exec.invalid_args',
        'args["exe"] (String) is required',
      );
    }
    if (!_config.executableAllowlist.contains(exe)) {
      throw _SandboxDenied(
        'policy.exe_not_allowed',
        'Executable "$exe" is not in the sandbox allowlist',
      );
    }
    return exe;
  }

  bool _requireShellAllowed(Command command) {
    final shell = command.args['shell'] == true;
    if (shell && !_config.allowShell) {
      throw _SandboxDenied(
        'policy.shell_disabled',
        'shell execution is disabled by the sandbox (enable allowShell)',
      );
    }
    return shell;
  }

  String _resolveCwd(Command command) {
    final requested = command.args['cwd'] as String?;
    final roots = _config.allowedRoots;
    if (requested == null) {
      if (roots.isEmpty) {
        throw _SandboxDenied(
          'policy.cwd_required',
          'no working directory is permitted (allowedRoots is empty)',
        );
      }
      return p.canonicalize(roots.first);
    }
    final cwd = p.canonicalize(requested);
    final permitted = roots.any((r) {
      final root = p.canonicalize(r);
      return cwd == root || p.isWithin(root, cwd);
    });
    if (!permitted) {
      throw _SandboxDenied(
        'policy.cwd_outside_root',
        'working directory "$requested" is outside the allowed roots',
      );
    }
    return cwd;
  }

  Map<String, String> _buildEnv(Command command) {
    final env = <String, String>{};
    for (final key in _config.envAllowlist) {
      final value = Platform.environment[key];
      if (value != null) env[key] = value;
    }
    final extra = (command.args['env'] as Map?)?.cast<String, String>();
    if (extra != null) env.addAll(extra);
    return env;
  }

  Duration _timeout(Command command) {
    final ms = command.args['timeoutMs'];
    if (ms is int && ms > 0) return Duration(milliseconds: ms);
    return _config.defaultTimeout;
  }

  Future<void> _killAll() async {
    for (final handle in _running.values.toList()) {
      handle.kill();
    }
    _running.clear();
  }

  // === Streaming / safety ===

  @override
  Stream<PayloadEnvelope> subscribe(TopicSpec spec) {
    final handle = _running[spec.uri];
    if (handle == null) {
      throw ArgumentError(
        'Process subscribe uri must be a live handleId (got "${spec.uri}")',
      );
    }
    final controller = StreamController<PayloadEnvelope>.broadcast();
    StreamSubscription<List<int>>? outSub;
    StreamSubscription<List<int>>? errSub;
    controller.onListen = () {
      outSub = handle.stdout.listen(
        (chunk) => controller.add(_chunkEnvelope(spec.uri, 'stdout', chunk)),
        onError: controller.addError,
      );
      errSub = handle.stderr.listen(
        (chunk) => controller.add(_chunkEnvelope(spec.uri, 'stderr', chunk)),
      );
    };
    controller.onCancel = () async {
      await outSub?.cancel();
      await errSub?.cancel();
    };
    return controller.stream;
  }

  PayloadEnvelope _chunkEnvelope(String handleId, String stream, List<int> chunk) {
    final now = DateTime.now();
    return PayloadEnvelope(
      uri: handleId,
      kind: PayloadKind.stream,
      payload: TypedPayload(
        type: PayloadType.blob,
        value: List<int>.unmodifiable(chunk),
        timestamp: now,
      ),
      meta: EnvelopeMeta(capturedAt: now, sourceAddress: '$deviceId/$stream'),
    );
  }

  @override
  Future<EmergencyStopResult> emergencyStop(EmergencyStopRequest request) async {
    await _killAll();
    return EmergencyStopResult(success: true, stoppedDevices: [deviceId]);
  }
}
