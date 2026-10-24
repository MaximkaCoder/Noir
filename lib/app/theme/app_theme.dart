import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/features/settings/domain/app_settings.dart';

/// Builds NOIR's custom theme. Material is only the foundation: colors,
/// typography and component shapes all come from NOIR tokens.
ThemeData buildNoirTheme(Brightness brightness, Density density) {
  final c = brightness == Brightness.dark
      ? NoirPalette.dark
      : NoirPalette.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.primaryActionFill,
    onPrimary: c.primaryActionText,
    secondary: c.textSecondary,
    onSecondary: c.background,
    error: c.destructive,
    onError: Colors.white,
    surface: c.background,
    onSurface: c.textPrimary,
    onSurfaceVariant: c.textSecondary,
    outline: c.glassBorder,
    outlineVariant: c.glassBorder,
    surfaceContainerHighest: c.surfaceElevated,
    surfaceContainerHigh: c.surfaceElevated,
    surfaceContainer: c.surfaceSolid,
    surfaceContainerLow: c.backgroundSecondary,
  );

  final text = _textTheme(c);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Inter',
    textTheme: text,
    scaffoldBackgroundColor: c.background,
    canvasColor: c.background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: c.hover,
    focusColor: c.selected,
    visualDensity: density == Density.compact
        ? VisualDensity.compact
        : VisualDensity.standard,
    extensions: [c],
    iconTheme: IconThemeData(color: c.textSecondary, size: 20),
    dividerTheme: DividerThemeData(color: c.glassBorder, thickness: 1),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: c.surfaceElevated,
        borderRadius: NoirRadii.smAll,
        border: Border.all(color: c.glassBorder),
      ),
      textStyle: text.labelMedium?.copyWith(color: c.textPrimary),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: c.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: NoirRadii.mdAll,
        side: BorderSide(color: c.glassBorder),
      ),
      textStyle: text.bodyMedium,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.surfaceElevated,
      contentTextStyle: text.bodyMedium?.copyWith(color: c.textPrimary),
      actionTextColor: c.textPrimary,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: NoirRadii.mdAll,
        side: BorderSide(color: c.glassBorder),
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: c.textPrimary,
      inactiveTrackColor: c.glassBorder,
      thumbColor: c.textPrimary,
      overlayColor: c.hover,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      trackShape: const RoundedRectSliderTrackShape(),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? c.primaryActionText
            : c.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.textPrimary : c.hover,
      ),
      trackOutlineColor: WidgetStatePropertyAll(c.glassBorder),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.textPrimary,
      linearTrackColor: c.glassBorder,
      circularTrackColor: Colors.transparent,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.textPrimary,
      selectionColor: c.selected,
      selectionHandleColor: c.textPrimary,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(c.glassBorder),
      radius: const Radius.circular(4),
      thickness: const WidgetStatePropertyAll(6),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: NoirRadii.xlAll,
        side: BorderSide(color: c.glassBorder),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

TextTheme _textTheme(NoirPalette c) {
  TextStyle s(double size, FontWeight w, Color color, {double h = 1.3}) =>
      TextStyle(
        fontFamily: 'Inter',
        fontSize: size,
        fontWeight: w,
        color: color,
        height: h,
        letterSpacing: size >= 22 ? -0.4 : -0.1,
      );
  return TextTheme(
    displaySmall: s(34, FontWeight.w600, c.textPrimary, h: 1.15),
    headlineMedium: s(28, FontWeight.w600, c.textPrimary, h: 1.2),
    headlineSmall: s(24, FontWeight.w600, c.textPrimary, h: 1.2),
    titleLarge: s(20, FontWeight.w600, c.textPrimary),
    titleMedium: s(16, FontWeight.w600, c.textPrimary),
    titleSmall: s(14, FontWeight.w600, c.textPrimary),
    bodyLarge: s(15, FontWeight.w400, c.textSecondary, h: 1.4),
    bodyMedium: s(14, FontWeight.w500, c.textPrimary),
    bodySmall: s(12.5, FontWeight.w400, c.textSecondary),
    labelLarge: s(14, FontWeight.w500, c.textPrimary),
    labelMedium: s(12.5, FontWeight.w500, c.textSecondary),
    labelSmall: s(11, FontWeight.w500, c.textTertiary),
  );
}

/// Timestamps and durations never jitter: tabular figures everywhere.
const tabularFigures = [FontFeature.tabularFigures()];
