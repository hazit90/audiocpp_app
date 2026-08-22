import 'dart:io';

import 'package:audiocpp_flutter/src/tracks/track.dart';
import 'package:audiocpp_flutter/src/tracks/track_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late TrackStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('audiocpp_tracks_test');
    store = TrackStore(root: root);
    await store.ensureExists();
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Track track(
    String id, {
    TrackStatus status = TrackStatus.done,
    String? audioFileName,
    int createdAtMs = 1000,
  }) {
    return Track(
      id: id,
      title: 'Track $id',
      params: const GenerationParams(caption: 'a bright pop song', lyrics: ''),
      modelPackageId: 'minimax_music3_q4_0',
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs),
      status: status,
      audioFileName: audioFileName,
    );
  }

  Future<void> writeAudio(Track t) async {
    await File(p.join(store.audioDirectory.path, t.audioFileName!))
        .writeAsBytes(<int>[0, 1, 2]);
  }

  test('round-trips a track through the index', () async {
    final original = track('a', audioFileName: 'a.wav').copyWith(
      params: const GenerationParams(
        caption: 'film score, strings',
        lyrics: '[verse] hello',
        seed: 41207,
        inferenceSteps: 24,
        styleTags: <String>['film score'],
      ),
      duration: const Duration(seconds: 32),
      favourite: true,
      peaks: <int>[0, 17, 255, 8],
    );
    await writeAudio(original);
    await store.upsert(original);

    final reloaded = TrackStore(root: root);
    await reloaded.load();

    expect(reloaded.tracks, hasLength(1));
    final restored = reloaded.tracks.single;
    expect(restored.id, 'a');
    expect(restored.status, TrackStatus.done);
    expect(restored.favourite, isTrue);
    expect(restored.duration, const Duration(seconds: 32));
    expect(restored.params.seed, 41207);
    expect(restored.params.inferenceSteps, 24);
    expect(restored.params.styleTags, <String>['film score']);
    expect(restored.params.isInstrumental, isFalse);
    expect(restored.peaks, <int>[0, 17, 255, 8]);
  });

  test('newest first', () async {
    await store.upsert(track('old', createdAtMs: 1000, audioFileName: null,
        status: TrackStatus.queued));
    await store.upsert(track('new', createdAtMs: 9000, audioFileName: null,
        status: TrackStatus.queued));

    expect(store.tracks.map((Track t) => t.id), <String>['new', 'old']);
  });

  test('upsert replaces rather than duplicating', () async {
    await store.upsert(track('a', status: TrackStatus.queued));
    await store.upsert(track('a', status: TrackStatus.queued)
        .copyWith(title: 'Renamed'));

    expect(store.tracks, hasLength(1));
    expect(store.tracks.single.title, 'Renamed');
  });

  test('load demotes a track whose audio went missing', () async {
    await store.upsert(track('a', audioFileName: 'a.wav'));

    final reloaded = TrackStore(root: root);
    await reloaded.load();

    expect(reloaded.tracks.single.status, TrackStatus.failed);
    expect(reloaded.tracks.single.errorMessage, contains('missing'));
    expect(reloaded.tracks.single.params.caption, isNotEmpty);
  });

  test('load demotes a track left running by a crash', () async {
    await store.upsert(track('a', status: TrackStatus.running));

    final reloaded = TrackStore(root: root);
    await reloaded.load();

    expect(reloaded.tracks.single.status, TrackStatus.failed);
    expect(reloaded.tracks.single.errorMessage, contains('Interrupted'));
  });

  test('remove deletes the audio file', () async {
    final t = track('a', audioFileName: 'a.wav');
    await writeAudio(t);
    await store.upsert(t);

    await store.remove('a');

    expect(store.tracks, isEmpty);
    expect(File(p.join(store.audioDirectory.path, 'a.wav')).existsSync(),
        isFalse);
  });

  test('prunes audio no track references', () async {
    final kept = track('a', audioFileName: 'a.wav');
    await writeAudio(kept);
    await store.upsert(kept);
    await File(p.join(store.audioDirectory.path, 'orphan.wav'))
        .writeAsBytes(<int>[9]);

    expect(await store.pruneOrphanedAudio(), 1);
    expect(File(p.join(store.audioDirectory.path, 'a.wav')).existsSync(),
        isTrue);
  });

  test('a corrupt index is quarantined, not fatal', () async {
    await store.indexFile.writeAsString('{not json');

    final reloaded = TrackStore(root: root);
    await reloaded.load();

    expect(reloaded.tracks, isEmpty);
    expect(reloaded.indexFile.existsSync(), isFalse);
    expect(
      root.listSync().whereType<File>().where(
            (File f) => f.path.contains('.corrupt-'),
          ),
      hasLength(1),
    );
  });
}
