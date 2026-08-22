import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The waveform, drawn from stored peaks and scrubbable.
///
/// A CustomPainter rather than a Row of boxes: two hundred bars rebuilt on
/// every position tick would be two hundred widgets a second.
class WaveformBar extends StatelessWidget {
  const WaveformBar({
    required this.peaks,
    required this.progress,
    required this.onSeek,
    super.key,
  });

  /// Amplitude buckets, 0-255. Empty draws a flat placeholder.
  final List<int> peaks;

  /// Fraction played, 0-1.
  final double progress;

  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        void seekTo(Offset local) {
          if (constraints.maxWidth > 0) {
            onSeek((local.dx / constraints.maxWidth).clamp(0.0, 1.0));
          }
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails d) => seekTo(d.localPosition),
          onHorizontalDragUpdate: (DragUpdateDetails d) =>
              seekTo(d.localPosition),
          child: CustomPaint(
            size: Size(constraints.maxWidth, 36),
            painter: _WaveformPainter(
              peaks: peaks,
              progress: progress,
              played: AppTheme.accent,
              remaining: theme.colorScheme.outlineVariant,
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.played,
    required this.remaining,
  });

  final List<int> peaks;
  final double progress;
  final Color played;
  final Color remaining;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) {
      return;
    }

    // One bar per bucket would be sub-pixel on a narrow window and wasteful on
    // a wide one, so the bar count follows the width and samples the peaks.
    final bars = (size.width / 3).floor().clamp(1, 400);
    final barWidth = size.width / bars;
    final centre = size.height / 2;
    final paint = Paint()..strokeCap = StrokeCap.round;

    for (var i = 0; i < bars; i++) {
      final fraction = bars == 1 ? 0.0 : i / (bars - 1);
      final amplitude = _peakAt(fraction);
      // A floor of two pixels: a silent passage should still read as a track
      // rather than as a gap in the control.
      final height = (2 + amplitude * (size.height - 4)).clamp(2, size.height);
      final x = i * barWidth + barWidth / 2;

      paint
        ..color = fraction <= progress ? played : remaining
        ..strokeWidth = barWidth * 0.6;
      canvas.drawLine(
        Offset(x, centre - height / 2),
        Offset(x, centre + height / 2),
        paint,
      );
    }
  }

  /// Amplitude 0-1 at a fraction through the track.
  double _peakAt(double fraction) {
    if (peaks.isEmpty) {
      return 0.12;
    }
    final index = (fraction * (peaks.length - 1)).round().clamp(
          0,
          peaks.length - 1,
        );
    return peaks[index] / 255;
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.peaks != peaks ||
      old.played != played ||
      old.remaining != remaining;
}
