import 'dart:async';
import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
import 'package:flutter/foundation.dart';

/// Where the controller currently is in the load/generate lifecycle.
enum GenerationStage {
  /// Nothing started yet.
  idle,

  /// Worker isolate coming up.
  startingEngine,

  /// Reading the model package off disk.
  loadingModel,

  /// Model resident, ready to generate.
  ready,

  /// Inference in flight.
  generating,

  /// The last operation failed; see [MusicGenerationController.errorMessage].
  failed,
}

/// Owns the audio.cpp engine for the app and exposes it as observable state.
///
/// Model loading is deliberately separate from generation: loading MiniMax
/// Music 3 is expensive, and keeping the session resident across runs is the
/// difference between a few seconds and a few minutes per generation.
class MusicGenerationController extends ChangeNotifier {
  AudioCppEngine? _engine;
  AudioCppModel? _model;
  AudioCppSession? _session;

  GenerationStage _stage = GenerationStage.idle;
  String? _errorMessage;
  List<AudioCppDevice> _devices = const [];
  String? _loadedModelPath;
  File? _lastOutput;
  Duration? _lastOutputDuration;

  GenerationStage get stage => _stage;
  String? get errorMessage => _errorMessage;
  List<AudioCppDevice> get devices => _devices;

  /// Path of the currently loaded model package, if any.
  String? get loadedModelPath => _loadedModelPath;

  /// WAV file written by the most recent successful generation.
  File? get lastOutput => _lastOutput;

  /// Playback length of [lastOutput].
  Duration? get lastOutputDuration => _lastOutputDuration;

  bool get isBusy =>
      _stage == GenerationStage.startingEngine ||
      _stage == GenerationStage.loadingModel ||
      _stage == GenerationStage.generating;

  bool get canGenerate => _stage == GenerationStage.ready;

  /// Starts the worker isolate and enumerates devices.
  ///
  /// Safe to call more than once; later calls are no-ops once the engine is up.
  Future<void> initialise() async {
    if (_engine != null) {
      return;
    }
    _setStage(GenerationStage.startingEngine);
    try {
      final engine = await AudioCppEngine.start();
      _engine = engine;
      _devices = await engine.listDevices();
      _setStage(GenerationStage.idle);
    } on Object catch (error) {
      _fail(error);
    }
  }

  /// Loads a model package and creates the generation session.
  ///
  /// Replaces whatever was loaded before, releasing it first so two copies of a
  /// multi-gigabyte model are never resident at once.
  Future<void> loadModel(String modelPath) async {
    await initialise();
    final engine = _engine;
    if (engine == null) {
      return;
    }

    _setStage(GenerationStage.loadingModel);
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
      _setStage(GenerationStage.ready);
    } on Object catch (error) {
      await _releaseModel();
      _fail(error);
    }
  }

  /// Generates one track and writes it to a WAV file in the system temp dir.
  Future<void> generate({
    required String caption,
    required String lyrics,
    int durationSeconds = 30,
    int inferenceSteps = 30,
    int seed = 0,
  }) async {
    final session = _session;
    if (session == null) {
      _errorMessage = 'Load a model before generating.';
      _stage = GenerationStage.failed;
      notifyListeners();
      return;
    }

    _setStage(GenerationStage.generating);
    GeneratedAudio? audio;
    try {
      audio = await session.run(
        MiniMaxMusic3Request(
          caption: caption,
          lyrics: lyrics,
          durationSeconds: durationSeconds,
          inferenceSteps: inferenceSteps,
          seed: seed,
        ),
      );

      final output = File(
        '${Directory.systemTemp.path}/audiocpp_'
        '${DateTime.now().millisecondsSinceEpoch}.wav',
      );
      await audio.writeWav(output.path);

      _lastOutput = output;
      _lastOutputDuration = audio.duration;
      _setStage(GenerationStage.ready);
    } on Object catch (error) {
      _fail(error);
    } finally {
      // The native buffer is tens of megabytes; release it as soon as the file
      // is on disk rather than waiting for the next generation.
      await audio?.dispose();
    }
  }

  /// Prefer the GPU when one is present; ggml picks the device itself.
  AudioCppBackend get _preferredBackend {
    final hasGpu = _devices.any((AudioCppDevice device) => device.type == 'GPU');
    return hasGpu ? AudioCppBackend.bestAvailable : AudioCppBackend.cpu;
  }

  /// Leave a couple of cores for the UI and the OS.
  int get _preferredThreadCount {
    final cores = Platform.numberOfProcessors;
    return cores > 4 ? cores - 2 : cores;
  }

  Future<void> _releaseModel() async {
    await _session?.dispose();
    _session = null;
    await _model?.dispose();
    _model = null;
    _loadedModelPath = null;
  }

  void _setStage(GenerationStage stage) {
    _stage = stage;
    _errorMessage = null;
    notifyListeners();
  }

  void _fail(Object error) {
    // AudioCppNativeException carries the engine's own message, which names the
    // missing component or bad option; anything else falls back to toString.
    _errorMessage = error is AudioCppException ? error.message : error.toString();
    _stage = GenerationStage.failed;
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
