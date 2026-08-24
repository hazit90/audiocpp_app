import 'dart:async';
import 'dart:math' as math;

import 'package:audiocpp/audiocpp.dart';
import 'package:flutter/foundation.dart';

import 'generation_engine.dart';
import 'phase_rates.dart';
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
    this.stopGrace = const Duration(milliseconds: 400),
    this.pauseLimit = const Duration(minutes: 10),
  });

  final TrackStore store;
  final GenerationEngine engine;
  final ModelPathResolver resolveModelPath;

  /// How long a stop is given to land before [isStopping] admits to it.
  ///
  /// Injectable so a test can assert both sides of it outright, rather than
  /// racing a wall clock that a loaded machine will lose.
  final Duration stopGrace;

  /// How long a run may stay paused before it is stopped instead.
  ///
  /// A pause holds the whole model in memory, so an indefinite one is an
  /// indefinite hold on several gigabytes with nothing on screen to prompt the
  /// user. Injectable for the same reason as [stopGrace].
  final Duration pauseLimit;

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

  /// When a stop was last asked for, so [isStopping] can stay quiet while the
  /// engine is still likely to be unwinding.
  DateTime? _stopRequestedAt;

  /// When the current pause began, if the run is paused.
  DateTime? _pausedAt;

  /// Paused time already accumulated in this run.
  ///
  /// Held apart from the start time because it has to come out of two separate
  /// numbers: what the UI shows as elapsed, and the sample the next estimate is
  /// extrapolated from. Leaving it in the latter would teach the queue that a
  /// run costs however long the user left it paused.
  Duration _pausedTotal = Duration.zero;

  /// Converts a forgotten pause into a stop; see [pauseLimit].
  Timer? _pauseDeadline;
  Timer? _ticker;
  bool _disposed = false;

  /// Per-phase costs, by model package, as last measured on this machine.
  ///
  /// Persisted through the store, so the first generation after a restart is
  /// paced as well as the last one was. A package with no entry falls back to
  /// [PhaseRates.seed] rather than to nothing: the ratios between phases belong
  /// to the model, and the absolute scale is corrected from the run in flight
  /// within seconds of it starting.
  Map<String, PhaseRates> _rates = const <String, PhaseRates>{};

  /// Last reading from the engine that belongs to the run in flight.
  ProgressSnapshot? _progress;

  /// The engine's serial for this run, adopted from the first reading.
  ///
  /// Polling is asynchronous to starting and finishing a run, so without this
  /// the tail of the previous run gets rendered as the opening of this one.
  int? _runSerial;

  /// Unit totals the engine has reported for this run, which beat prediction.
  final Map<GenerationPhase, int> _liveTotals = <GenerationPhase, int>{};

  /// What each finished phase of this run actually cost.
  ///
  /// [units] and [elapsed] are a consistent pair taken from one reading, which
  /// is what a rate needs. [total] is the engine's own count for the phase and
  /// is what its geometry needs -- the last reading is always a unit or so
  /// short of the end, which barely matters over thousands of AR frames and
  /// badly matters over two vocoder chunks.
  final Map<GenerationPhase, ({int units, int total, Duration elapsed})>
      _observed = <GenerationPhase, ({int units, int total, Duration elapsed})>{};

  /// Paused time already banked when the current phase began, so a pause is
  /// not billed to the phase it happened in.
  Duration _pausedAtPhaseStart = Duration.zero;

  /// The bar's position, which only ever moves forward. See [runningProgress].
  double _shownProgress = 0;

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

  /// True while a stop has been asked for and the run has not ended yet.
  ///
  /// Deliberately false for the first [stopGrace]. A stop usually lands in
  /// about a tenth of a second, and a strip that appears and vanishes inside
  /// two hundred milliseconds reads as a glitch rather than as information.
  /// What this is for is the case that is genuinely slow -- a run already past
  /// its last check, which finishes on its own -- where saying nothing would
  /// leave the pane looking idle while the machine is still busy.
  bool get isStopping {
    final askedAt = _stopRequestedAt;
    if (_runningTrack == null || running != null || askedAt == null) {
      return false;
    }
    return DateTime.now().difference(askedAt) >= stopGrace;
  }



  /// Number of tracks waiting behind the one running.
  int get waitingCount =>
      pending.where((Track t) => t.status == TrackStatus.queued).length;

  /// Whether the generation in flight is suspended.
  bool get isRunPaused => _pausedAt != null;

  /// How long the current generation has spent generating.
  ///
  /// Excludes time spent paused: that is time the machine was idle, and
  /// counting it would make the readout a stopwatch rather than a measure of
  /// the work done.
  Duration? get runningElapsed {
    final startedAt = _runningStartedAt;
    if (startedAt == null) {
      return null;
    }
    return DateTime.now().difference(startedAt) - _pausedSoFar();
  }

  /// Paused time in this run, including a pause still in progress.
  Duration _pausedSoFar() {
    final since = _pausedAt;
    return since == null
        ? _pausedTotal
        : _pausedTotal + DateTime.now().difference(since);
  }

  /// How far through the current generation the engine says it is, 0..1.
  ///
  /// Null when nothing is running, or when the engine is not reporting — an
  /// older library or a family without report points — which the UI shows as an
  /// indeterminate bar rather than as a run stuck at zero.
  ///
  /// Monotone. When a phase turns out to cost more than predicted the finished
  /// segments are not renormalised, because a bar that goes backwards reads as
  /// a bug; the error lands in [runningEstimatedRemaining] instead, which is
  /// free to move in both directions.
  double? get runningProgress {
    if (_runningTrack == null || _progress == null) {
      return null;
    }
    return _shownProgress;
  }

  /// Which stage the run is in, or null when nothing is being reported.
  GenerationPhase? get runningPhase {
    final snapshot = _progress;
    if (_runningTrack == null || snapshot == null) {
      return null;
    }
    return snapshot.phase;
  }

  /// Time left on the current generation.
  ///
  /// Measured, not extrapolated from a past run: the phase in flight is timed
  /// against its own units, and the phases after it are scaled by how far off
  /// the stored rate this machine is turning out to be right now.
  ///
  /// Falls back to the pre-run prediction until a phase has enough units behind
  /// it to time, which is a few seconds rather than a whole first run.
  Duration? get runningEstimatedRemaining {
    final params = _runningTrack?.params;
    if (params == null) {
      return null;
    }
    final rates = _ratesForRunning();
    final snapshot = _progress;
    if (snapshot == null || !snapshot.isReporting) {
      final elapsed = runningElapsed;
      final total = rates.predictedTotal(params);
      if (elapsed == null) {
        return null;
      }
      final remaining = total - elapsed;
      return remaining.isNegative ? Duration.zero : remaining;
    }

    final phase = snapshot.phase;
    if (phase == GenerationPhase.finalizing) {
      return Duration.zero;
    }

    final live = _liveRate(snapshot);
    final stored = rates.rateFor(phase);
    // How far off this machine is running right now, carried to the phases that
    // have not started. They share a CPU and a thermal budget with this one, so
    // whatever is slowing it down is the best guess for them too. Clamped
    // because one anomalous phase should not produce an absurd total.
    final drift = live != null && stored > 0
        ? (live / stored).clamp(0.2, 5.0)
        : 1.0;
    final rate = live ?? stored;

    var milliseconds =
        math.max(0, snapshot.total - snapshot.done).toDouble() * rate;
    var reached = false;
    for (final later in PhaseRates.order) {
      if (later == phase) {
        reached = true;
        continue;
      }
      if (!reached) {
        continue;
      }
      milliseconds +=
          _unitsFor(later, params, rates) * rates.rateFor(later) * drift;
    }
    return Duration(milliseconds: milliseconds.round());
  }

  /// Estimated wait before a track enqueued now would start.
  ///
  /// Never null while anything is queued: every package has rates, measured or
  /// shipped. A run being stopped still occupies the engine, so it still counts
  /// towards the wait — hence the snapshot rather than what the store can still
  /// see.
  Duration get estimatedWait {
    var total = runningEstimatedRemaining ?? Duration.zero;
    for (final track in pending) {
      if (track.status == TrackStatus.queued) {
        total += estimateFor(track.params, track.modelPackageId);
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
    _rates = store.readCalibration();
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
  /// the result is thrown away if it lands anyway; [isStopping] is how the UI
  /// says the machine is still busy without pretending the track survived.
  Future<void> cancel(String id) async {
    final track = _find(id);
    if (track == null) {
      return;
    }
    if (track.status == TrackStatus.running) {
      _abandoned.add(id);
      _stopRequestedAt = DateTime.now();
      // Cancelling wakes a paused run in the engine, so the bookkeeping here
      // has to follow or the elapsed readout keeps subtracting a pause that
      // has already ended.
      if (_pausedAt != null) {
        _pausedTotal += DateTime.now().difference(_pausedAt!);
        _pausedAt = null;
        _startTicker();
      }
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

  /// Suspends or resumes the generation in flight.
  ///
  /// Distinct from cancelling: the run keeps its place and its memory, so
  /// resuming produces the track that would have been produced anyway. Nothing
  /// happens if there is no run.
  void setRunPaused(bool value) {
    if (_runningTrack == null || value == isRunPaused) {
      return;
    }
    if (value) {
      _pausedAt = DateTime.now();
      engine.requestPause();
      _stopTicker();
      // A pause holds the model resident -- gigabytes, for this family -- and
      // unlike a run it has no natural end. Left alone it would sit there until
      // the app closed, with that memory quietly spoken for, so it converts
      // itself into the stop the user could have asked for.
      _pauseDeadline = Timer(pauseLimit, () {
        final running = _runningTrack;
        if (isRunPaused && running != null) {
          unawaited(cancel(running.id));
        }
      });
    } else {
      _pausedTotal += DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
      engine.requestResume();
      _startTicker();
      _pauseDeadline?.cancel();
      _pauseDeadline = null;
    }
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
      _stopRequestedAt = null;
      _notify();
    }
  }

  Future<void> _run(Track track) async {
    _runningId = track.id;
    _runningTrack = track;
    _runningStartedAt = DateTime.now();
    _pausedAt = null;
    _pausedTotal = Duration.zero;
    _pausedAtPhaseStart = Duration.zero;
    _progress = null;
    _runSerial = null;
    _shownProgress = 0;
    _liveTotals.clear();
    _observed.clear();
    _startTicker();
    await store.upsert(track.copyWith(status: TrackStatus.running));
    _notify();

    try {
      await _ensureModelLoaded(track.modelPackageId, track.params.family);

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
      //
      // The last phase never sees a transition to close it out, so it is banked
      // here from its final reading.
      final last = _progress;
      if (last != null && last.isReporting && last.done > 0) {
        _observed[last.phase] = (
          units: last.done,
          total: last.total,
          elapsed: last.phaseElapsed - (_pausedSoFar() - _pausedAtPhaseStart),
        );
      }
      if (_observed.isNotEmpty) {
        final updated = _ratesFor(track.modelPackageId).blendedWith(
          _observed,
          durationSeconds: track.params.durationSeconds,
        );
        _rates = <String, PhaseRates>{
          ..._rates,
          track.modelPackageId: updated,
        };
        await store.writeCalibration(track.modelPackageId, updated);
      }

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
      // Whatever ended the run also ends its pause: leaving the deadline armed
      // would stop a later, unrelated track.
      _pauseDeadline?.cancel();
      _pauseDeadline = null;
      _pausedAt = null;
      _runningId = null;
      _runningTrack = null;
      _runningStartedAt = null;
      _stopRequestedAt = null;
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
  Future<void> _ensureModelLoaded(String packageId, String family) async {
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
    await engine.loadModel(path, family: family);
    if (engine.loadedModelPath != path) {
      throw StateError(engine.errorMessage ?? 'Could not load $packageId.');
    }
  }

  /// Rates for a package, falling back to the shipped defaults.
  PhaseRates _ratesFor(String packageId) =>
      _rates[packageId] ?? PhaseRates.seed;

  PhaseRates _ratesForRunning() {
    final track = _runningTrack;
    return track == null ? PhaseRates.seed : _ratesFor(track.modelPackageId);
  }

  /// Units in a phase: what the engine reported if it has started, and the
  /// prediction otherwise.
  int _unitsFor(
    GenerationPhase phase,
    GenerationParams params,
    PhaseRates rates,
  ) =>
      _liveTotals[phase] ?? rates.predictedUnits(phase, params);

  /// Cost per unit of the phase in flight, from this run alone.
  ///
  /// Null until a couple of units are done: the first is measured from a phase
  /// boundary the poll only approximates, and dividing by one of anything is
  /// not a rate.
  double? _liveRate(ProgressSnapshot snapshot) {
    if (snapshot.done < 2) {
      return null;
    }
    final paused = _pausedSoFar() - _pausedAtPhaseStart;
    final elapsed = snapshot.phaseElapsed - paused;
    if (elapsed <= Duration.zero) {
      return null;
    }
    return elapsed.inMilliseconds / snapshot.done;
  }

  /// What [params] would cost on [packageId], from the same measured rates the
  /// running bar uses.
  ///
  /// Public because a setting is worth pricing before it is committed to: the
  /// Create pane reads this while a slider moves. Short of the truth by the
  /// weight upload, which reports no phase and so cannot be predicted -- show
  /// it as an approximation, never as a countdown.
  Duration estimateFor(GenerationParams params, String packageId) =>
      _ratesFor(packageId).predictedTotal(params);

  /// Reads the engine's position and folds it into the bar and the estimate.
  ///
  /// Runs on the ticker rather than on a callback: the isolate that started the
  /// run is blocked inside it, so anything pushed to its port would not be
  /// delivered until the run it described had finished. See
  /// [GenerationEngine.progress].
  void _pollProgress() {
    final track = _runningTrack;
    if (track == null) {
      return;
    }
    final snapshot = engine.progress;
    if (snapshot == null || !snapshot.isReporting) {
      return;
    }
    // The first reading of a run names it; everything after has to agree, or it
    // belongs to a run this queue is not showing.
    _runSerial ??= snapshot.runSerial;
    if (snapshot.runSerial != _runSerial) {
      return;
    }

    final previous = _progress;
    if (previous != null && previous.phase != snapshot.phase) {
      // Bank what the phase just finished actually cost. Its last reading is
      // the closest thing to a measurement of it -- up to one poll short of the
      // truth, against a phase that ran for minutes.
      _observed[previous.phase] = (
        units: previous.done,
        total: previous.total,
        elapsed: previous.phaseElapsed - (_pausedSoFar() - _pausedAtPhaseStart),
      );
      _pausedAtPhaseStart = _pausedSoFar();
    }
    _liveTotals[snapshot.phase] = snapshot.total;
    _progress = snapshot;
    _recomputeProgress(track.params);
  }

  /// Weights each phase by what it is predicted to cost and sums the finished
  /// ones, so the bar advances in wall time rather than in units.
  ///
  /// Counting units directly would sprint through AR — thousands of cheap
  /// frames — and then sit still through flow, which is three quarters of the
  /// run in a fraction of the units.
  void _recomputeProgress(GenerationParams params) {
    final snapshot = _progress;
    if (snapshot == null) {
      return;
    }
    if (snapshot.phase == GenerationPhase.finalizing) {
      _shownProgress = 1;
      return;
    }

    final rates = _ratesForRunning();
    var total = 0.0;
    var done = 0.0;
    var reached = false;
    for (final phase in PhaseRates.order) {
      final cost = _unitsFor(phase, params, rates) * rates.rateFor(phase);
      total += cost;
      if (phase == snapshot.phase) {
        reached = true;
        done += cost * (snapshot.phaseFraction ?? 0);
      } else if (!reached) {
        done += cost;
      }
    }
    if (total <= 0) {
      return;
    }
    // Only ever forward: see [runningProgress].
    _shownProgress = math.max(_shownProgress, (done / total).clamp(0.0, 1.0));
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

  /// Drives the elapsed readout and reads the engine's position while a
  /// generation runs. The run itself is one await lasting minutes, so this is
  /// the only thing that moves in the meantime.
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (Timer _) {
      _pollProgress();
      notifyListeners();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTicker();
    _pauseDeadline?.cancel();
    // Quitting is a discard of everything in flight, so treat it as one. The
    // run holds the worker isolate and every teardown command queued behind it,
    // which is what made closing the app mid-generation hang; and the result
    // has nowhere to go now regardless.
    if (_runningTrack != null) {
      // requestCancel wakes a paused run too, which matters here more than
      // anywhere: a paused run reaches no further checkpoint on its own, so
      // without this the teardown behind it would wait forever rather than
      // merely a long time.
      engine.requestCancel();
    }
    super.dispose();
  }
}
