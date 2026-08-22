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

  /// Ids the user gave up on. A running generation cannot actually be stopped —
  /// the C ABI has no cancellation — so the only honest thing to do is let it
  /// finish and throw the result away.
  final Set<String> _abandoned = <String>{};

  int _nextQueueOrder = 0;
  bool _draining = false;
  String? _runningId;
  DateTime? _runningStartedAt;
  Timer? _ticker;
  bool _disposed = false;

  /// Wall-clock cost of the last successful run, used for the estimate. Only
  /// the most recent is kept: it was measured on this machine, with this model
  /// resident, which is what makes it worth anything.
  Duration? _lastRunElapsed;
  int? _lastRunWorkUnits;

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
    final total = _estimateFor(running?.params);
    if (elapsed == null || total == null) {
      return null;
    }
    final remaining = total - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Estimated wait before a track enqueued now would start.
  Duration? get estimatedWait {
    var total = runningEstimatedRemaining ?? Duration.zero;
    if (runningEstimatedRemaining == null && running != null) {
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

  /// Drops a queued track, or abandons the running one.
  ///
  /// Abandoning does not stop the engine. The generation runs to completion and
  /// its output is discarded; the UI should say so rather than implying a stop.
  Future<void> cancel(String id) async {
    final track = _find(id);
    if (track == null) {
      return;
    }
    if (track.status == TrackStatus.running) {
      _abandoned.add(id);
      _notify();
      return;
    }
    if (track.status == TrackStatus.queued) {
      await store.remove(id);
      _notify();
    }
  }

  /// Whether a cancel has been requested for the running track.
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
      _runningStartedAt = null;
      _notify();
    }
  }

  Future<void> _run(Track track) async {
    _runningId = track.id;
    _runningStartedAt = DateTime.now();
    _startTicker();
    await store.upsert(track.copyWith(status: TrackStatus.running));
    _notify();

    try {
      await _ensureModelLoaded(track.modelPackageId);

      final fileName = store.audioFileNameFor(track);
      final outcome = await engine.runToFile(
        params: track.params,
        output: store.audioFileFor(track.copyWith(audioFileName: fileName))!,
      );

      final elapsed = DateTime.now().difference(_runningStartedAt!);
      _lastRunElapsed = elapsed;
      _lastRunWorkUnits = _workUnits(track.params);

      if (_abandoned.remove(track.id)) {
        // The user asked for this back when it could not be stopped. Honour it
        // now the result exists rather than surfacing a track they discarded.
        await store.remove(track.id);
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
      _runningStartedAt = null;
      _notify();
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
    final elapsed = _lastRunElapsed;
    final baseline = _lastRunWorkUnits;
    if (params == null || elapsed == null || baseline == null || baseline == 0) {
      return null;
    }
    final scale = _workUnits(params) / baseline;
    return Duration(
      milliseconds: (elapsed.inMilliseconds * scale).round(),
    );
  }

  /// Notifies unless the queue is gone.
  ///
  /// A generation cannot be stopped, so quitting mid-run leaves the drain loop
  /// awaiting a call that outlives this object; its completion must not throw.
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
