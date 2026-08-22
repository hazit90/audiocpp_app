import 'dart:typed_data';

import '../native/native_bridge.dart';
import '../types.dart';

/// Messages exchanged with the worker isolate.
///
/// Each command carries its own execution against the [NativeBridge], so the
/// worker loop stays a dispatch with no knowledge of individual operations.
/// Commands and results are plain data, which is what makes them sendable
/// across the isolate port.
sealed class WorkerCommand {
  const WorkerCommand();

  /// Runs on the worker isolate. May block for a long time.
  Object? execute(NativeBridge bridge);
}

final class ListDevicesCommand extends WorkerCommand {
  const ListDevicesCommand();

  @override
  List<AudioCppDevice> execute(NativeBridge bridge) => bridge.listDevices();
}

final class LoadModelCommand extends WorkerCommand {
  const LoadModelCommand(this.descriptor);

  final ModelDescriptor descriptor;

  @override
  LoadedModelInfo execute(NativeBridge bridge) {
    final id = bridge.loadModel(descriptor);
    // Read the metadata here so the caller gets it without a second round trip
    // and can expose it as a synchronous getter.
    return LoadedModelInfo(
      handleId: id,
      family: bridge.modelFamily(id),
      supportedTasks: {
        for (final task in AudioCppTask.values)
          if (bridge.modelSupportsTask(id, task)) task,
      },
    );
  }
}

final class DisposeModelCommand extends WorkerCommand {
  const DisposeModelCommand(this.handleId);

  final int handleId;

  @override
  void execute(NativeBridge bridge) => bridge.disposeModel(handleId);
}

final class CreateSessionCommand extends WorkerCommand {
  const CreateSessionCommand(this.modelHandleId, this.config);

  final int modelHandleId;
  final SessionConfig config;

  @override
  int execute(NativeBridge bridge) => bridge.createSession(modelHandleId, config);
}

final class DisposeSessionCommand extends WorkerCommand {
  const DisposeSessionCommand(this.handleId);

  final int handleId;

  @override
  void execute(NativeBridge bridge) => bridge.disposeSession(handleId);
}

final class RunCommand extends WorkerCommand {
  const RunCommand(this.sessionHandleId, this.request);

  final int sessionHandleId;
  final InferenceRequest request;

  @override
  GeneratedAudioInfo execute(NativeBridge bridge) {
    final audioId = bridge.runSession(sessionHandleId, request);
    final info = bridge.audioInfo(audioId);
    return GeneratedAudioInfo(
      handleId: audioId,
      sampleRate: info.sampleRate,
      channels: info.channels,
      sampleCount: info.sampleCount,
    );
  }
}

final class ReadSamplesCommand extends WorkerCommand {
  const ReadSamplesCommand(this.handleId);

  final int handleId;

  @override
  Float32List execute(NativeBridge bridge) => bridge.readSamples(handleId);
}

final class WriteWavCommand extends WorkerCommand {
  const WriteWavCommand(this.handleId, this.path);

  final int handleId;
  final String path;

  @override
  void execute(NativeBridge bridge) => bridge.writeWav(handleId, path);
}

final class DisposeAudioCommand extends WorkerCommand {
  const DisposeAudioCommand(this.handleId);

  final int handleId;

  @override
  void execute(NativeBridge bridge) => bridge.disposeAudio(handleId);
}

/// Metadata returned alongside a freshly loaded model handle.
final class LoadedModelInfo {
  const LoadedModelInfo({
    required this.handleId,
    required this.family,
    required this.supportedTasks,
  });

  final int handleId;
  final String family;
  final Set<AudioCppTask> supportedTasks;
}

/// Metadata returned alongside a freshly generated audio handle.
final class GeneratedAudioInfo {
  const GeneratedAudioInfo({
    required this.handleId,
    required this.sampleRate,
    required this.channels,
    required this.sampleCount,
  });

  final int handleId;
  final int sampleRate;
  final int channels;
  final int sampleCount;
}
