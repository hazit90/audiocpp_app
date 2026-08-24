import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
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
  ///
  /// [family] is the registry family the package belongs to. It is passed in
  /// rather than sniffed from the files because the registry takes it as a
  /// hint, and the track already knows which family it was built for.
  Future<void> loadModel(String modelPath, {required String family});

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

  /// Suspends the run in flight at its next checkpoint.
  ///
  /// The model stays resident while paused, which is what lets the run carry on
  /// afterwards as though it had never stopped. Only [requestCancel] wakes it.
  void requestPause();

  /// Lets a paused run carry on. Harmless if it is not paused.
  void requestResume();

  /// How far the run in flight has got, or null when there is nothing to say.
  ///
  /// A poll rather than a stream, and not because a stream would be harder to
  /// write: the isolate that starts a run is blocked inside it for the whole
  /// run, so pushed events would queue behind the very run they describe. The
  /// queue reads this on the timer it already runs for the elapsed readout.
  ///
  /// Null for a library or model family that does not report, which the UI
  /// shows as indeterminate rather than as a run stuck at zero.
  ProgressSnapshot? get progress;
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
