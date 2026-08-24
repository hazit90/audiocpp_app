import 'package:audiocpp/audiocpp.dart';
import 'package:flutter/foundation.dart';

import 'track.dart';

/// What each phase of a generation costs, per unit of its own work.
///
/// A generation is three phases with unrelated cost models. AR runs once per
/// audio frame and does not care how many denoising steps were asked for; flow
/// runs once per denoiser evaluation, which is chunks times steps; the vocoder
/// runs once per chunk. Measured on an M1 Max at 30 audio seconds, flow was 76%
/// of the run at 30 steps and 86% at 60, with AR unchanged in wall time across
/// both -- so the phases' *shares* are a property of the request, not of the
/// machine, and cannot be stored as fixed fractions.
///
/// Unit counts are carried alongside the rates rather than recomputed from the
/// model's frame rate and chunk geometry. Those constants live in the engine,
/// and a second copy of them in Dart would be a silent lie the first time the
/// engine's changed. During a run the engine reports the real totals anyway;
/// these are only for predicting a request that has not started.
@immutable
final class PhaseRates {
  const PhaseRates({
    required this.arMsPerFrame,
    required this.flowMsPerEval,
    required this.vocoderMsPerChunk,
    required this.sampleDurationSeconds,
    required this.sampleArFrames,
    required this.sampleChunks,
  });

  factory PhaseRates.fromJson(Map<String, Object?> json) {
    double number(String key, double fallback) {
      final value = json[key];
      return value is num && value > 0 ? value.toDouble() : fallback;
    }

    int count(String key, int fallback) {
      final value = json[key];
      return value is num && value > 0 ? value.toInt() : fallback;
    }

    return PhaseRates(
      arMsPerFrame: number('ar_ms_per_frame', seed.arMsPerFrame),
      flowMsPerEval: number('flow_ms_per_eval', seed.flowMsPerEval),
      vocoderMsPerChunk: number('vocoder_ms_per_chunk', seed.vocoderMsPerChunk),
      sampleDurationSeconds:
          count('sample_duration_seconds', seed.sampleDurationSeconds),
      sampleArFrames: count('sample_ar_frames', seed.sampleArFrames),
      sampleChunks: count('sample_chunks', seed.sampleChunks),
    );
  }

  /// Measured on an M1 Max (Metal, 8 threads, q4_0) across three runs — 30
  /// audio seconds at 30 and at 60 steps, and 60 seconds at 30 — which agreed
  /// on the per-unit cost to within 2% while the phases' shares of the run
  /// moved from 18/76/5 to 10/86/3. That is the whole argument for rates over
  /// fractions.
  ///
  /// Shipping a machine's absolute numbers as the default sounds wrong and is
  /// not: what the progress bar needs is the *ratio* between the phases, which
  /// is a property of the model, while the absolute scale is corrected within
  /// seconds of a run starting by measuring the phase actually in flight. The
  /// alternative -- no estimate at all until a first run completes -- is what
  /// this replaces.
  static const PhaseRates seed = PhaseRates(
    arMsPerFrame: 82.7,
    flowMsPerEval: 1214.0,
    vocoderMsPerChunk: 2510.0,
    sampleDurationSeconds: 30,
    sampleArFrames: 750,
    sampleChunks: 7,
  );

  final double arMsPerFrame;
  final double flowMsPerEval;
  final double vocoderMsPerChunk;

  /// The request the unit counts below were observed on.
  final int sampleDurationSeconds;
  final int sampleArFrames;
  final int sampleChunks;

  /// Phases in the order the engine runs them.
  static const List<GenerationPhase> order = <GenerationPhase>[
    GenerationPhase.ar,
    GenerationPhase.flow,
    GenerationPhase.vocoder,
  ];

  double rateFor(GenerationPhase phase) {
    switch (phase) {
      case GenerationPhase.ar:
        return arMsPerFrame;
      case GenerationPhase.flow:
        return flowMsPerEval;
      case GenerationPhase.vocoder:
        return vocoderMsPerChunk;
      case GenerationPhase.finalizing:
      case GenerationPhase.unknown:
        return 0;
    }
  }

  /// How many units [phase] will take for [params], scaled from the observed
  /// sample. Superseded by the engine's own total the moment a phase starts.
  int predictedUnits(GenerationPhase phase, GenerationParams params) {
    final scale = params.durationSeconds / sampleDurationSeconds;
    final chunks = (sampleChunks * scale).round().clamp(1, 1 << 30);
    switch (phase) {
      case GenerationPhase.ar:
        return (sampleArFrames * scale).round().clamp(1, 1 << 30);
      case GenerationPhase.flow:
        return chunks * params.inferenceSteps;
      case GenerationPhase.vocoder:
        return chunks;
      case GenerationPhase.finalizing:
      case GenerationPhase.unknown:
        return 0;
    }
  }

  /// Predicted wall time for a whole request, for a track that has not started.
  Duration predictedTotal(GenerationParams params) {
    var milliseconds = 0.0;
    for (final phase in order) {
      milliseconds += predictedUnits(phase, params) * rateFor(phase);
    }
    return Duration(milliseconds: milliseconds.round());
  }

  /// Folds a completed run's measurements in, keeping some of what was already
  /// known.
  ///
  /// Weighted rather than replaced because a single run carries the machine's
  /// mood at the time -- a thermal ceiling, another app competing -- and the
  /// next estimate should not inherit all of it. Unit counts are taken outright
  /// from the newer run: they are structural, not noisy.
  PhaseRates blendedWith(
    Map<GenerationPhase, ({int units, int total, Duration elapsed})> observed, {
    required int durationSeconds,
    double weight = 0.5,
  }) {
    double fold(GenerationPhase phase, double current) {
      final sample = observed[phase];
      if (sample == null || sample.units <= 0 || sample.elapsed <= Duration.zero) {
        return current;
      }
      final measured = sample.elapsed.inMilliseconds / sample.units;
      return current * (1 - weight) + measured * weight;
    }

    // Geometry comes from the engine's totals, never from the last position
    // polled: a phase is always a unit or so past its last reading when it
    // ends, which is noise across thousands of AR frames and a factor of two
    // across two vocoder chunks.
    final arUnits = observed[GenerationPhase.ar]?.total ?? 0;
    final chunks = observed[GenerationPhase.vocoder]?.total ?? 0;
    return PhaseRates(
      arMsPerFrame: fold(GenerationPhase.ar, arMsPerFrame),
      flowMsPerEval: fold(GenerationPhase.flow, flowMsPerEval),
      vocoderMsPerChunk: fold(GenerationPhase.vocoder, vocoderMsPerChunk),
      // Only adopt the geometry when the run actually reported it, or a
      // cancelled run would rewrite the sample with a partial one.
      sampleDurationSeconds:
          arUnits > 0 && chunks > 0 ? durationSeconds : sampleDurationSeconds,
      sampleArFrames: arUnits > 0 && chunks > 0 ? arUnits : sampleArFrames,
      sampleChunks: arUnits > 0 && chunks > 0 ? chunks : sampleChunks,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'ar_ms_per_frame': arMsPerFrame,
        'flow_ms_per_eval': flowMsPerEval,
        'vocoder_ms_per_chunk': vocoderMsPerChunk,
        'sample_duration_seconds': sampleDurationSeconds,
        'sample_ar_frames': sampleArFrames,
        'sample_chunks': sampleChunks,
      };
}
