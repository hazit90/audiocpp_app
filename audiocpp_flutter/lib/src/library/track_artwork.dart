import 'package:flutter/material.dart';

import '../tracks/track.dart';

/// Placeholder artwork derived from the track.
///
/// Deterministic from the seed and id, so a row keeps the same tile for its
/// whole life and forty rows do not read as forty identical grey squares.
class TrackArtwork extends StatelessWidget {
  const TrackArtwork({required this.track, this.size = 44, super.key});

  final Track track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hash = track.params.seed ^ track.id.hashCode;
    final hue = (hash % 360).abs().toDouble();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size / 5.5),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            HSLColor.fromAHSL(1, hue, 0.6, 0.45).toColor(),
            HSLColor.fromAHSL(1, (hue + 40) % 360, 0.5, 0.18).toColor(),
          ],
        ),
      ),
    );
  }
}
