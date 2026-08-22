import 'dart:io';

import 'package:audiocpp_flutter/src/player/playback_controller.dart';
import 'package:audiocpp_flutter/src/tracks/track.dart';
import 'package:audiocpp_flutter/src/tracks/track_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Exercises the parts that do not need an audio backend.
///
/// Actually decoding and playing a file needs the platform plugin, which does
/// not exist on the test VM — so the player is created lazily and these tests
/// stay on the near side of it.
void main() {
  late Directory root;
  late TrackStore store;
  late PlaybackController playback;

  Track track(String id, {String? audioFileName}) => Track(
        id: id,
        title: 'Track $id',
        params: const GenerationParams(caption: 'ambient', lyrics: ''),
        modelPackageId: 'minimax_music3_q4_0',
        createdAt: DateTime.now(),
        status: TrackStatus.done,
        audioFileName: audioFileName,
        duration: const Duration(seconds: 30),
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('audiocpp_playback_test');
    store = TrackStore(root: root);
    await store.load();
    playback = PlaybackController(store: store);
  });

  tearDown(() async {
    playback.dispose();
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  test('starts with nothing loaded', () {
    expect(playback.current, isNull);
    expect(playback.isPlaying, isFalse);
    expect(playback.progress, 0);
  });

  test('a track whose file is gone reports rather than throwing', () async {
    await playback.play(track('a', audioFileName: 'missing.wav'));

    expect(playback.error, contains('no audio'));
    expect(playback.current, isNull);
  });

  test('a track with no audio at all is refused', () async {
    await playback.play(track('a'));

    expect(playback.current, isNull);
    expect(playback.error, isNotNull);
  });

  test('progress is zero when nothing has a duration', () {
    expect(playback.progress, 0);
    expect(playback.duration, Duration.zero);
  });

  test('skipping an empty list does nothing', () async {
    await playback.skip(<Track>[], 1);
    expect(playback.current, isNull);
  });

  test('seeking with nothing loaded does nothing', () async {
    await playback.seekFraction(0.5);
    expect(playback.position, Duration.zero);
  });

  test('isCurrent tracks what is loaded', () async {
    expect(playback.isCurrent(track('a')), isFalse);
  });

  test('clear resets even when no player was ever created', () async {
    await playback.clear();
    expect(playback.current, isNull);
    expect(playback.isPlaying, isFalse);
  });

  test('audioFileFor resolves against the store, not an absolute path',
      () async {
    final t = track('a', audioFileName: 'a.wav');
    await File(p.join(store.audioDirectory.path, 'a.wav')).writeAsBytes(<int>[1]);

    expect(store.audioFileFor(t)!.path, contains(root.path));
  });
}
