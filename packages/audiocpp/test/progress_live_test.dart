@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs a real generation and watches it report progress.
///
/// Everything else about progress can be tested with a fake, except the one
/// thing that made the design what it is: the isolate that calls into the
/// engine is blocked inside it for the whole run, so readings have to be pulled
/// from another isolate entirely. That is only true against the real dylib.
///
/// Skipped unless AUDIOCPP_TEST_MODEL points at a model package, because it
/// costs minutes and gigabytes:
///
/// ```
/// AUDIOCPP_TEST_MODEL=~/Downloads/MiniMax-Music3-GGUF \
///   flutter test test/progress_live_test.dart
/// ```
void main() {
  final libraryFile = File('macos/Libs/libaudiocpp_ffi.dylib');
  final modelPath = Platform.environment['AUDIOCPP_TEST_MODEL'];
  final skipReason = !libraryFile.existsSync()
      ? 'libaudiocpp_ffi.dylib not built; run tool/build_macos.sh'
      : modelPath == null
          ? 'set AUDIOCPP_TEST_MODEL to a model package to run this'
          : null;

  test('a run reports its phases while the calling isolate is blocked in it',
      () async {
    final engine = await AudioCppEngine.start(
      libraryPath: libraryFile.absolute.path,
    );
    addTearDown(engine.dispose);

    final model = await engine.loadModel(
      ModelDescriptor(path: modelPath!, family: MiniMaxMusic3Request.family),
    );
    final session = await model.createSession(
      const SessionConfig(
        task: AudioCppTask.audioGeneration,
        backend: AudioCppBackend.bestAvailable,
      ),
    );

    // Nothing is running yet, so there is nothing to report.
    expect(engine.progress?.isReporting, isNot(isTrue));

    final started = DateTime.now();
    final readings = <ProgressSnapshot>[];
    final boundaries = <GenerationPhase, Duration>{};

    // Deliberately not awaited: the point is to poll while it runs.
    final run = session.run(MiniMaxMusic3Request(
      caption: 'warm analog synth pop, steady drums, bright and hopeful',
      lyrics: '[verse]\nA fixed line for a fixed run\n',
      durationSeconds: 30,
      inferenceSteps: 30,
      seed: 1,
    ));

    final poller = Timer.periodic(const Duration(milliseconds: 500), (Timer _) {
      final snapshot = engine.progress;
      if (snapshot == null || !snapshot.isReporting) {
        return;
      }
      if (!boundaries.containsKey(snapshot.phase)) {
        boundaries[snapshot.phase] = DateTime.now().difference(started);
      }
      readings.add(snapshot);
    });

    final audio = await run;
    poller.cancel();
    addTearDown(audio.dispose);

    for (final entry in boundaries.entries) {
      // ignore: avoid_print
      print('${entry.key.name} began at ${entry.value.inSeconds}s');
    }

    expect(readings, isNotEmpty, reason: 'the run never reported anything');

    // Every reading belongs to this run.
    final serials = readings.map((ProgressSnapshot r) => r.runSerial).toSet();
    expect(serials, hasLength(1));

    // The phases arrive in the order the pipeline runs them.
    final seen = <GenerationPhase>[];
    for (final reading in readings) {
      if (seen.isEmpty || seen.last != reading.phase) {
        seen.add(reading.phase);
      }
    }
    expect(
      seen.where((GenerationPhase p) => p != GenerationPhase.finalizing),
      <GenerationPhase>[
        GenerationPhase.ar,
        GenerationPhase.flow,
        GenerationPhase.vocoder,
      ],
    );

    // Within a phase, position only advances, and never past the total.
    for (var i = 1; i < readings.length; i++) {
      final previous = readings[i - 1];
      final current = readings[i];
      expect(current.done, lessThanOrEqualTo(current.total));
      if (current.phase == previous.phase) {
        expect(current.done, greaterThanOrEqualTo(previous.done));
      }
    }

    // The flow phase is counted across every chunk rather than restarting at
    // each one, which is what set_progress_span exists for.
    final flow = readings
        .where((ProgressSnapshot r) => r.phase == GenerationPhase.flow)
        .toList();
    expect(flow.last.done, greaterThan(flow.first.done));
    expect(flow.last.total, greaterThan(30),
        reason: 'a single chunk of steps, not the whole phase');

    await session.dispose();
  }, timeout: const Timeout(Duration(minutes: 40)), skip: skipReason);
}
