import 'package:material_ui/material_ui.dart';

/// App theming.
///
/// One seed colour drives both schemes through Material 3, so light and dark
/// stay in step and nothing has to be hand-paired. Everything below the seed is
/// about legibility on a counter: generous tap targets and type that survives a
/// glance from arm's length.
class AppTheme {
  const AppTheme._();

  static const Color _seed = Color(0xFF6F4E37); // Roasted coffee.

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 2,
      ),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: const InputDecorationThemeData(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 48dp is the floor for something tapped repeatedly with a thumb.
          minimumSize: const Size(0, 48),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

/// Colours that carry meaning on the board, derived from the active scheme so
/// they stay legible in both light and dark.
extension StatusPalette on ColorScheme {
  Color get warning => brightness == Brightness.light
      ? const Color(0xFF9A6700)
      : const Color(0xFFE3B341);

  Color get onWarningSurface => brightness == Brightness.light
      ? const Color(0xFF3D2900)
      : const Color(0xFFFFF4D6);

  Color get warningSurface => brightness == Brightness.light
      ? const Color(0xFFFFF8E1)
      : const Color(0xFF3A2E09);

  Color get success => brightness == Brightness.light
      ? const Color(0xFF1B7F3B)
      : const Color(0xFF69D98A);

  Color get successSurface => brightness == Brightness.light
      ? const Color(0xFFE8F5EC)
      : const Color(0xFF123520);
}
