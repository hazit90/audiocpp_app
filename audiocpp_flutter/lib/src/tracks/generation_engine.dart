import 'dart:io';

import 'package:flutter/foundation.dart';

import 'track.dart';

/// What one completed generation yields.
///
/// Peaks are computed here, while the samples are still in memory, rather than
/// by re-reading the WAV later: the engine has just produced them and the cost
/// is one pass over a buffer that is about to be freed anyway.
@immutable
final class GenerationOutcome {
  const GenerationOutcome({required this.duration, required this.peaks});

  final Duration duration;

  /// Amplitude buckets, 0-255. See `waveform.dart`.
  final List<int> peaks;
}

/// The slice of the engine the queue actually needs.
///
/// Narrow on purpose: it keeps the queue's own logic — ordering, retries,
/// abandonment, estimates — testable without a dylib, which matters because
/// `flutter test` runs on the Dart VM with no native library to load and a real
/// generation takes minutes.
abstract interface class GenerationEngine {
  /// Path of the model package currently resident, if any.
  String? get loadedModelPath;

  /// Message from the last failure, if any.
  String? get errorMessage;

  /// Makes [modelPath] resident, replacing whatever was loaded before.
  Future<void> loadModel(String modelPath);

  /// Runs one request to completion, writing a WAV to [output].
  ///
  /// Throws on failure rather than reporting through state: the queue has to
  /// attribute the failure to one track and carry on with the next.
  ///
  /// Throws [GenerationCancelled] instead if [requestCancel] was called during
  /// the run.
  Future<GenerationOutcome> runToFile({
    required GenerationParams params,
    required File output,
  });

  /// Asks the run in flight to stop.
  ///
  /// Returns immediately and does not wait: the engine honours it between
  /// units of work, so the run it stops may take a little longer to unwind.
  /// Safe to call with nothing running.
  void requestCancel();
}

/// Raised by [GenerationEngine.runToFile] when the run was stopped on request.
///
/// Distinct from a failure so the queue can tell "the user stopped this" from
/// "this broke", which are two very different things to show in the library.
final class GenerationCancelled implements Exception {
  const GenerationCancelled();

  @override
  String toString() => 'GenerationCancelled';
}
