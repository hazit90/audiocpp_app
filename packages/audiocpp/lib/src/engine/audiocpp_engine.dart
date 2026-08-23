import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../exceptions.dart';
import '../ffi/audiocpp_bindings.g.dart';
import '../ffi/library.dart';
import '../types.dart';
import 'protocol.dart';
import 'worker.dart';

/// Entry point to the audio.cpp engine.
///
/// All native work happens on a dedicated worker isolate, so model loading and
/// generation -- both of which block for a long time -- never stall the UI.
///
/// ```dart
/// final engine = await AudioCppEngine.start();
/// final model = await engine.loadModel(const ModelDescriptor(
///   path: '/models/MiniMax-Music3-GGUF',
///   family: MiniMaxMusic3Request.family,
/// ));
/// final session = await model.createSession(const SessionConfig(
///   task: AudioCppTask.audioGeneration,
///   backend: AudioCppBackend.metal,
/// ));
/// final audio = await session.run(MiniMaxMusic3Request(
///   caption: 'A bright pop rock song with clean drums.',
///   lyrics: '[verse] City lights are shining low.',
///   durationSeconds: 30,
/// ));
/// await audio.writeWav('/tmp/song.wav');
/// await audio.dispose();
/// await engine.dispose();
/// ```
///
/// Disposing the engine releases every model, session and audio buffer it still
/// holds, so callers do not have to unwind by hand on shutdown.
final class AudioCppEngine {
  AudioCppEngine._(this._isolate, this._commandPort, this._responses);

  final Isolate _isolate;
  final SendPort _commandPort;
  final StreamSubscription<dynamic> _responses;

  final Map<int, Completer<Object?>> _pending = {};
  int _nextRequestId = 1;
  bool _disposed = false;

  /// Spawns the worker isolate and waits for it to come up.
  ///
  /// The native library is not opened until the first command, so a missing
  /// dylib surfaces as an [AudioCppLibraryNotFoundException] from
  /// [listDevices] or [loadModel] rather than from here.
  ///
  /// [libraryPath] overrides library resolution inside the worker; it exists
  /// for tests and tooling.
  static Future<AudioCppEngine> start({String? libraryPath}) async {
    final responsePort = ReceivePort();
    final ready = Completer<SendPort>();

    late final AudioCppEngine engine;
    // Cancelled in dispose() via _responses; the lint cannot see across the
    // handoff into the AudioCppEngine constructor.
    // ignore: cancel_subscriptions
    final subscription = responsePort.listen((dynamic message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      if (message is WorkerResponse) {
        engine._completeResponse(message);
      }
    });

    final isolate = await Isolate.spawn(
      audioCppWorkerMain,
      WorkerBootstrap(replyPort: responsePort.sendPort, libraryPath: libraryPath),
      debugName: 'audiocpp-worker',
      onExit: responsePort.sendPort,
      errorsAreFatal: true,
    );

    final commandPort = await ready.future;
    engine = AudioCppEngine._(isolate, commandPort, subscription);
    return engine;
  }

  /// Enumerates the ggml devices the native library can see.
  Future<List<AudioCppDevice>> listDevices() async {
    final devices = await _send(const ListDevicesCommand());
    return (devices as List<Object?>).cast<AudioCppDevice>();
  }

  /// Loads a model package. Blocking on the worker; can take a while.
  Future<AudioCppModel> loadModel(ModelDescriptor descriptor) async {
    final info = await _send(LoadModelCommand(descriptor)) as LoadedModelInfo;
    return AudioCppModel._(this, info);
  }

  /// Asks the generation in flight to stop.
  ///
  /// Synchronous, and deliberately not a worker command. The worker isolate is
  /// blocked inside the native call for the whole run, so a message would sit
  /// in its queue until the very run it was meant to stop had finished. This
  /// goes straight to the library from the calling isolate instead.
  ///
  /// That works because Dart statics are per-isolate but `dlopen` is not: a
  /// second [AudioCppLibrary] handle resolves to the same loaded image, and so
  /// to the same flag the worker's run is reading.
  ///
  /// Returns without waiting. The stopped run completes as an
  /// [AudioCppCancelledException] out of [AudioCppSession.run], between units
  /// of work rather than instantly -- sub-second during the autoregressive
  /// phase, tens of seconds during flow. Calling it with nothing running is
  /// harmless and does not affect the next run.
  void requestCancel() {
    AudioCppLibrary.instance.audiocpp_cancel_request();
  }

  /// Suspends the generation in flight at its next checkpoint.
  ///
  /// Same isolate story as [requestCancel], and the same reason: the worker is
  /// blocked inside the run, so this goes straight to the library.
  ///
  /// A paused run keeps the model resident -- gigabytes, for a large one --
  /// because that is precisely why resuming produces the audio the run would
  /// have produced anyway. Nothing is torn down and no sampling state is
  /// rebuilt.
  ///
  /// Only [requestCancel] wakes a paused run. Nothing else does, so a caller
  /// that pauses and then awaits the run without resuming or cancelling waits
  /// forever.
  void requestPause() {
    AudioCppLibrary.instance.audiocpp_pause_request();
  }

  /// Lets a paused generation carry on. Harmless if it is not paused.
  void requestResume() {
    AudioCppLibrary.instance.audiocpp_resume_request();
  }

  /// How far the generation in flight has got.
  ///
  /// Same isolate story as [requestCancel]: the worker is blocked inside the
  /// run, so this is read straight from the library by whichever isolate asks.
  /// That is also why progress is polled rather than pushed -- a callback would
  /// be delivered to the blocked isolate and arrive after the run it described.
  ///
  /// Cheap enough for a UI timer: one lock and a struct copy, no allocation
  /// beyond the out parameter. Null if the library cannot be reached at all,
  /// which is the case in tests that never open it.
  ProgressSnapshot? get progress {
    final out = calloc<audiocpp_progress>();
    try {
      final status =
          AudioCppLibrary.instance.audiocpp_progress_query(out);
      if (status != audiocpp_status.AUDIOCPP_OK.value) {
        return null;
      }
      final value = out.ref;
      return ProgressSnapshot(
        phase: GenerationPhase.fromNative(value.phase),
        runSerial: value.run_serial,
        done: value.done,
        total: value.total,
        phaseElapsed: Duration(milliseconds: value.phase_elapsed_ms),
      );
    } on AudioCppException {
      // This isolate never opened the library, so there is nothing running to
      // report on. Matches dispose()'s handling of the same case.
      return null;
    } finally {
      calloc.free(out);
    }
  }

  /// Shuts the worker down, releasing every handle it still owns.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;

    // A generation in flight owns the worker isolate, so the shutdown below
    // would sit in its queue until the run finished on its own -- the 30s
    // timeout would expire and the kill would land on an isolate still inside a
    // native call. Asking the run to stop first is what makes closing an app
    // mid-generation take a moment instead of minutes.
    try {
      requestCancel();
    } on AudioCppException {
      // This isolate never opened the library, so nothing here is running.
      // Disposing an engine that was never used must not fail.
    }

    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commandPort.send(ShutdownRequest(id));

    // The worker frees potentially many gigabytes here; give it room, but do
    // not hang forever if it has already died.
    await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => null,
    );

    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          const AudioCppDisposedException('engine was disposed before the command completed'),
        );
      }
    }
    _pending.clear();

    await _responses.cancel();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  Future<Object?> _send(WorkerCommand command) {
    if (_disposed) {
      throw const AudioCppDisposedException('engine has been disposed');
    }
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commandPort.send(WorkerRequest(id, command));
    return completer.future;
  }

  void _completeResponse(WorkerResponse response) {
    final completer = _pending.remove(response.id);
    if (completer == null || completer.isCompleted) {
      return;
    }
    if (response.isSuccess) {
      completer.complete(response.value);
    } else {
      completer.completeError(
        response.error!,
        StackTrace.fromString(response.stackTrace ?? ''),
      );
    }
  }
}

/// A model package loaded into memory.
final class AudioCppModel {
  AudioCppModel._(this._engine, this._info);

  final AudioCppEngine _engine;
  final LoadedModelInfo _info;
  bool _disposed = false;

  /// Family the registry resolved this package to, e.g. `minimax_music3`.
  String get family => _info.family;

  /// Tasks this model advertises in offline mode.
  Set<AudioCppTask> get supportedTasks => _info.supportedTasks;

  bool supportsTask(AudioCppTask task) => _info.supportedTasks.contains(task);

  /// Creates an offline session. Fails if the model does not support [SessionConfig.task].
  Future<AudioCppSession> createSession(SessionConfig config) async {
    _assertUsable();
    final handleId = await _engine._send(CreateSessionCommand(_info.handleId, config)) as int;
    return AudioCppSession._(_engine, handleId);
  }

  /// Releases the model and every session created from it.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _engine._send(DisposeModelCommand(_info.handleId));
  }

  void _assertUsable() {
    if (_disposed) {
      throw AudioCppDisposedException('model "$family" has been disposed');
    }
  }
}

/// A configured offline inference session.
final class AudioCppSession {
  AudioCppSession._(this._engine, this._handleId);

  final AudioCppEngine _engine;
  final int _handleId;
  bool _disposed = false;

  /// Runs one inference.
  ///
  /// For MiniMax Music 3 this occupies the worker for minutes. Only one run
  /// executes at a time per engine; further calls queue behind it.
  Future<GeneratedAudio> run(InferenceRequest request) async {
    _assertUsable();
    final info = await _engine._send(RunCommand(_handleId, request)) as GeneratedAudioInfo;
    return GeneratedAudio._(_engine, info);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _engine._send(DisposeSessionCommand(_handleId));
  }

  void _assertUsable() {
    if (_disposed) {
      throw const AudioCppDisposedException('session has been disposed');
    }
  }
}

/// Audio produced by a session.
///
/// The samples stay in native memory until [readSamples] is called, so writing
/// straight to a file with [writeWav] never pulls a large buffer through the
/// Dart heap. Call [dispose] when finished.
final class GeneratedAudio {
  GeneratedAudio._(this._engine, this._info);

  final AudioCppEngine _engine;
  final GeneratedAudioInfo _info;
  bool _disposed = false;

  int get sampleRate => _info.sampleRate;
  int get channels => _info.channels;

  /// Total floats across all channels (interleaved), not per-channel frames.
  int get sampleCount => _info.sampleCount;

  /// Playback length, derived from [sampleCount], [channels] and [sampleRate].
  Duration get duration {
    if (sampleRate <= 0 || channels <= 0) {
      return Duration.zero;
    }
    final frames = sampleCount ~/ channels;
    return Duration(microseconds: (frames * 1000000 / sampleRate).round());
  }

  /// Copies the interleaved float samples into the Dart heap.
  Future<Float32List> readSamples() async {
    _assertUsable();
    return await _engine._send(ReadSamplesCommand(_info.handleId)) as Float32List;
  }

  /// Writes a 16-bit PCM WAV file using audio.cpp's own writer.
  Future<void> writeWav(String path) async {
    _assertUsable();
    await _engine._send(WriteWavCommand(_info.handleId, path));
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _engine._send(DisposeAudioCommand(_info.handleId));
  }

  void _assertUsable() {
    if (_disposed) {
      throw const AudioCppDisposedException('audio buffer has been disposed');
    }
  }
}
