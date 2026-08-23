import 'dart:async';
import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
import 'package:flutter/foundation.dart';

import 'platform/cpu_topology.dart';
import 'tracks/generation_engine.dart';
import 'tracks/track.dart';
import 'tracks/waveform.dart';

/// Owns the audio.cpp engine for the app and exposes it as observable state.
///
/// Model loading is deliberately separate from generation: loading MiniMax
/// Music 3 is expensive, and keeping the session resident across runs is the
/// difference between a few seconds and a few minutes per generation.
class MusicGenerationController extends ChangeNotifier
    implements GenerationEngine {
  AudioCppEngine? _engine;
  AudioCppModel? _model;
  AudioCppSession? _session;

  String? _errorMessage;
  List<AudioCppDevice> _devices = const [];
  String? _loadedModelPath;

  @override
  String? get errorMessage => _errorMessage;

  /// Path of the currently loaded model package, if any.
  @override
  String? get loadedModelPath => _loadedModelPath;

  /// Starts the worker isolate and enumerates devices.
  ///
  /// Safe to call more than once; later calls are no-ops once the engine is up.
  Future<void> initialise() async {
    if (_engine != null) {
      return;
    }
    _beginWork();
    try {
      final engine = await AudioCppEngine.start();
      _engine = engine;
      _devices = await engine.listDevices();
      notifyListeners();
    } on Object catch (error) {
      _fail(error);
    }
  }

  /// Loads a model package and creates the generation session.
  ///
  /// Replaces whatever was loaded before, releasing it first so two copies of a
  /// multi-gigabyte model are never resident at once.
  @override
  Future<void> loadModel(String modelPath) async {
    await initialise();
    final engine = _engine;
    if (engine == null) {
      return;
    }

    _beginWork();
    try {
      await _releaseModel();

      final model = await engine.loadModel(
        ModelDescriptor(
          path: modelPath,
          family: MiniMaxMusic3Request.family,
        ),
      );

      if (!model.supportsTask(MiniMaxMusic3Request.task)) {
        await model.dispose();
        throw StateError(
          'Model at $modelPath reports family "${model.family}" which does not '
          'support audio generation.',
        );
      }

      _model = model;
      _session = await model.createSession(
        SessionConfig(
          task: MiniMaxMusic3Request.task,
          backend: _preferredBackend,
          threads: _preferredThreadCount,
        ),
      );
      _loadedModelPath = modelPath;
      notifyListeners();
    } on Object catch (error) {
      await _releaseModel();
      _fail(error);
    }
  }

  /// Runs one request and writes the result to [output], returning its length.
  ///
  /// Unlike [generate] this rethrows: the queue needs to attribute a failure to
  /// the track that caused it and carry on with the next one, which it cannot
  /// do if the error is only reachable as controller state.
  @override
  Future<GenerationOutcome> runToFile({
    required GenerationParams params,
    required File output,
  }) async {
    final session = _session;
    if (session == null) {
      throw StateError('Load a model before generating.');
    }

    _beginWork();
    GeneratedAudio? audio;
    try {
      audio = await session.run(params.toRequest());
      await output.parent.create(recursive: true);
      await audio.writeWav(output.path);
      final duration = audio.duration;
      final peaks = reducePeaks(await audio.readSamples());
      notifyListeners();
      return GenerationOutcome(duration: duration, peaks: peaks);
    } on AudioCppCancelledException {
      // Not a failure, so it does not become controller error state: the user
      // asked for this and the session is still usable for the next track.
      notifyListeners();
      throw const GenerationCancelled();
    } on Object catch (error) {
      _fail(error);
      rethrow;
    } finally {
      // The native buffer is tens of megabytes; release it as soon as the file
      // is on disk rather than waiting for the next generation.
      await audio?.dispose();
    }
  }

  @override
  void requestCancel() => _engine?.requestCancel();

  @override
  void requestPause() => _engine?.requestPause();

  @override
  void requestResume() => _engine?.requestResume();

  @override
  ProgressSnapshot? get progress => _engine?.progress;

  /// Prefer the GPU when one is present; ggml picks the device itself.
  AudioCppBackend get _preferredBackend {
    final hasGpu = _devices.any((AudioCppDevice device) => device.type == 'GPU');
    return hasGpu ? AudioCppBackend.bestAvailable : AudioCppBackend.cpu;
  }

  /// Threads for the CPU backend, chosen for the CPU we are actually on.
  ///
  /// Hybrid CPUs need more than a core count — see [recommendedThreadCount].
  int get _preferredThreadCount => recommendedThreadCount();

  Future<void> _releaseModel() async {
    await _session?.dispose();
    _session = null;
    await _model?.dispose();
    _model = null;
    _loadedModelPath = null;
  }

  /// Clears the last error and announces the change.
  ///
  /// The controller used to track a lifecycle stage for the old single-shot
  /// screen. The queue owns that state now — it knows what is running, queued
  /// and failed per track — so all this has to do is not leave a stale error
  /// hanging around.
  void _beginWork() {
    _errorMessage = null;
    notifyListeners();
  }

  void _fail(Object error) {
    // AudioCppNativeException carries the engine's own message, which names the
    // missing component or bad option; anything else falls back to toString.
    _errorMessage = error is AudioCppException ? error.message : error.toString();
    notifyListeners();
  }

  /// Releases the model, session and worker isolate.
  ///
  /// Separate from [dispose] because teardown is genuinely asynchronous and
  /// `ChangeNotifier.dispose` is not. Prefer awaiting this where the caller can.
  Future<void> shutdown() async {
    await _releaseModel();
    await _engine?.dispose();
    _engine = null;
  }

  @override
  void dispose() {
    // Widget teardown cannot await, so the native release runs detached. The
    // worker isolate holds the only references, so nothing here can be used
    // after this point regardless of when the release lands.
    unawaited(shutdown());
    super.dispose();
  }
}
