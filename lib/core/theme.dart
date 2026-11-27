import 'package:flutter/material.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:xterm/xterm.dart';

class AppColors {
  // Keep fallback colors aligned with the default workspace palette.
  static const bg = Color(0xFF0B1020);
  static const surface = Color(0xFF111A2B);
  static const surface2 = Color(0xFF182438);
  static const surface3 = Color(0xFF24324A);

  static const border = Color(0xFF28364D);
  static const borderStrong = Color(0xFF40516C);

  static const ink = Color(0xFFF1F5F9);
  static const muted = Color(0xFFA7B4CA);

  static const accent = Color(0xFF98A5FF);
  static const accentContainer = Color(0xFF273456);
  static const accentInk = Color(0xFF10172A);

  static const cyan = Color(0xFF70D6D1);
  static const cyanContainer = Color(0xFF163C42);
  static const amber = Color(0xFFF5C16C);
  static const red = Color(0xFFFDA4AF);
  static const green = Color(0xFF5AD6AA);
}

@immutable
class TermPulsePalette extends ThemeExtension<TermPulsePalette> {
  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color border;
  final Color borderStrong;
  final Color ink;
  final Color muted;
  final Color accent;
  final Color accentContainer;
  final Color accentInk;
  final Color cyan;
  final Color cyanContainer;
  final Color amber;
  final Color red;
  final Color green;
  final TerminalTheme terminalTheme;

  const TermPulsePalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.border,
    required this.borderStrong,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.accentContainer,
    required this.accentInk,
    required this.cyan,
    required this.cyanContainer,
    required this.amber,
    required this.red,
    required this.green,
    required this.terminalTheme,
  });

  @override
  TermPulsePalette copyWith({
    Brightness? brightness,
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? surface3,
    Color? border,
    Color? borderStrong,
    Color? ink,
    Color? muted,
    Color? accent,
    Color? accentContainer,
    Color? accentInk,
    Color? cyan,
    Color? cyanContainer,
    Color? amber,
    Color? red,
    Color? green,
    TerminalTheme? terminalTheme,
  }) {
    return TermPulsePalette(
      brightness: brightness ?? this.brightness,
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      surface3: surface3 ?? this.surface3,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      ink: ink ?? this.ink,
      muted: muted ?? this.muted,
      accent: accent ?? this.accent,
      accentContainer: accentContainer ?? this.accentContainer,
      accentInk: accentInk ?? this.accentInk,
      cyan: cyan ?? this.cyan,
      cyanContainer: cyanContainer ?? this.cyanContainer,
      amber: amber ?? this.amber,
      red: red ?? this.red,
      green: green ?? this.green,
      terminalTheme: terminalTheme ?? this.terminalTheme,
    );
  }

  @override
  TermPulsePalette lerp(ThemeExtension<TermPulsePalette>? other, double t) {
    if (other is! TermPulsePalette) return this;
    return TermPulsePalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      surface3: Color.lerp(surface3, other.surface3, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentContainer: Color.lerp(accentContainer, other.accentContainer, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      cyan: Color.lerp(cyan, other.cyan, t)!,
      cyanContainer: Color.lerp(cyanContainer, other.cyanContainer, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      red: Color.lerp(red, other.red, t)!,
      green: Color.lerp(green, other.green, t)!,
      terminalTheme: t < 0.5 ? terminalTheme : other.terminalTheme,
    );
  }
}

TermPulsePalette paletteFor(AppThemePreset preset) {
  switch (preset) {
    case AppThemePreset.dark:
      return const TermPulsePalette(
        brightness: Brightness.dark,
        bg: Color(0xFF0B1020),
        surface: Color(0xFF111A2B),
        surface2: Color(0xFF182438),
        surface3: Color(0xFF24324A),
        border: Color(0xFF28364D),
        borderStrong: Color(0xFF40516C),
        ink: Color(0xFFF1F5F9),
        muted: Color(0xFFA7B4CA),
        accent: Color(0xFF98A5FF),
        accentContainer: Color(0xFF273456),
        accentInk: Color(0xFF10172A),
        cyan: Color(0xFF70D6D1),
        cyanContainer: Color(0xFF163C42),
        amber: Color(0xFFF5C16C),
        red: Color(0xFFFDA4AF),
        green: Color(0xFF5AD6AA),
        terminalTheme: TerminalTheme(
          cursor: Color(0xFF98A5FF),
          selection: Color(0x556D7CFF),
          foreground: Color(0xFFE8EEF8),
          background: Color(0xFF0C1424),
          black: Color(0xFF161A23),
          red: Color(0xFFFB7185),
          green: Color(0xFF34D399),
          yellow: Color(0xFFFBBF24),
          blue: Color(0xFF818CF8),
          magenta: Color(0xFFC084FC),
          cyan: Color(0xFF38BDF8),
          white: Color(0xFFE2E8F0),
          brightBlack: Color(0xFF8C9BB5),
          brightRed: Color(0xFFFDA4AF),
          brightGreen: Color(0xFF6EE7B7),
          brightYellow: Color(0xFFFDE68A),
          brightBlue: Color(0xFFA5B4FC),
          brightMagenta: Color(0xFFD8B4FE),
          brightCyan: Color(0xFF7DD3FC),
          brightWhite: Color(0xFFFFFFFF),
          searchHitBackground: Color(0xFF92400E),
          searchHitBackgroundCurrent: Color(0xFFF59E0B),
          searchHitForeground: Color(0xFF06070B),
        ),
      );

    case AppThemePreset.light:
      return const TermPulsePalette(
        brightness: Brightness.light,
        bg: Color(0xFFF5F7FB),
        surface: Color(0xFFFFFFFF),
        surface2: Color(0xFFEEF1F7),
        surface3: Color(0xFFE2E7F2),
        border: Color(0x140F172A),
        borderStrong: Color(0x240F172A),
        ink: Color(0xFF0B1120),
        muted: Color(0xFF52627A),
        accent: Color(0xFF4F46E5),
        accentContainer: Color(0xFFEEF2FF),
        accentInk: Color(0xFFFFFFFF),
        cyan: Color(0xFF0F766E),
        cyanContainer: Color(0xFFCCFBF1),
        amber: Color(0xFF9A5705),
        red: Color(0xFFBE123C),
        green: Color(0xFF047857),
        terminalTheme: TerminalTheme(
          cursor: Color(0xFF4F46E5),
          selection: Color(0x3D4F46E5),
          foreground: Color(0xFF0F172A),
          background: Color(0xFFFFFFFF),
          black: Color(0xFF1E293B),
          red: Color(0xFFDC2626),
          green: Color(0xFF047857),
          yellow: Color(0xFF9A5705),
          blue: Color(0xFF4F46E5),
          magenta: Color(0xFF9333EA),
          cyan: Color(0xFF0369A1),
          white: Color(0xFF475569),
          brightBlack: Color(0xFF64748B),
          brightRed: Color(0xFFE11D48),
          brightGreen: Color(0xFF047857),
          brightYellow: Color(0xFF9A5705),
          brightBlue: Color(0xFF4F46E5),
          brightMagenta: Color(0xFF9333EA),
          brightCyan: Color(0xFF0369A1),
          brightWhite: Color(0xFF0F172A),
          searchHitBackground: Color(0xFFFDE68A),
          searchHitBackgroundCurrent: Color(0xFFF59E0B),
          searchHitForeground: Color(0xFF0F172A),
        ),
      );
  }
}

extension TermPulseThemeContext on BuildContext {
  TermPulsePalette get tp => Theme.of(this).extension<TermPulsePalette>()!;
}

ThemeData buildTermPulseTheme(AppThemePreset preset) {
  final p = paletteFor(preset);
  final isDark = p.brightness == Brightness.dark;
  const radius = BorderRadius.all(Radius.circular(11));

  final scheme = isDark
      ? ColorScheme.dark(
          primary: p.accent,
          onPrimary: p.accentInk,
          primaryContainer: p.accentContainer,
          onPrimaryContainer: p.accent,
          secondary: p.cyan,
          onSecondary: p.accentInk,
          secondaryContainer: p.cyanContainer,
          onSecondaryContainer: p.cyan,
          surface: p.surface,
          onSurface: p.ink,
          surfaceContainerLowest: p.bg,
          surfaceContainerLow: p.surface,
          surfaceContainer: p.surface2,
          surfaceContainerHigh: p.surface3,
          surfaceContainerHighest: p.surface3,
          outline: p.border,
          outlineVariant: p.borderStrong,
          error: p.red,
          onError: p.bg,
        )
      : ColorScheme.light(
          primary: p.accent,
          onPrimary: p.accentInk,
          primaryContainer: p.accentContainer,
          onPrimaryContainer: p.accent,
          secondary: p.cyan,
          onSecondary: Colors.white,
          secondaryContainer: p.cyanContainer,
          onSecondaryContainer: p.cyan,
          surface: p.surface,
          onSurface: p.ink,
          surfaceContainerLowest: p.bg,
          surfaceContainerLow: p.surface,
          surfaceContainer: p.surface2,
          surfaceContainerHigh: p.surface3,
          surfaceContainerHighest: p.surface3,
          outline: p.border,
          outlineVariant: p.borderStrong,
          error: p.red,
          onError: Colors.white,
        );

  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    scaffoldBackgroundColor: p.bg,
    colorScheme: scheme,
    textTheme: ThemeData(
      brightness: p.brightness,
    ).textTheme.apply(bodyColor: p.ink, displayColor: p.ink),
    extensions: [p],
    dividerColor: p.border,
    splashColor: p.accent.withValues(alpha: 0.10),
    highlightColor: p.accent.withValues(alpha: 0.06),
    hoverColor: p.accent.withValues(alpha: 0.08),
    focusColor: p.accent.withValues(alpha: 0.16),
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: p.ink,
        fontSize: 16,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.25,
      ),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: p.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.borderStrong),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: isDark ? p.surface2 : p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.borderStrong),
      ),
      textStyle: TextStyle(color: p.ink, fontSize: 13),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: p.surface3,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.borderStrong),
      ),
      textStyle: TextStyle(
        color: p.ink,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.surface2,
      contentTextStyle: TextStyle(color: p.ink, fontSize: 13),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: p.borderStrong),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: radius),
        minimumSize: const Size(40, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        textStyle: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        backgroundColor: p.surface2.withValues(alpha: 0.72),
        side: BorderSide(color: p.borderStrong),
        shape: const RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.muted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: p.border)),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return p.accentContainer;
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return p.accent;
          return p.muted;
        }),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 9),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surface2,
      selectedColor: p.accentContainer,
      secondarySelectedColor: p.accentContainer,
      disabledColor: p.surface,
      labelStyle: TextStyle(
        color: p.ink,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      secondaryLabelStyle: TextStyle(
        color: p.accent,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
      side: BorderSide(color: p.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      checkmarkColor: p.accent,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accentInk : p.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.surface3,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.borderStrong,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.muted.withValues(alpha: 0.55)),
      radius: const Radius.circular(999),
      thickness: const WidgetStatePropertyAll(5),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark
          ? p.surface2.withValues(alpha: 0.7)
          : p.surface2.withValues(alpha: 0.8),
      isDense: true,
      labelStyle: TextStyle(color: p.muted, fontSize: 13),
      hintStyle: TextStyle(color: p.muted, fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.accent, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.red, width: 1.5),
      ),
    ),
  );
}

ThemeData buildTermPulseDarkTheme() => buildTermPulseTheme(AppThemePreset.dark);
final termPulseTerminalTheme = paletteFor(AppThemePreset.dark).terminalTheme;
