import 'package:flutter/material.dart';

import '../create/enqueue_button.dart' show formatDuration;
import '../library/track_artwork.dart';
import '../tracks/track.dart';
import 'playback_controller.dart';
import 'waveform_bar.dart';

/// The persistent player across the bottom of the app.
///
/// Subscribes to the controller and hands plain values to [PlayerBarContent],
/// which is where the layout lives.
class NowPlayingBar extends StatefulWidget {
  const NowPlayingBar({
    required this.playback,
    required this.playable,
    super.key,
  });

  final PlaybackController playback;

  /// What "next" and "previous" mean right now — the library's current order.
  final List<Track> playable;

  @override
  State<NowPlayingBar> createState() => _NowPlayingBarState();
}

class _NowPlayingBarState extends State<NowPlayingBar> {
  @override
  void initState() {
    super.initState();
    widget.playback.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.playback.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final track = playback.current;
    if (track == null) {
      return const SizedBox.shrink();
    }

    return PlayerBarContent(
      track: track,
      position: playback.position,
      duration: playback.duration,
      progress: playback.progress,
      isPlaying: playback.isPlaying,
      onToggle: playback.toggle,
      onPrevious: () => playback.skip(widget.playable, -1),
      onNext: () => playback.skip(widget.playable, 1),
      onSeek: playback.seekFraction,
    );
  }
}

/// The player bar's layout, over plain values.
///
/// Separated from the controller so it can be laid out on its own: this bar is
/// the densest row in the app and the easiest place to overflow.
class PlayerBarContent extends StatelessWidget {
  const PlayerBarContent({
    required this.track,
    required this.position,
    required this.duration,
    required this.progress,
    required this.isPlaying,
    required this.onToggle,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    super.key,
  });

  /// Below this the waveform and time readouts are dropped.
  static const double wideBreakpoint = 720;

  final Track track;
  final Duration position;
  final Duration duration;
  final double progress;
  final bool isPlaying;
  final VoidCallback onToggle;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      // Keyed off the bar's own width, not the window's: at three-pane widths
      // the bar spans everything, but it is the bar that decides.
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final wide = constraints.maxWidth >= wideBreakpoint;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Divider(height: 1),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: <Widget>[
                    TrackArtwork(track: track, size: 40),
                    const SizedBox(width: 12),
                    // Titles take the slack when narrow and a fixed slice when
                    // wide, so the waveform gets the rest. Sizing is decided
                    // here: a Flexible inside _Titles would be misparented the
                    // moment the caller wrapped it in anything but a Flex.
                    if (wide)
                      SizedBox(width: 180, child: _Titles(track: track))
                    else
                      Expanded(child: _Titles(track: track)),
                    const SizedBox(width: 8),
                    _Transport(
                      isPlaying: isPlaying,
                      onToggle: onToggle,
                      onPrevious: onPrevious,
                      onNext: onNext,
                    ),
                    if (wide) ...<Widget>[
                      const SizedBox(width: 12),
                      Text(formatDuration(position),
                          style: theme.textTheme.bodySmall),
                      const SizedBox(width: 10),
                      Expanded(
                        child: WaveformBar(
                          peaks: track.peaks,
                          progress: progress,
                          onSeek: onSeek,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(formatDuration(duration),
                          style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              // A narrow bar loses the waveform but keeps a position readout,
              // which is the part that shows the track is advancing.
              if (!wide)
                LinearProgressIndicator(value: progress, minHeight: 2),
            ],
          );
        },
      ),
    );
  }
}

class _Titles extends StatelessWidget {
  const _Titles({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          track.title,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
        Text(
          track.params.caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({
    required this.isPlaying,
    required this.onToggle,
    required this.onPrevious,
    required this.onNext,
  });

  final bool isPlaying;
  final VoidCallback onToggle;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: 'Previous',
          onPressed: onPrevious,
          icon: const Icon(Icons.skip_previous),
        ),
        IconButton.filled(
          tooltip: isPlaying ? 'Pause' : 'Play',
          onPressed: onToggle,
          icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
        ),
        IconButton(
          tooltip: 'Next',
          onPressed: onNext,
          icon: const Icon(Icons.skip_next),
        ),
      ],
    );
  }
}
