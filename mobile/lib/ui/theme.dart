import 'package:flutter/material.dart';

/// WeDrop's palette, kept deliberately in step with the desktop app so the two
/// read as one product.
class WeDropColors {
  static const bg = Color(0xFF080B14);
  static const bgSoft = Color(0xFF0D1220);
  static const surface = Color(0xFF121829);
  static const surfaceHi = Color(0xFF1A2236);
  static const border = Color(0xFF232C45);
  static const borderHi = Color(0xFF2F3A58);

  static const brand = Color(0xFF4F7CFF);
  static const brandSoft = Color(0xFF6D92FF);
  static const accent = Color(0xFF9B6BFF);
  static const success = Color(0xFF2FCE8F);
  static const warn = Color(0xFFF2B544);
  static const danger = Color(0xFFF2555A);

  static const ink = Color(0xFFEEF2FF);
  static const inkDim = Color(0xFF9AA6C4);
  static const inkFaint = Color(0xFF6B7699);
}

/// Spacing on a 4pt grid. Using these instead of ad-hoc numbers is what keeps
/// vertical rhythm consistent between screens that were written months apart.
class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
}

/// Corner radii, scaled to the element's size: controls are tighter than the
/// cards that contain them, cards tighter than sheets.
class Radii {
  static const control = 12.0;
  static const card = 20.0;
  static const sheet = 24.0;
  static const pill = 999.0;
}

/// The type scale. Every size in the app comes from here — the alternative
/// (an inline TextStyle per widget) is how a UI ends up with 11, 11.5, 12,
/// 12.5, 13 and 13.5 all in use for what is visually the same thing.
class AppText {
  /// Card and row headings.
  static const title = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: WeDropColors.ink,
    letterSpacing: -0.1,
  );

  /// The small uppercase heading that labels a section *inside* a card, as
  /// opposed to [SectionHeader], which titles a whole page section.
  static const eyebrow = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: WeDropColors.inkFaint,
    letterSpacing: 0.8,
  );

  /// Default reading size for list rows and primary values.
  static const body = TextStyle(fontSize: 14, color: WeDropColors.ink);

  /// Secondary text: subtitles, supporting detail.
  static const label = TextStyle(fontSize: 13, color: WeDropColors.inkDim);

  /// Tertiary text: timestamps, hints, units.
  static const caption = TextStyle(fontSize: 12, color: WeDropColors.inkFaint);

  /// Numeric readouts (timers, percentages) — tabular figures stop the text
  /// jittering horizontally as the digits tick over.
  static const numeric = TextStyle(
    fontSize: 12,
    color: WeDropColors.inkFaint,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

ThemeData buildWeDropTheme() {
  const scheme = ColorScheme.dark(
    primary: WeDropColors.brand,
    secondary: WeDropColors.accent,
    surface: WeDropColors.surface,
    error: WeDropColors.danger,
    onPrimary: Colors.white,
    onSurface: WeDropColors.ink,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: WeDropColors.bg,
    canvasColor: WeDropColors.bg,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: WeDropColors.ink,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
      ),
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(color: WeDropColors.ink, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(color: WeDropColors.ink, fontWeight: FontWeight.w600),
      bodyMedium: TextStyle(color: WeDropColors.inkDim, height: 1.45),
      bodySmall: TextStyle(color: WeDropColors.inkFaint, height: 1.4),
    ),
    dividerTheme: const DividerThemeData(color: WeDropColors.border, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: WeDropColors.brand,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: WeDropColors.brandSoft),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? Colors.white : WeDropColors.inkFaint,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? WeDropColors.brand : WeDropColors.border,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: WeDropColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: WeDropColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: WeDropColors.surfaceHi,
      contentTextStyle: const TextStyle(color: WeDropColors.ink),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: WeDropColors.bgSoft,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: WeDropColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: WeDropColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: WeDropColors.brand),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: WeDropColors.bgSoft,
      surfaceTintColor: Colors.transparent,
      indicatorColor: WeDropColors.brand.withValues(alpha: 0.16),
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? WeDropColors.brandSoft
              : WeDropColors.inkFaint,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? WeDropColors.brandSoft
              : WeDropColors.inkFaint,
        ),
      ),
    ),
  );
}

/// Icon for a device's form factor.
IconData iconForFormFactor(String formFactor) {
  switch (formFactor) {
    case 'phone':
      return Icons.smartphone_rounded;
    case 'tablet':
      return Icons.tablet_mac_rounded;
    default:
      return Icons.laptop_mac_rounded;
  }
}

/// Human-readable byte count.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];

  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0
      ? '${value.toInt()} ${units[unit]}'
      : '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

/// Relative time for feeds.
String timeAgo(int millis) {
  if (millis == 0) return '';

  final seconds = (DateTime.now().millisecondsSinceEpoch - millis) ~/ 1000;
  if (seconds < 45) return 'just now';
  if (seconds < 3600) return '${seconds ~/ 60}m ago';
  if (seconds < 86400) return '${seconds ~/ 3600}h ago';

  final days = seconds ~/ 86400;
  if (days == 1) return 'yesterday';
  if (days < 30) return '${days}d ago';
  return DateTime.fromMillisecondsSinceEpoch(millis).toString().split(' ').first;
}
