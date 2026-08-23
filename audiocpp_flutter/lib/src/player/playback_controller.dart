import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../tracks/track.dart';
import '../tracks/track_store.dart';

/// Plays finished tracks.
///
/// Deliberately thin over `audioplayers`: it holds which track is loaded and
/// exposes position as plain values, so widgets rebuild from one notifier
/// instead of each subscribing to their own stream.
///
/// `audioplayers` rather than `just_audio` because just_audio has no Windows
/// implementation, and neither does the `audio_session` package it depends on —
/// constructing a player there throws `MissingPluginException`.
///
/// Nothing here starts playback on its own — a queue draining for half an hour
/// would otherwise interrupt whatever the user is listening to every few
/// minutes.
final class PlaybackController extends ChangeNotifier {
  PlaybackController({required this.store, AudioPlayer? player})
      : _injected = player;

  final TrackStore store;

  final AudioPlayer? _injected;
  AudioPlayer? _player;

  /// Creates the platform player on first use.
  ///
  /// Lazy because constructing one reaches for a platform plugin: a screen that
  /// merely shows a library, and every widget test of one, would otherwise need
  /// an audio backend it never uses.
  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) {
      return existing;
    }
    final player = _injected ?? AudioPlayer();
    _player = player;
    // The default release mode frees the platform resources once a track ends,
    // which would make pressing play again a fresh load rather than a replay.
    unawaited(player.setReleaseMode(ReleaseMode.stop));
    _subscriptions.add(player.onPositionChanged.listen((Duration position) {
      _position = position;
      _notify();
    }));
    // audioplayers reports duration asynchronously once the decoder has read
    // the header, so it arrives on a stream rather than as a property.
    _subscriptions.add(player.onDurationChanged.listen((Duration duration) {
      _duration = duration;
      _notify();
    }));
    _subscriptions.add(player.onPlayerStateChanged.listen((PlayerState state) {
      _playing = state == PlayerState.playing;
      _notify();
    }));
    _subscriptions.add(player.onPlayerComplete.listen((void _) {
      // Leave the head at the start rather than at the end, so pressing play
      // again replays instead of doing nothing.
      _playing = false;
      _position = Duration.zero;
      unawaited(player.seek(Duration.zero));
      _notify();
    }));
    return player;
  }

  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  Track? _current;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _disposed = false;
  String? _error;

  /// The track loaded into the player, finished or not.
  Track? get current => _current;

  bool get isPlaying => _playing;

  Duration get position => _position;

  /// Length of the loaded track, preferring what the player reports.
  Duration get duration => _duration ?? _current?.duration ?? Duration.zero;

  /// Why the last load failed, if it did.
  String? get error => _error;

  /// Fraction played, 0-1, for the scrubber.
  double get progress {
    final total = duration.inMilliseconds;
    if (total <= 0) {
      return 0;
    }
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  bool isCurrent(Track track) => _current?.id == track.id;

  /// Loads [track] and starts playing, or toggles if it is already loaded.
  Future<void> playOrToggle(Track track) async {
    if (isCurrent(track)) {
      await toggle();
      return;
    }
    await play(track);
  }

  Future<void> play(Track track) async {
    final file = store.audioFileFor(track);
    if (!track.hasAudio || file == null || !file.existsSync()) {
      _error = 'That track has no audio on disk.';
      _notify();
      return;
    }

    try {
      _error = null;
      _current = track;
      _position = Duration.zero;
      // Fall back to the track's own duration until the decoder reports one.
      _duration = null;
      _notify();
      final player = _ensurePlayer();
      await player.play(DeviceFileSource(file.path));
    } on Object catch (error) {
      _error = '$error';
      _current = null;
      _notify();
    }
  }

  Future<void> toggle() async {
    if (_current == null) {
      return;
    }
    final player = _ensurePlayer();
    if (_playing) {
      await player.pause();
    } else {
      await player.resume();
    }
  }

  Future<void> seekFraction(double fraction) async {
    final total = duration;
    if (_current == null || total == Duration.zero) {
      return;
    }
    await _ensurePlayer().seek(
      Duration(
        milliseconds: (total.inMilliseconds * fraction.clamp(0.0, 1.0)).round(),
      ),
    );
  }

  /// Moves within [playable] relative to what is loaded.
  ///
  /// The list is passed in rather than held: what "next" means is whatever the
  /// library is currently showing, including its sort order and any filter.
  Future<void> skip(List<Track> playable, int offset) async {
    if (playable.isEmpty) {
      return;
    }
    final index = playable.indexWhere((Track t) => t.id == _current?.id);
    final target = index == -1 ? 0 : index + offset;
    if (target < 0 || target >= playable.length) {
      return;
    }
    await play(playable[target]);
  }

  /// Drops the loaded track, e.g. because it was deleted underneath us.
  Future<void> clear() async {
    _current = null;
    _playing = false;
    _position = Duration.zero;
    _duration = null;
    await _player?.stop();
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player?.dispose());
    super.dispose();
  }
}
