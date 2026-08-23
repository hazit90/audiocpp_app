import 'dart:async';
import 'dart:io';

import 'package:audiocpp_flutter/src/tracks/generation_engine.dart';
import 'package:audiocpp_flutter/src/tracks/track.dart';

/// A stand-in for the engine.
///
/// Generation is the one thing that cannot be exercised for real here — there
/// is no dylib on the test VM and a run takes minutes — so the fake reproduces
/// only what the queue depends on: it blocks until released, and it fails when
/// told to.
final class FakeEngine implements GenerationEngine {
  @override
  String? loadedModelPath;

  @override
  String? errorMessage;

  final List<String> loads = <String>[];
  final List<GenerationParams> runs = <GenerationParams>[];

  /// Runs to fail, matched against the caption as a substring.
  final Set<String> failCaptions = <String>{};

  /// Set to make [loadModel] a no-op that leaves nothing resident.
  bool loadSilentlyFails = false;

  Duration produced = const Duration(seconds: 32);

  /// Peaks handed back with each successful run.
  List<int> producedPeaks = const <int>[0, 128, 255, 64];

  Completer<void>? _gate;
  Completer<void>? _loadGate;

  /// Mirrors the real engine: set by [requestCancel], cleared when a run
  /// starts, and honoured at one point mid-run rather than instantly.
  bool _cancelRequested = false;

  /// Blocks the run while paused, as the engine does — rather than unwinding.
  bool _paused = false;
  Completer<void>? _pauseGate;

  /// How many times a cancel was asked for, so a test can tell "the queue
  /// called through" from "the run happened to end".
  int cancelRequests = 0;

  /// Makes the next run block until [release] is called.
  void hold() => _gate = Completer<void>();

  void release() {
    _gate?.complete();
    _gate = null;
  }

  /// Makes the next [loadModel] block until [releaseLoad] is called.
  ///
  /// Loading a real package is gigabytes and the longest stretch of a first
  /// generation, which makes it the widest window for a cancel to land in.
  void holdLoad() => _loadGate = Completer<void>();

  void releaseLoad() {
    _loadGate?.complete();
    _loadGate = null;
  }

  @override
  Future<void> loadModel(String modelPath) async {
    loads.add(modelPath);
    final gate = _loadGate;
    if (gate != null) {
      await gate.future;
    }
    if (loadSilentlyFails) {
      errorMessage = 'no such package';
      return;
    }
    loadedModelPath = modelPath;
  }

  @override
  void requestCancel() {
    cancelRequests++;
    _cancelRequested = true;
    // Mirrors the engine: cancelling wakes a paused run, which is the only way
    // one ever ends.
    _paused = false;
    _pauseGate?.complete();
    _pauseGate = null;
  }

  @override
  void requestPause() {
    _paused = true;
    _pauseGate ??= Completer<void>();
  }

  @override
  void requestResume() {
    _paused = false;
    _pauseGate?.complete();
    _pauseGate = null;
  }

  @override
  Future<GenerationOutcome> runToFile({
    required GenerationParams params,
    required File output,
  }) async {
    runs.add(params);
    // Cleared on entry, like the shim: a cancel with nothing running must not
    // stop whatever starts next.
    _cancelRequested = false;
    // Real elapsed time, so the queue's estimate has something to measure.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final gate = _gate;
    if (gate != null) {
      await gate.future;
    }
    // Blocks rather than returning, as a real paused run does.
    while (_paused) {
      await _pauseGate!.future;
    }
    // After the gate, standing in for the engine noticing between units of
    // work rather than the instant the flag is set.
    if (_cancelRequested) {
      _cancelRequested = false;
      throw const GenerationCancelled();
    }
    if (failCaptions.any(params.caption.contains)) {
      throw StateError('out of memory during flow stage');
    }
    await output.parent.create(recursive: true);
    await output.writeAsBytes(<int>[0, 1, 2]);
    return GenerationOutcome(duration: produced, peaks: producedPeaks);
  }
}
