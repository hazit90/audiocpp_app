import 'dart:isolate';

import '../ffi/library.dart';
import '../native/native_bridge.dart';
import 'protocol.dart';

/// Startup payload handed to the worker isolate.
final class WorkerBootstrap {
  const WorkerBootstrap({required this.replyPort, this.libraryPath});

  final SendPort replyPort;

  /// Propagates [AudioCppLibrary.overridePath] into the worker, which does not
  /// inherit static state from the spawning isolate.
  final String? libraryPath;
}

/// One request on the wire: an id the caller correlates on, plus the command.
final class WorkerRequest {
  const WorkerRequest(this.id, this.command);

  final int id;
  final WorkerCommand command;
}

/// One response on the wire.
///
/// Errors travel as a value rather than as an isolate error so a single failed
/// command does not tear down the worker and every handle it holds.
final class WorkerResponse {
  const WorkerResponse.success(this.id, this.value)
      : error = null,
        stackTrace = null;

  const WorkerResponse.failure(this.id, this.error, this.stackTrace) : value = null;

  final int id;
  final Object? value;
  final Object? error;

  /// Serialized because [StackTrace] itself is not sendable.
  final String? stackTrace;

  bool get isSuccess => error == null;
}

/// Sentinel telling the worker to release everything and exit.
final class ShutdownRequest {
  const ShutdownRequest(this.id);

  final int id;
}

/// Entry point for the worker isolate.
///
/// Requests are handled strictly in arrival order. Because inference blocks the
/// isolate, a long generation delays anything queued behind it -- including
/// dispose calls. That is the deliberate trade for keeping native handles
/// confined to one thread, which the C ABI requires.
Future<void> audioCppWorkerMain(WorkerBootstrap bootstrap) async {
  if (bootstrap.libraryPath != null) {
    AudioCppLibrary.overridePath = bootstrap.libraryPath;
  }

  final bridge = NativeBridge();
  final commandPort = ReceivePort();
  bootstrap.replyPort.send(commandPort.sendPort);

  await for (final message in commandPort) {
    if (message is ShutdownRequest) {
      bridge.disposeAll();
      bootstrap.replyPort.send(WorkerResponse.success(message.id, null));
      break;
    }

    if (message is! WorkerRequest) {
      continue;
    }

    try {
      final value = message.command.execute(bridge);
      bootstrap.replyPort.send(WorkerResponse.success(message.id, value));
    } catch (error, stackTrace) {
      bootstrap.replyPort.send(
        WorkerResponse.failure(message.id, error, stackTrace.toString()),
      );
    }
  }

  commandPort.close();
}
