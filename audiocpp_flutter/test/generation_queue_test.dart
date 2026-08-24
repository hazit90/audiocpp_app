import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
import 'package:audiocpp_flutter/src/tracks/generation_queue.dart';
import 'package:audiocpp_flutter/src/tracks/phase_rates.dart';
import 'package:audiocpp_flutter/src/tracks/track.dart';
import 'package:audiocpp_flutter/src/tracks/track_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine.dart';

/// A few event-loop turns — enough for the drain loop to reach its first await,
/// while leaving a held generation in flight.
Future<void> pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Waits until the engine has actually begun a run.
///
/// `pump()` is not enough for anything that means "cancel a generation in
/// flight": the queue writes to disk and loads a model first, and a cancel that
/// arrives during the load takes a different path on purpose -- the run is
/// skipped rather than stopped. Waiting for the run to start is what keeps the
/// two cases apart instead of racing between them.
Future<void> started(FakeEngine engine) async {
  for (var i = 0; i < 500 && engine.runs.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Waits for the queue's one-second ticker to poll the engine.
///
/// Progress is polled rather than pushed -- the isolate running a generation is
/// blocked inside it -- so a test has to let the timer fire to see a reading
/// land, exactly as the UI does.
Future<void> ticked() async {
  await Future<void>.delayed(const Duration(milliseconds: 1100));
}

/// Waits until the queue has nothing left to run. Bounded so a bug stalls one
/// test rather than the suite.
Future<void> drained(GenerationQueue queue) async {
  for (var i = 0; i < 500 && (queue.isBusy || queue.pending.isNotEmpty); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  await pump();
}

/// A queue with its own store, engine and directory.
///
/// For tests that dispose the queue themselves and so must not collide with the
/// shared teardown disposing it a second time.
final class OwnQueue {
  OwnQueue(this.queue, this.engine, this._root);

  final GenerationQueue queue;
  final FakeEngine engine;
  final Directory _root;

  Future<void> cleanUp() async {
    for (var i = 0; i < 200 && queue.isBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    if (_root.existsSync()) {
      await _root.delete(recursive: true);
    }
  }
}

Future<OwnQueue> ownQueue({Duration? stopGrace, Duration? pauseLimit}) async {
  final root = await Directory.systemTemp.createTemp('audiocpp_dispose_test');
  final store = TrackStore(root: root);
  await store.load();
  final engine = FakeEngine();
  final queue = GenerationQueue(
    store: store,
    engine: engine,
    resolveModelPath: (String id) async => '/models/$id',
    stopGrace: stopGrace ?? const Duration(milliseconds: 400),
    pauseLimit: pauseLimit ?? const Duration(minutes: 10),
  );
  queue.restore();
  return OwnQueue(queue, engine, root);
}

void main() {
  late Directory root;
  late TrackStore store;
  late FakeEngine engine;
  late GenerationQueue queue;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('audiocpp_queue_test');
    store = TrackStore(root: root);
    await store.load();
    engine = FakeEngine();
    queue = GenerationQueue(
      store: store,
      engine: engine,
      resolveModelPath: (String id) async =>
          id == 'missing' ? null : '/models/$id',
    );
    queue.restore();
  });

  tearDown(() async {
    engine.release();
    await drained(queue);
    queue.dispose();
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Future<Track> add(String caption, {int steps = 30, int seconds = 30}) {
    return queue.enqueue(
      params: GenerationParams(
        caption: caption,
        lyrics: '',
        inferenceSteps: steps,
        durationSeconds: seconds,
      ),
      modelPackageId: 'minimax_music3_q4_0',
      title: caption,
    );
  }


  test('the track\'s family reaches the engine, not a hardcoded one', () async {
    // Two families can be installed at once, and the registry takes the family
    // as a load hint. Loading a Stable Audio package as minimax_music3 fails in
    // a way that reads like a corrupt download.
    await queue.enqueue(
      params: const GenerationParams(
        caption: 'uplifting house music',
        lyrics: '',
        family: 'stable_audio',
      ),
      modelPackageId: 'stable_audio_3_small_music_q8_0',
      title: 'house',
    );
    await drained(queue);

    expect(engine.loadedFamilies, <String>['stable_audio']);
  });

  test('a track with no recorded family still loads as MiniMax', () async {
    // Everything written before a second family existed omits the field.
    final params = GenerationParams.fromJson(<String, Object?>{
      'caption': 'old track',
      'lyrics': 'la la',
    });

    expect(params.family, 'minimax_music3');
    expect(params.toRequest(), isA<MiniMaxMusic3Request>());
  });

  test('params build the request their family calls for', () async {
    const stable = GenerationParams(
      caption: 'ambient drone',
      lyrics: 'ignored',
      family: 'stable_audio',
      negativePrompt: 'vocals',
      inferenceSteps: 8,
    );

    final request = stable.toRequest();
    expect(request, isA<StableAudio3Request>());
    // The lyrics field is carried on the params but must not reach an engine
    // that has no lyrics input.
    expect(request.options.containsKey('lyrics'), isFalse);
    expect(request.options['negative_prompt'], 'vocals');
  });

  test('enqueue returns immediately and the track lands as queued', () async {
    engine.hold();
    final track = await add('first');

    expect(track.status, TrackStatus.queued);
    expect(store.tracks.single.id, track.id);

    engine.release();
    await drained(queue);
  });

  test('drains in order and marks each done', () async {
    await add('first');
    await add('second');
    await drained(queue);

    expect(engine.runs.map((GenerationParams p) => p.caption),
        <String>['first', 'second']);
    expect(store.tracks.every((Track t) => t.status == TrackStatus.done),
        isTrue);
    expect(store.tracks.every((Track t) => t.queueOrder == null), isTrue);
  });

  test('a finished track has audio on disk and a duration', () async {
    final track = await add('first');
    await drained(queue);

    final done = store.tracks.single;
    expect(done.status, TrackStatus.done);
    expect(done.audioFileName, '${track.id}.wav');
    expect(store.audioFileFor(done)!.existsSync(), isTrue);
    expect(done.duration, const Duration(seconds: 32));
    expect(done.completedAt, isNotNull);
    // Peaks come back with the run and are stored, so the waveform never has
    // to re-read the audio.
    expect(done.peaks, engine.producedPeaks);
  });

  test('the model is loaded once and kept resident across tracks', () async {
    await add('first');
    await add('second');
    await drained(queue);

    expect(engine.loads, <String>['/models/minimax_music3_q4_0']);
  });

  test('a failure fails only its own track and the queue carries on', () async {
    engine.failCaptions.add('bad');
    await add('bad');
    await add('good');
    await drained(queue);

    final bad = store.tracks.firstWhere((Track t) => t.title == 'bad');
    final good = store.tracks.firstWhere((Track t) => t.title == 'good');
    expect(bad.status, TrackStatus.failed);
    expect(bad.errorMessage, contains('out of memory'));
    expect(bad.queueOrder, isNull);
    expect(good.status, TrackStatus.done);
  });

  test('an uninstalled model fails the track with a usable message', () async {
    await queue.enqueue(
      params: const GenerationParams(caption: 'x', lyrics: ''),
      modelPackageId: 'missing',
      title: 'x',
    );
    await drained(queue);

    expect(store.tracks.single.status, TrackStatus.failed);
    expect(store.tracks.single.errorMessage, contains('not installed'));
  });

  test('a load that leaves nothing resident is not treated as success',
      () async {
    engine.loadSilentlyFails = true;
    await add('first');
    await drained(queue);

    expect(engine.runs, isEmpty);
    expect(store.tracks.single.status, TrackStatus.failed);
  });

  test('retry puts a failed track back at the end of the queue', () async {
    engine.failCaptions.add('bad');
    final bad = await add('bad');
    await drained(queue);
    expect(store.tracks.single.status, TrackStatus.failed);

    engine.failCaptions.clear();
    await queue.retry(bad.id);
    await drained(queue);

    expect(store.tracks.single.status, TrackStatus.done);
  });

  test('cancelling a queued track removes it before it runs', () async {
    engine.hold();
    await add('first');
    final second = await add('second');
    await pump();

    await queue.cancel(second.id);
    engine.release();
    await drained(queue);

    expect(engine.runs.map((GenerationParams p) => p.caption),
        <String>['first']);
    expect(store.tracks, hasLength(1));
  });

  test('discarding the running track removes it at once and drops the result',
      () async {
    engine.hold();
    final first = await add('first');
    await started(engine);

    await queue.cancel(first.id);
    // Gone from the library immediately: "discard" means the same thing whether
    // or not the work had started.
    expect(store.tracks, isEmpty);
    expect(queue.isAbandoned(first.id), isTrue);
    // Nothing is said about stopping yet: a stop normally lands in a fraction
    // of a second, and announcing one that is about to succeed would put a
    // strip on screen for two frames.
    expect(queue.isStopping, isFalse);

    // This run is held open, standing in for one already past its last check.
    // Once the grace has passed, the pane has to say the machine is still busy
    // rather than look idle.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(queue.isStopping, isTrue);

    engine.release();
    await drained(queue);

    expect(engine.runs, hasLength(1));
    expect(store.tracks, isEmpty);
    expect(queue.isStopping, isFalse);
  });

  test('discarding the running track asks the engine to stop', () async {
    engine.hold();
    final first = await add('first');
    await add('second');
    await started(engine);

    await queue.cancel(first.id);
    expect(engine.cancelRequests, 1);

    engine.release();
    await drained(queue);

    // The stop landed, so the run ended as cancelled rather than producing a
    // track -- and the queue carried on to the next one regardless.
    expect(store.tracks.single.title, 'second');
    expect(store.tracks.single.status, TrackStatus.done);
  });

  test('a cancelled run is not a failure', () async {
    engine.hold();
    final first = await add('first');
    await started(engine);

    await queue.cancel(first.id);
    engine.release();
    await drained(queue);

    // Nothing left behind at all: no track, and in particular no failed one
    // carrying an error the user never caused.
    expect(store.tracks, isEmpty);
  });

  test('discarding during the model load stops the run that follows it',
      () async {
    // The engine clears its cancel flag when a run starts, so a discard during
    // the load would otherwise be erased and the generation would go ahead in
    // full -- minutes of work the user already stopped.
    engine.holdLoad();
    final first = await add('first');
    await pump();

    await queue.cancel(first.id);
    engine.releaseLoad();
    await drained(queue);

    expect(engine.runs, isEmpty);
    expect(store.tracks, isEmpty);
  });

  test('a discard during the load does not stop the track behind it', () async {
    engine.holdLoad();
    final first = await add('first');
    await add('second');
    await pump();

    await queue.cancel(first.id);
    engine.releaseLoad();
    await drained(queue);

    // Only the discarded one is skipped; the queue carries on normally.
    expect(engine.runs.map((GenerationParams p) => p.caption),
        <String>['second']);
    expect(store.tracks.single.status, TrackStatus.done);
  });

  test('disposing while a generation runs asks it to stop', () async {
    // Its own queue: these tests dispose the thing under test, and the shared
    // teardown disposes it again.
    final own = await ownQueue();
    own.engine.hold();
    await own.queue.enqueue(
      params: const GenerationParams(caption: 'first', lyrics: ''),
      modelPackageId: 'minimax_music3_q4_0',
      title: 'first',
    );
    await started(own.engine);

    own.queue.dispose();

    // Quitting mid-run would otherwise leave every teardown command queued
    // behind a generation with minutes left on it.
    expect(own.engine.cancelRequests, 1);

    own.engine.release();
    await own.cleanUp();
  });

  test('disposing with nothing running asks for nothing', () async {
    final own = await ownQueue();
    own.queue.dispose();
    expect(own.engine.cancelRequests, 0);
    await own.cleanUp();
  });

  test('a cancel with nothing running does not stop the next track', () async {
    // Mirrors the shim clearing its flag when a run starts.
    engine.requestCancel();

    await add('first');
    await drained(queue);

    expect(store.tracks.single.status, TrackStatus.done);
  });

  test('discarding a running track leaves no audio behind', () async {
    engine.hold();
    final first = await add('first');
    await started(engine);
    await queue.cancel(first.id);

    engine.release();
    await drained(queue);

    // The run wrote its WAV before anyone knew it was unwanted. Nothing points
    // at it now, so it must not be left for the next startup to sweep up.
    final leftover = store.audioDirectory.existsSync()
        ? store.audioDirectory.listSync()
        : const <FileSystemEntity>[];
    expect(leftover, isEmpty);
  });

  test('the estimate survives the track being discarded', () async {
    // One completed run gives the queue something to extrapolate from.
    await add('calibrate');
    await drained(queue);

    engine.hold();
    final running = await add('running');
    await add('waiting');
    await started(engine);

    await queue.cancel(running.id);
    // The discarded work still occupies the engine, so the track waiting behind
    // it is still waiting for that time to pass.
    expect(queue.runningEstimatedRemaining, isNotNull);
    expect(queue.estimatedWait, isNotNull);

    engine.release();
    await drained(queue);
  });

  test('pausing suspends the run rather than ending it', () async {
    engine.hold();
    final first = await add('first');
    await started(engine);

    queue.setRunPaused(true);
    expect(queue.isRunPaused, isTrue);
    // The track is still there and still running; pause is not a discard.
    expect(store.tracks.single.id, first.id);
    expect(store.tracks.single.status, TrackStatus.running);

    queue.setRunPaused(false);
    expect(queue.isRunPaused, isFalse);

    engine.release();
    await drained(queue);

    // And it produced its audio, because nothing was torn down.
    expect(store.tracks.single.status, TrackStatus.done);
  });

  test('a paused run is still stoppable', () async {
    engine.hold();
    final first = await add('first');
    await started(engine);
    queue.setRunPaused(true);

    // The engine wakes a paused run on cancel; if the queue did not follow, a
    // paused generation could never be stopped at all.
    await queue.cancel(first.id);
    expect(queue.isRunPaused, isFalse);

    engine.release();
    await drained(queue);
    expect(store.tracks, isEmpty);
  });

  test('paused time is left out of the elapsed readout', () async {
    engine.hold();
    await add('first');
    await started(engine);

    queue.setRunPaused(true);
    final atPause = queue.runningElapsed!;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final afterWaiting = queue.runningElapsed!;

    // The machine did nothing in between, so neither should the clock.
    expect(
      (afterWaiting - atPause).inMilliseconds.abs(),
      lessThan(100),
    );

    queue.setRunPaused(false);
    engine.release();
    await drained(queue);
  });

  test('a pause left alone becomes a stop', () async {
    final own = await ownQueue(pauseLimit: const Duration(milliseconds: 150));
    own.engine.hold();
    final first = await own.queue.enqueue(
      params: const GenerationParams(caption: 'first', lyrics: ''),
      modelPackageId: 'minimax_music3_q4_0',
      title: 'first',
    );
    await started(own.engine);
    own.queue.setRunPaused(true);
    expect(own.queue.isRunPaused, isTrue);
    expect(first.id, isNotEmpty);

    // Holding gigabytes indefinitely is not something to leave to the user
    // remembering, so the pause expires into the stop they could have asked for.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(own.queue.isAbandoned(first.id), isTrue);
    expect(own.queue.isRunPaused, isFalse);

    own.engine.release();
    await own.cleanUp();
  });

  test('clearing the queue drops what is waiting and spares what is running',
      () async {
    engine.hold();
    final running = await add('running');
    await add('b');
    await add('c');
    await started(engine);

    await queue.clearQueue();

    expect(store.tracks.single.id, running.id);
    expect(queue.waitingCount, 0);

    engine.release();
    await drained(queue);

    // The running track was never interrupted, so it still produced its audio.
    expect(engine.runs.map((GenerationParams p) => p.caption),
        <String>['running']);
    expect(store.tracks.single.status, TrackStatus.done);
  });

  test('reorder moves a queued track behind the running one', () async {
    engine.hold();
    await add('running');
    await add('b');
    await add('c');
    await pump();

    expect(queue.pending.map((Track t) => t.title),
        <String>['running', 'b', 'c']);

    // Move c ahead of b — index 1 is the first movable slot.
    await queue.reorder(2, 1);
    expect(queue.pending.map((Track t) => t.title),
        <String>['running', 'c', 'b']);

    // The running track cannot be displaced.
    await queue.reorder(0, 2);
    expect(queue.pending.first.title, 'running');

    engine.release();
    await drained(queue);

    expect(engine.runs.map((GenerationParams p) => p.caption),
        <String>['running', 'c', 'b']);
  });

  test('an estimate exists from the first run, and grows with the queue',
      () async {
    engine.hold();
    await add('first');
    await pump();

    // Nothing has been measured on this machine yet. The phases' costs
    // relative to each other are a property of the model rather than the
    // hardware, so a shipped default is honest enough to show -- and the run in
    // flight corrects the absolute scale within seconds of reporting.
    expect(queue.runningEstimatedRemaining, isNotNull);
    expect(queue.estimatedWait, greaterThan(Duration.zero));

    engine.release();
    await drained(queue);

    engine.hold();
    await add('a', steps: 30);
    await pump();
    final withOne = queue.estimatedWait;

    await add('b', steps: 60);
    await pump();
    final withTwo = queue.estimatedWait;

    // b doubles the denoising steps, and denoising is most of a run.
    expect(withTwo.inMilliseconds, greaterThan(withOne.inMilliseconds));

    engine.release();
    await drained(queue);
  });

  test('pending work survives a restart and is picked up', () async {
    engine.hold();
    await add('first');
    await add('second');
    await pump();

    // Simulate a restart: a fresh store and queue over the same directory.
    engine.release();
    final reloaded = TrackStore(root: root);
    await reloaded.load();

    // The store demotes what was running; the rest is still queued.
    expect(
      reloaded.tracks.where((Track t) => t.status == TrackStatus.queued),
      hasLength(1),
    );

    final engine2 = FakeEngine();
    final queue2 = GenerationQueue(
      store: reloaded,
      engine: engine2,
      resolveModelPath: (String id) async => '/models/$id',
    );
    queue2.restore();
    await drained(queue2);

    expect(engine2.runs.map((GenerationParams p) => p.caption),
        <String>['second']);
    queue2.dispose();
  });

  test('measured rates survive a restart, so the next run is paced by them',
      () async {
    engine.hold();
    await add('first');
    await started(engine);
    // Rates are learned from what the engine reports, so a run that reported
    // nothing teaches nothing -- there is no per-phase cost to infer from a
    // single wall-clock number.
    engine.reportProgress(GenerationPhase.ar, done: 400, total: 750);
    await ticked();
    engine.release();
    await drained(queue);
    expect(store.calibrationFile.existsSync(), isTrue);

    // Simulate a restart over the same directory.
    engine.release();
    final reloaded = TrackStore(root: root);
    await reloaded.load();
    final engine2 = FakeEngine()..hold();
    final queue2 = GenerationQueue(
      store: reloaded,
      engine: engine2,
      resolveModelPath: (String id) async => '/models/$id',
    );
    queue2.restore();

    await queue2.enqueue(
      params: GenerationParams(
        caption: 'after restart',
        lyrics: '',
        durationSeconds: 30,
        inferenceSteps: 30,
      ),
      modelPackageId: 'model',
      title: 'after restart',
    );
    await pump();

    // Nothing has run in this session, but the machine's cost is known.
    expect(queue2.runningEstimatedRemaining, isNotNull);

    engine2.release();
    await drained(queue2);
    queue2.dispose();
  });

  test('the bar weights phases by cost rather than counting units', () async {
    engine.hold();
    await add('first', steps: 30);
    await started(engine);

    // Nothing reported yet: indeterminate, not zero.
    expect(queue.runningProgress, isNull);

    // The whole AR phase, which is thousands of cheap units and a fifth of the
    // run. Counting units would have this near the end already.
    engine.reportProgress(GenerationPhase.ar, done: 750, total: 750);
    await ticked();
    final afterAr = queue.runningProgress;
    expect(afterAr, isNotNull);
    expect(afterAr, lessThan(0.35));
    expect(afterAr, greaterThan(0.05));
    expect(queue.runningPhase, GenerationPhase.ar);

    // Halfway through denoising, which is most of the run.
    engine.reportProgress(GenerationPhase.flow, done: 105, total: 210);
    await ticked();
    expect(queue.runningProgress, greaterThan(afterAr!));
    expect(queue.runningProgress, greaterThan(0.4));

    engine.release();
    await drained(queue);
  });

  test('the bar never goes backwards', () async {
    engine.hold();
    await add('first', steps: 30);
    await started(engine);

    engine.reportProgress(GenerationPhase.flow, done: 200, total: 210);
    await ticked();
    final high = queue.runningProgress;
    expect(high, isNotNull);

    // A phase costing more than predicted re-weights the run. The finished
    // segments are held where they are rather than renormalised, because a bar
    // that rewinds reads as a bug; the estimate absorbs it instead.
    engine.reportProgress(GenerationPhase.flow, done: 10, total: 2100);
    await ticked();
    expect(queue.runningProgress, greaterThanOrEqualTo(high!));

    engine.release();
    await drained(queue);
  });

  test('a reading from another run is ignored', () async {
    engine.hold();
    await add('first', steps: 30);
    await started(engine);

    engine.reportProgress(GenerationPhase.ar, done: 100, total: 750, runSerial: 4);
    await ticked();
    final mine = queue.runningProgress;
    expect(mine, isNotNull);

    // The engine's serial changes when a run starts. A reading carrying a
    // different one is the tail of some other run, and rendering it would show
    // this track as nearly finished the moment it began.
    engine.reportProgress(
      GenerationPhase.vocoder,
      done: 6,
      total: 7,
      runSerial: 5,
    );
    await ticked();
    expect(queue.runningProgress, mine);
    expect(queue.runningPhase, GenerationPhase.ar);

    engine.release();
    await drained(queue);
  });

  test('rates are recorded per model package', () async {
    engine.hold();
    await add('first', steps: 30);
    await started(engine);
    engine.reportProgress(
      GenerationPhase.ar,
      done: 100,
      total: 750,
      phaseElapsed: const Duration(seconds: 50),
    );
    await ticked();
    engine.release();
    await drained(queue);

    final recorded = store.readCalibration();
    expect(recorded.keys, contains('minimax_music3_q4_0'));
    // 50s over 100 frames is 500ms each, blended halfway with the shipped
    // default -- so it must have moved well clear of the default alone.
    expect(
      recorded['minimax_music3_q4_0']!.arMsPerFrame,
      greaterThan(PhaseRates.seed.arMsPerFrame * 1.5),
    );
  });

  test('a pause is not billed to the phase it happened in', () async {
    engine.hold();
    await add('first', steps: 30);
    await started(engine);

    // 20s for 100 frames: 200ms each.
    engine.reportProgress(
      GenerationPhase.ar,
      done: 100,
      total: 750,
      phaseElapsed: const Duration(seconds: 20),
    );
    await ticked();
    final before = queue.runningEstimatedRemaining;
    expect(before, isNotNull);

    queue.setRunPaused(true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    queue.setRunPaused(false);

    // The engine's phase clock keeps running while paused, so the pause shows
    // up in phaseElapsed. Counting it would make every frame look slower than
    // it is and inflate what is left by the length of the pause.
    engine.reportProgress(
      GenerationPhase.ar,
      done: 100,
      total: 750,
      phaseElapsed: const Duration(seconds: 21, milliseconds: 200),
    );
    await ticked();

    final after = queue.runningEstimatedRemaining!;
    expect(
      (after - before!).abs(),
      lessThan(const Duration(seconds: 20)),
      reason: 'the paused stretch was charged to the phase',
    );

    engine.release();
    await drained(queue);
  });

  test('unit counts are recorded from the engine total, not the last poll',
      () async {
    engine.hold();
    await add('first', steps: 30);
    await started(engine);

    // A phase is always a poll or so short of its end when it is last seen.
    // Over two vocoder chunks that gap is the difference between the right
    // geometry and half of it, which is what predicts every later request.
    engine.reportProgress(GenerationPhase.ar, done: 246, total: 250);
    await ticked();
    engine.reportProgress(GenerationPhase.vocoder, done: 1, total: 2);
    await ticked();
    engine.release();
    await drained(queue);

    final rates = store.readCalibration()['minimax_music3_q4_0']!;
    expect(rates.sampleArFrames, 250);
    expect(rates.sampleChunks, 2);
  });

  test('delete removes a track and its audio', () async {
    final track = await add('first');
    await drained(queue);
    final file = store.audioFileFor(store.tracks.single)!;
    expect(file.existsSync(), isTrue);

    await queue.delete(track.id);

    expect(store.tracks, isEmpty);
    expect(file.existsSync(), isFalse);
  });

  test('favourite and rename persist', () async {
    final track = await add('first');
    await drained(queue);

    await queue.setFavourite(track.id, true);
    await queue.rename(track.id, '  Neon Overpass  ');

    final reloaded = TrackStore(root: root);
    await reloaded.load();
    expect(reloaded.tracks.single.favourite, isTrue);
    expect(reloaded.tracks.single.title, 'Neon Overpass');
  });
}
