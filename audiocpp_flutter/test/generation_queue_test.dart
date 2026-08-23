import 'dart:io';

import 'package:audiocpp_flutter/src/tracks/generation_queue.dart';
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

/// Waits until the queue has nothing left to run. Bounded so a bug stalls one
/// test rather than the suite.
Future<void> drained(GenerationQueue queue) async {
  for (var i = 0; i < 500 && (queue.isBusy || queue.pending.isNotEmpty); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  await pump();
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

  test('cancelling the running track discards its result when it lands',
      () async {
    engine.hold();
    final first = await add('first');
    await pump();

    await queue.cancel(first.id);
    // Nothing can stop the engine, so the track is still running and the run
    // still happens — the result is what gets thrown away.
    expect(queue.isAbandoned(first.id), isTrue);
    expect(store.tracks.single.status, TrackStatus.running);

    engine.release();
    await drained(queue);

    expect(engine.runs, hasLength(1));
    expect(store.tracks, isEmpty);
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

  test('no estimate until a run has completed, then it grows with the queue',
      () async {
    engine.hold();
    await add('first');
    await pump();

    // Nothing has been measured yet, so there is nothing honest to show.
    expect(queue.runningEstimatedRemaining, isNull);
    expect(queue.estimatedWait, isNull);

    engine.release();
    await drained(queue);

    engine.hold();
    await add('a', steps: 30);
    await pump();
    final withOne = queue.estimatedWait;

    await add('b', steps: 60);
    await pump();
    final withTwo = queue.estimatedWait;

    expect(withOne, isNotNull);
    expect(withTwo, isNotNull);
    // b is twice the work of a, so it must add more than nothing to the wait.
    expect(withTwo!.inMilliseconds, greaterThan(withOne!.inMilliseconds));

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

  test('the timing sample survives a restart, so the first run is estimated',
      () async {
    await add('first');
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
