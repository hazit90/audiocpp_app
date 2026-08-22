import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The one primary action on the Create pane.
///
/// Takes plain values rather than the queue so it can be laid out on its own —
/// this widget has twice been where a `Size.from*` constructor left one axis at
/// infinity and blanked the whole pane, and it is worth being able to test.
class EnqueueButton extends StatelessWidget {
  const EnqueueButton({
    required this.enabled,
    required this.onPressed,
    this.waiting = 0,
    this.wait,
    this.disabledReason,
    super.key,
  });

  final bool enabled;
  final VoidCallback onPressed;

  /// Tracks queued ahead of this one.
  final int waiting;

  /// Estimated wait before it would start, when one can be estimated.
  final Duration? wait;

  /// Why the button is disabled, shown in place of the queue summary.
  ///
  /// A disabled button with no explanation is the worst version of this
  /// control: the reason is always something the user can act on.
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final subtitle = enabled
        ? <String>[
            if (waiting > 0) '$waiting ahead',
            if (wait != null && wait! > Duration.zero)
              '~${formatDuration(wait!)} wait',
          ].join(' · ')
        : (disabledReason ?? '');

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: enabled ? AppTheme.ctaGradient : null,
        borderRadius: BorderRadius.circular(12),
      ),
      // Full width comes from the box, never from a minimumSize: the
      // `Size.from*` constructors leave the other axis at infinity, which fails
      // layout in whichever direction the parent is unbounded.
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: enabled ? onPressed : null,
          style: FilledButton.styleFrom(
            backgroundColor: enabled ? Colors.transparent : null,
            shadowColor: Colors.transparent,
            foregroundColor: enabled ? Colors.white : null,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text('Add to queue'),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `1:23`, or `12s` under a minute.
String formatDuration(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 60) {
    return '${seconds}s';
  }
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}
