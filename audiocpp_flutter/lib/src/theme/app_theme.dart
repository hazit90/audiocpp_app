import 'package:flutter/material.dart';

/// The app's visual language, in one place.
///
/// Dark is the design target — this is a studio tool that people will sit in
/// front of for long generations — and light is derived from the same seed so
/// it stays usable rather than being a second design.
abstract final class AppTheme {
  /// Accent taken from the app icon, and the only saturated colour in the UI.
  /// Reserving it for the primary action and the currently playing track is
  /// what keeps a dense library readable.
  static const Color accent = Color(0xFFFF1E6F);

  /// Secondary end of the CTA gradient.
  static const Color accentWarm = Color(0xFFFF5A3C);

  static const Color _surface = Color(0xFF0A0A0C);
  static const Color _panel = Color(0xFF111114);
  static const Color _panelHigh = Color(0xFF17171B);
  static const Color _line = Color(0xFF242429);

  /// Radius used by cards, chips and buttons alike.
  static const double radius = 14;

  /// Standard gap between stacked sections.
  static const double gap = 14;

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(
      primary: accent,
      surface: _surface,
      surfaceContainerLow: _panel,
      surfaceContainerHighest: _panelHigh,
      outlineVariant: _line,
    );
    return _base(scheme);
  }

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    );
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      cardTheme: CardThemeData(
        color: dark ? _panel : scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      // Filled rather than outlined: a form of eight fields reads as one block
      // instead of eight boxes.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? _panelHigh : scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // A height floor only. `Size.fromHeight` would set the width to
          // infinity, which fails layout for any button inside a Row.
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: dark ? _panelHigh : scheme.surfaceContainerHighest,
        selectedColor: accent.withValues(alpha: 0.14),
        showCheckmark: false,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: dark ? _panelHigh : scheme.surfaceContainerHighest,
        labelType: NavigationRailLabelType.all,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? _panel : scheme.surfaceContainerLow,
        indicatorColor: accent.withValues(alpha: 0.16),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: accent,
        thumbColor: Colors.white,
        trackHeight: 4,
      ),
    );
  }

  /// Gradient used by the single primary action on a screen.
  static const LinearGradient ctaGradient = LinearGradient(
    colors: <Color>[accent, accentWarm],
  );
}
