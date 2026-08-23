import 'dart:async';

import 'package:flutter/foundation.dart';

import 'generation_engine.dart';
import 'track.dart';
import 'track_store.dart';

/// Resolves an installed package id to the directory the engine loads.
///
/// Injected rather than reached for so the queue does not depend on the model
/// library, and so a track can be retried after a restart — the path is derived
/// from the id every time instead of being persisted and going stale.
typedef ModelPathResolver = Future<String?> Function(String packageId);

/// Drains queued tracks one at a time.
///
/// One at a time is not a simplification: the session holds several gigabytes
/// of weights and audio.cpp's handles are documented as not thread-safe, so
/// concurrency would mean a second resident model rather than more throughput.
/// What the queue buys is that enqueueing is instant — the form clears, the
/// track appears in the library as queued, and the user carries on writing the
/// next one while a five-minute generation runs.
final class GenerationQueue extends ChangeNotifier {
  GenerationQueue({
    required this.store,
    required this.engine,
    required this.resolveModelPath,
  });

  final TrackStore store;
  final GenerationEngine engine;
  final ModelPathResolver resolveModelPath;

  /// Ids the user gave up on.
  ///
  /// The engine can now be asked to stop, but only between units of work — and
  /// a run already past its last check finishes regardless. This is what makes
  /// that case behave the same as a stop from the outside: the result is thrown
  /// away when it lands.
  final Set<String> _abandoned = <String>{};

  int _nextQueueOrder = 0;
  bool _draining = false;
  String? _runningId;

  /// Snapshot of what is running, held here rather than read back off the store.
  ///
  /// Discarding a running track deletes it from the store immediately, but the
  /// engine keeps working — so this is what still knows the shape of the work
  /// in flight and keeps the estimate honest after the track itself is gone.
  Track? _runningTrack;
  DateTime? _runningStartedAt;
  Timer? _ticker;
  bool _disposed = false;

  /// Wall-clock cost of the last successful run, used for the estimate. Only
  /// the most recent is kept: it was measured on this machine, with this model
  /// resident, which is what makes it worth anything.
  ///
  /// Persisted through the store, so the first generation after a restart gets
  /// an estimate too — the measurement is a property of the machine, and a run
  /// costs minutes, which is exactly when a number is worth having.
  TimingSample? _lastRun;

  /// Every track, newest first, exactly as the library shows them.
  List<Track> get tracks => store.tracks;

  /// Pending tracks in the order they will run.
  List<Track> get pending {
    final list = store.tracks.where((Track t) => t.isPending).toList()
      ..sort((Track a, Track b) =>
          (a.queueOrder ?? 0).compareTo(b.queueOrder ?? 0));
    return List<Track>.unmodifiable(list);
  }

  /// The track generating right now, if any.
  Track? get running {
    final id = _runningId;
    if (id == null) {
      return null;
    }
    for (final track in store.tracks) {
      if (track.id == id) {
        return track;
      }
    }
    return null;
  }

  bool get isBusy => _draining;

  /// True while the engine is finishing work the user has already discarded.
  ///
  /// The track is gone from the library the moment it is discarded, but the
  /// machine is not free: nothing can interrupt a generation, so the next one
  /// cannot start until this finishes. The UI shows this rather than looking
  /// idle for the minutes that remain.
  bool get isFinishingDiscarded => _runningTrack != null && running == null;

  /// Number of tracks waiting behind the one running.
  int get waitingCount =>
      pending.where((Track t) => t.status == TrackStatus.queued).length;

  /// How long the current generation has been running.
  Duration? get runningElapsed {
    final startedAt = _runningStartedAt;
    return startedAt == null ? null : DateTime.now().difference(startedAt);
  }

  /// Rough time left on the current generation.
  ///
  /// There is no progress callback in the ABI, so this is an extrapolation from
  /// the previous run scaled by steps × seconds, not a measurement. It is
  /// deliberately absent until one run has completed rather than guessed.
  Duration? get runningEstimatedRemaining {
    final elapsed = runningElapsed;
    final total = _estimateFor(_runningTrack?.params);
    if (elapsed == null || total == null) {
      return null;
    }
    final remaining = total - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Estimated wait before a track enqueued now would start.
  Duration? get estimatedWait {
    var total = runningEstimatedRemaining ?? Duration.zero;
    // Discarded work still occupies the engine, so it still counts towards the
    // wait — hence the snapshot rather than what the store can still see.
    if (runningEstimatedRemaining == null && _runningTrack != null) {
      return null;
    }
    for (final track in pending) {
      if (track.status == TrackStatus.queued) {
        final each = _estimateFor(track.params);
        if (each == null) {
          return null;
        }
        total += each;
      }
    }
    return total;
  }

  /// Restores queue state from disk. Call once, after [TrackStore.load].
  ///
  /// Anything still marked pending is left pending and will be picked up: the
  /// store has already demoted whatever was mid-flight when the app died, so
  /// what survives here is genuinely work the user asked for and never got.
  void restore() {
    _lastRun = store.readCalibration();
    _nextQueueOrder = store.tracks
            .map((Track t) => t.queueOrder ?? 0)
            .fold<int>(0, (int a, int b) => a > b ? a : b) +
        1;
    if (pending.isNotEmpty) {
      unawaited(_drain());
    }
  }

  /// Adds a track to the back of the queue and starts draining.
  ///
  /// Returns immediately with the queued track; generation happens later.
  Future<Track> enqueue({
    required GenerationParams params,
    required String modelPackageId,
    required String title,
  }) async {
    final now = DateTime.now();
    final track = Track(
      id: '${now.millisecondsSinceEpoch}-${_nextQueueOrder.toRadixString(36)}',
      title: title,
      params: params,
      modelPackageId: modelPackageId,
      createdAt: now,
      queueOrder: _nextQueueOrder++,
    );
    await store.upsert(track);
    _notify();
    unawaited(_drain());
    return track;
  }

  /// Puts a failed track back at the end of the queue.
  Future<void> retry(String id) async {
    final track = _find(id);
    if (track == null || track.isPending) {
      return;
    }
    _abandoned.remove(id);
    await store.upsert(
      track.copyWith(
        status: TrackStatus.queued,
        queueOrder: _nextQueueOrder++,
        clearError: true,
      ),
    );
    _notify();
    unawaited(_drain());
  }

  /// Drops a queued track, or discards the running one.
  ///
  /// Discarding does not stop the engine — nothing can. What it does do is take
  /// the track out of the library at once, so "discard" means the same thing to
  /// the user whether or not the work has started. The engine keeps going and
  /// the result is thrown away when it lands; [isFinishingDiscarded] is how the
  /// UI says the machine is still busy without pretending the track survived.
  Future<void> cancel(String id) async {
    final track = _find(id);
    if (track == null) {
      return;
    }
    if (track.status == TrackStatus.running) {
      _abandoned.add(id);
      // Asks the engine to stop. It is honoured between units of work, so the
      // run still takes a moment to unwind -- and may not be honoured at all if
      // it is already past its last check. _abandoned stays the backstop for
      // exactly that case.
      engine.requestCancel();
    }
    await store.remove(id);
    _notify();
  }

  /// Drops everything still waiting, leaving any running track alone.
  ///
  /// The counterpart to discarding the running one: together they are a full
  /// stop, and on their own this is "finish what you started, then stop".
  Future<void> clearQueue() async {
    final keep = store.tracks
        .where((Track t) => t.status != TrackStatus.queued)
        .toList(growable: false);
    if (keep.length == store.tracks.length) {
      return;
    }
    // One write rather than one per track: nothing queued has audio to delete,
    // which is the only thing `remove` would add here.
    await store.replaceAll(keep);
    _notify();
  }

  /// Whether a discard has been requested for the running track.
  bool isAbandoned(String id) => _abandoned.contains(id);

  /// Moves a queued track within the queue.
  ///
  /// Indices are into [pending]. The running track cannot be moved and anything
  /// targeting position 0 while one is running lands directly behind it.
  Future<void> reorder(int oldIndex, int newIndex) async {
    final list = pending.toList();
    if (oldIndex < 0 || oldIndex >= list.length) {
      return;
    }
    if (list[oldIndex].status == TrackStatus.running) {
      return;
    }
    final runningOffset = list.isNotEmpty && list.first.status == TrackStatus.running ? 1 : 0;
    var target = newIndex.clamp(runningOffset, list.length - 1);
    if (oldIndex < target) {
      target -= 1;
      target = target.clamp(runningOffset, list.length - 1);
    }

    final moved = list.removeAt(oldIndex);
    list.insert(target, moved);

    // Renumber from scratch: gaps would accumulate over enough drags, and the
    // absolute values mean nothing beyond their order.
    final updated = <String, Track>{};
    for (var i = 0; i < list.length; i++) {
      updated[list[i].id] = list[i].copyWith(queueOrder: i);
    }
    _nextQueueOrder = list.length;

    await store.replaceAll(<Track>[
      for (final track in store.tracks) updated[track.id] ?? track,
    ]);
    _notify();
  }

  Future<void> setFavourite(String id, bool value) async {
    final track = _find(id);
    if (track != null) {
      await store.upsert(track.copyWith(favourite: value));
      _notify();
    }
  }

  Future<void> rename(String id, String title) async {
    final track = _find(id);
    if (track != null && title.trim().isNotEmpty) {
      await store.upsert(track.copyWith(title: title.trim()));
      _notify();
    }
  }

  /// Deletes a track and its audio. Abandons it first if it is running.
  Future<void> delete(String id) async {
    if (_runningId == id) {
      _abandoned.add(id);
    }
    await store.remove(id);
    _notify();
  }

  /// Runs pending tracks until none are left.
  ///
  /// Re-entrant by design: every mutation calls it, and all but the first
  /// return straight away.
  Future<void> _drain() async {
    if (_draining) {
      return;
    }
    _draining = true;
    _notify();
    try {
      while (true) {
        final next = pending
            .where((Track t) => t.status == TrackStatus.queued)
            .firstOrNull;
        if (next == null) {
          break;
        }
        await _run(next);
      }
    } finally {
      _draining = false;
      _stopTicker();
      _runningId = null;
      _runningTrack = null;
      _runningStartedAt = null;
      _notify();
    }
  }

  Future<void> _run(Track track) async {
    _runningId = track.id;
    _runningTrack = track;
    _runningStartedAt = DateTime.now();
    _startTicker();
    await store.upsert(track.copyWith(status: TrackStatus.running));
    _notify();

    try {
      await _ensureModelLoaded(track.modelPackageId);

      // A discard during the model load is aimed at this run, but the engine
      // clears its own flag when a run starts -- deliberately, so a stale
      // cancel cannot stop the next track. Asking here is what stops the two
      // from cancelling each other out and leaving the user watching a run
      // they stopped minutes ago. Loading is the longest uninterruptible
      // stretch in the app, so this window is not a narrow one.
      if (_abandoned.contains(track.id)) {
        throw const GenerationCancelled();
      }

      final fileName = store.audioFileNameFor(track);
      final outcome = await engine.runToFile(
        params: track.params,
        output: store.audioFileFor(track.copyWith(audioFileName: fileName))!,
      );

      // Recorded even when abandoned below: the work still happened, and the
      // next estimate is better for knowing what it cost.
      _lastRun = TimingSample(
        elapsed: DateTime.now().difference(_runningStartedAt!),
        workUnits: _workUnits(track.params),
      );
      await store.writeCalibration(_lastRun!);

      if (_abandoned.remove(track.id)) {
        // Already gone from the store — discarding removes the track up front.
        // What is left is the audio the run just wrote, which nothing points at
        // now, so delete it here rather than leaving gigabytes for the next
        // startup's orphan sweep to find.
        await store.remove(track.id);
        await _deleteOutput(track);
      } else {
        await store.upsert(
          _find(track.id)!.copyWith(
            status: TrackStatus.done,
            audioFileName: fileName,
            duration: outcome.duration,
            peaks: outcome.peaks,
            completedAt: DateTime.now(),
            clearQueueOrder: true,
            clearError: true,
          ),
        );
      }
    } on GenerationCancelled {
      // The stop landed. The track is already gone from the store -- discarding
      // removes it up front -- so there is nothing to mark, and nothing to say:
      // this is the outcome the user asked for.
      _abandoned.remove(track.id);
      await store.remove(track.id);
      _deleteOutput(track);
    } on Object catch (error) {
      _abandoned.remove(track.id);
      final current = _find(track.id);
      if (current != null) {
        await store.upsert(
          current.copyWith(
            status: TrackStatus.failed,
            errorMessage: '$error',
            clearQueueOrder: true,
          ),
        );
      }
    } finally {
      _stopTicker();
      _runningId = null;
      _runningTrack = null;
      _runningStartedAt = null;
      _notify();
    }
  }

  /// Deletes the audio a discarded run produced, if it got that far.
  ///
  /// The track is out of the index by this point, so nothing points at the
  /// file and the next startup's orphan sweep is the only other thing that
  /// would ever find it -- too late to matter on something this large.
  Future<void> _deleteOutput(Track track) async {
    final file = store.audioFileFor(
      track.copyWith(audioFileName: store.audioFileNameFor(track)),
    );
    if (file != null && file.existsSync()) {
      await file.delete();
    }
  }

  /// Loads the package this track needs, unless it is already resident.
  Future<void> _ensureModelLoaded(String packageId) async {
    final path = await resolveModelPath(packageId);
    if (path == null || path.isEmpty) {
      throw StateError(
        'Model package "$packageId" is not installed. Install it from Models '
        'and retry this track.',
      );
    }
    if (engine.loadedModelPath == path) {
      return;
    }
    await engine.loadModel(path);
    if (engine.loadedModelPath != path) {
      throw StateError(engine.errorMessage ?? 'Could not load $packageId.');
    }
  }

  /// Cost proxy for the estimate: steps × seconds tracks runtime far better
  /// than either alone, since both scale the flow stage roughly linearly.
  int _workUnits(GenerationParams params) =>
      params.inferenceSteps * params.durationSeconds;

  Duration? _estimateFor(GenerationParams? params) {
    final sample = _lastRun;
    if (params == null || sample == null || sample.workUnits == 0) {
      return null;
    }
    final scale = _workUnits(params) / sample.workUnits;
    return Duration(
      milliseconds: (sample.elapsed.inMilliseconds * scale).round(),
    );
  }

  /// Notifies unless the queue is gone.
  ///
  /// A generation is not stopped instantly, so quitting mid-run can leave the
  /// drain loop awaiting a call that outlives this object; its completion must
  /// not throw.
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Track? _find(String id) {
    for (final track in store.tracks) {
      if (track.id == id) {
        return track;
      }
    }
    return null;
  }

  /// Drives the elapsed readout while a generation runs. There is nothing else
  /// to notify on: the engine call is one opaque await lasting minutes.
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (Timer _) => notifyListeners(),
    );
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTicker();
    super.dispose();
  }
}
