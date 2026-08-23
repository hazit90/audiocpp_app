import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'phase_rates.dart';
import 'track.dart';

/// Persists generated tracks: one JSON index plus the WAV files beside it.
///
/// JSON rather than a database because the whole point of the index is that a
/// few hundred rows fit in memory and stay inspectable with a text editor;
/// nothing here queries, it only sorts by time.
///
/// The store is a repository, not a controller: it has no listeners and does no
/// generation. Ordering, the queue and the UI live above it.
final class TrackStore {
  TrackStore({required this.root});

  /// Resolves the default root, `<Application Support>/tracks`.
  ///
  /// Application Support, not the system temp directory, is what makes a track
  /// outlive the session that made it — a generation costs minutes, so losing
  /// one to a restart is not acceptable.
  static Future<TrackStore> resolveDefault({String? overridePath}) async {
    if (overridePath != null && overridePath.isNotEmpty) {
      return TrackStore(root: Directory(overridePath));
    }
    final support = await getApplicationSupportDirectory();
    return TrackStore(root: Directory(p.join(support.path, 'tracks')));
  }

  static const int schemaVersion = 1;

  /// Schema of [calibrationFile], versioned separately from the index: the two
  /// files are read independently and a change to one must not invalidate the
  /// other.
  ///
  /// 2 replaced a single whole-run sample with per-phase rates. An older file
  /// is discarded rather than migrated -- it holds one number for a run whose
  /// phases are now known to cost unrelated amounts, so there is nothing in it
  /// worth carrying forward.
  static const int calibrationSchemaVersion = 2;

  /// Directory holding [indexFile] and [audioDirectory].
  final Directory root;

  File get indexFile => File(p.join(root.path, 'index.json'));

  Directory get audioDirectory => Directory(p.join(root.path, 'audio'));

  /// Holds the per-phase rates the queue predicts and paces a run from.
  ///
  /// Separate from the index rather than a field on it: it is a measurement of
  /// this machine, not part of the library, and a corrupt or missing one costs
  /// nothing but the accuracy of an estimate that has a usable default anyway.
  File get calibrationFile => File(p.join(root.path, 'timing.json'));

  /// Tracks in memory, newest first. Empty until [load].
  List<Track> get tracks => List<Track>.unmodifiable(_tracks);
  List<Track> _tracks = <Track>[];

  Future<void> ensureExists() async {
    await audioDirectory.create(recursive: true);
  }

  /// Absolute path the WAV for [track] should live at.
  File? audioFileFor(Track track) {
    final name = track.audioFileName;
    return name == null ? null : File(p.join(audioDirectory.path, name));
  }

  /// File name to hand a generation about to write its output.
  String audioFileNameFor(Track track) => '${track.id}.wav';

  /// Reads the index off disk.
  ///
  /// A track whose WAV has gone missing is demoted to [TrackStatus.failed]
  /// rather than dropped: the parameters are still worth keeping, and a row the
  /// user can retry beats a track that silently disappeared. A track left
  /// [TrackStatus.running] by a crash is demoted the same way — nothing is
  /// generating at load time by definition.
  Future<void> load() async {
    await ensureExists();
    _tracks = _sorted(await _readIndex());

    var repaired = false;
    _tracks = _tracks.map((Track track) {
      if (track.status == TrackStatus.running) {
        repaired = true;
        return track.copyWith(
          status: TrackStatus.failed,
          errorMessage: 'Interrupted — the app closed while this was generating.',
        );
      }
      if (track.status == TrackStatus.done) {
        final file = audioFileFor(track);
        if (file == null || !file.existsSync()) {
          repaired = true;
          return track.copyWith(
            status: TrackStatus.failed,
            errorMessage: 'Audio file is missing.',
          );
        }
      }
      return track;
    }).toList();

    if (repaired) {
      await _write();
    }
  }

  /// Inserts [track], or replaces the existing entry with the same id.
  Future<void> upsert(Track track) async {
    final index = _tracks.indexWhere((Track t) => t.id == track.id);
    if (index == -1) {
      _tracks = _sorted(<Track>[..._tracks, track]);
    } else {
      _tracks = <Track>[..._tracks]..[index] = track;
    }
    await _write();
  }

  /// Replaces the whole list, preserving the caller's order.
  ///
  /// Used by the queue, whose order is deliberate and not by creation time.
  Future<void> replaceAll(List<Track> tracks) async {
    _tracks = List<Track>.of(tracks);
    await _write();
  }

  /// Removes [id] and deletes its audio.
  Future<void> remove(String id) async {
    final index = _tracks.indexWhere((Track t) => t.id == id);
    if (index == -1) {
      return;
    }
    final file = audioFileFor(_tracks[index]);
    _tracks = <Track>[..._tracks]..removeAt(index);
    await _write();
    // After the index is written: an orphaned file wastes space, whereas an
    // index entry pointing at a deleted file is a broken row in the library.
    if (file != null && file.existsSync()) {
      await file.delete();
    }
  }

  /// Deletes audio files with no index entry.
  ///
  /// Generation writes the WAV before the index entry is finalised, so a crash
  /// in that window leaves a file nothing references.
  Future<int> pruneOrphanedAudio() async {
    if (!audioDirectory.existsSync()) {
      return 0;
    }
    final known = _tracks
        .map((Track track) => track.audioFileName)
        .whereType<String>()
        .toSet();
    var removed = 0;
    await for (final entity in audioDirectory.list()) {
      if (entity is! File || !entity.path.endsWith('.wav')) {
        continue;
      }
      if (!known.contains(p.basename(entity.path))) {
        await entity.delete();
        removed++;
      }
    }
    return removed;
  }

  /// Reads the recorded rates per model package, empty if there are none to
  /// trust.
  ///
  /// Synchronous because the queue restores in one turn, before the first
  /// frame; the file is a handful of numbers.
  Map<String, PhaseRates> readCalibration() {
    try {
      if (!calibrationFile.existsSync()) {
        return const <String, PhaseRates>{};
      }
      final decoded = jsonDecode(calibrationFile.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        return const <String, PhaseRates>{};
      }
      if (decoded['schema_version'] != calibrationSchemaVersion) {
        return const <String, PhaseRates>{};
      }
      final packages = decoded['packages'];
      if (packages is! Map<String, Object?>) {
        return const <String, PhaseRates>{};
      }
      final out = <String, PhaseRates>{};
      for (final entry in packages.entries) {
        final value = entry.value;
        if (value is Map<String, Object?>) {
          out[entry.key] = PhaseRates.fromJson(value);
        }
      }
      return out;
    } on Object {
      // Unreadable rates just mean the built-in defaults until the next run.
      return const <String, PhaseRates>{};
    }
  }

  /// Records the rates measured for one model package, leaving the others as
  /// they were.
  ///
  /// Per package because the phases' costs belong to the model, not the
  /// machine alone: a smaller family would otherwise inherit a larger one's
  /// numbers and mis-pace its first run.
  ///
  /// Never throws: losing the estimate is not worth failing a generation that
  /// has already produced its audio.
  Future<void> writeCalibration(String packageId, PhaseRates rates) async {
    try {
      await root.create(recursive: true);
      final existing = readCalibration();
      final payload = <String, Object?>{
        'schema_version': calibrationSchemaVersion,
        'packages': <String, Object?>{
          for (final entry in existing.entries) entry.key: entry.value.toJson(),
          packageId: rates.toJson(),
        },
        'recorded_at': DateTime.now().toIso8601String(),
      };
      final temporary =
          File('${calibrationFile.path}.${_writeSequence++}.tmp');
      await temporary.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
        flush: true,
      );
      await temporary.rename(calibrationFile.path);
    } on Object {
      // Ignored deliberately; see the doc comment.
    }
  }

  Future<List<Track>> _readIndex() async {
    try {
      if (!indexFile.existsSync()) {
        return <Track>[];
      }
      final decoded = jsonDecode(await indexFile.readAsString());
      if (decoded is! Map<String, Object?>) {
        return <Track>[];
      }
      final rows = decoded['tracks'] as List<Object?>? ?? const <Object?>[];
      return rows
          .whereType<Map<String, Object?>>()
          .map(Track.fromJson)
          .where((Track track) => track.id.isNotEmpty)
          .toList();
    } on Object {
      // A corrupt index must not brick the app. The WAVs are still on disk and
      // the file is moved aside rather than overwritten, so it can be recovered
      // by hand if it ever matters.
      _quarantineIndex();
      return <Track>[];
    }
  }

  void _quarantineIndex() {
    try {
      if (indexFile.existsSync()) {
        indexFile.renameSync(
          '${indexFile.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
        );
      }
    } on Object {
      // Nothing useful to do; the caller carries on with an empty library.
    }
  }

  /// Serialises writes.
  ///
  /// The queue mutates the index from two places at once — a track finishing
  /// while the user enqueues another — and two overlapping writes would race on
  /// the temporary file, the second rename failing because the first already
  /// moved it. Chaining also means the last write genuinely wins.
  Future<void> _writes = Future<void>.value();
  int _writeSequence = 0;

  Future<void> _write() {
    final next = _writes.then((_) => _writeNow());
    // Swallow on the chain only: the failure is still delivered to the caller
    // through [next], but must not poison every later write.
    _writes = next.catchError((Object _) {});
    return next;
  }

  /// Writes atomically, so an interrupted write cannot truncate the library.
  Future<void> _writeNow() async {
    await root.create(recursive: true);
    final payload = <String, Object?>{
      'schema_version': schemaVersion,
      'tracks': _tracks.map((Track track) => track.toJson()).toList(),
    };
    final temporary = File('${indexFile.path}.${_writeSequence++}.tmp');
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
      flush: true,
    );
    await temporary.rename(indexFile.path);
  }

  static List<Track> _sorted(List<Track> tracks) =>
      List<Track>.of(tracks)..sort(
          (Track a, Track b) => b.createdAt.compareTo(a.createdAt),
        );
}
