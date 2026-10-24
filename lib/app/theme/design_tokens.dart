import 'package:flutter/material.dart';

/// Color tokens for one brightness. Monochrome by design: hierarchy comes from
/// opacity, blur and contrast, never from an accent hue.
@immutable
class NoirPalette extends ThemeExtension<NoirPalette> {
  const NoirPalette({
    required this.background,
    required this.backgroundSecondary,
    required this.surfaceSolid,
    required this.surfaceElevated,
    required this.glassFill,
    required this.glassBorder,
    required this.glassHighlight,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.hover,
    required this.selected,
    required this.primaryActionFill,
    required this.primaryActionText,
    required this.destructive,
    required this.shadow,
  });

  static const dark = NoirPalette(
    background: Color(0xFF090909),
    backgroundSecondary: Color(0xFF111111),
    surfaceSolid: Color(0xFF161616),
    surfaceElevated: Color(0xFF1C1C1C),
    glassFill: Color(0x0FFFFFFF),
    glassBorder: Color(0x1AFFFFFF),
    glassHighlight: Color(0x14FFFFFF),
    textPrimary: Color(0xFFF2F2F0),
    textSecondary: Color(0xFFA3A3A3),
    textTertiary: Color(0xFF6B6B6B),
    hover: Color(0x12FFFFFF),
    selected: Color(0x1FFFFFFF),
    primaryActionFill: Color(0xFFF5F5F3),
    primaryActionText: Color(0xFF0B0B0B),
    destructive: Color(0xFFD9534F),
    shadow: Color(0x99000000),
  );

  static const light = NoirPalette(
    background: Color(0xFFF6F4F0),
    backgroundSecondary: Color(0xFFEFECE7),
    surfaceSolid: Color(0xFFFBFAF8),
    surfaceElevated: Color(0xFFFFFFFF),
    glassFill: Color(0x8CFFFFFF),
    glassBorder: Color(0x1F000000),
    glassHighlight: Color(0x66FFFFFF),
    textPrimary: Color(0xFF141414),
    textSecondary: Color(0xFF5E5E5E),
    textTertiary: Color(0xFF8F8F8F),
    hover: Color(0x0D000000),
    selected: Color(0x17000000),
    primaryActionFill: Color(0xFF141414),
    primaryActionText: Color(0xFFF8F7F4),
    destructive: Color(0xFFB3261E),
    shadow: Color(0x24000000),
  );

  final Color background;
  final Color backgroundSecondary;

  /// Opaque surface used when Liquid Glass is off.
  final Color surfaceSolid;
  final Color surfaceElevated;
  final Color glassFill;
  final Color glassBorder;
  final Color glassHighlight;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color hover;
  final Color selected;
  final Color primaryActionFill;
  final Color primaryActionText;
  final Color destructive;
  final Color shadow;

  @override
  NoirPalette copyWith() => this;

  @override
  NoirPalette lerp(NoirPalette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return NoirPalette(
      background: l(background, other.background),
      backgroundSecondary: l(backgroundSecondary, other.backgroundSecondary),
      surfaceSolid: l(surfaceSolid, other.surfaceSolid),
      surfaceElevated: l(surfaceElevated, other.surfaceElevated),
      glassFill: l(glassFill, other.glassFill),
      glassBorder: l(glassBorder, other.glassBorder),
      glassHighlight: l(glassHighlight, other.glassHighlight),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textTertiary: l(textTertiary, other.textTertiary),
      hover: l(hover, other.hover),
      selected: l(selected, other.selected),
      primaryActionFill: l(primaryActionFill, other.primaryActionFill),
      primaryActionText: l(primaryActionText, other.primaryActionText),
      destructive: l(destructive, other.destructive),
      shadow: l(shadow, other.shadow),
    );
  }
}

/// 4-pt spacing scale.
abstract final class NoirSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

abstract final class NoirRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// Backdrop blur sigmas. `reduced` is used by Performance mode.
abstract final class NoirBlur {
  static const double full = 28;
  static const double reduced = 10;
}

abstract final class NoirMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration medium = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 360);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
}

/// Window-width breakpoints for the adaptive shell.
enum WindowClass {
  /// Phones and very narrow windows: bottom navigation.
  compact,

  /// Narrow desktop windows and tablets: icon rail.
  medium,

  /// Wide desktop windows: full sidebar.
  expanded;

  static WindowClass of(double width) {
    if (width < 640) return WindowClass.compact;
    if (width < 1080) return WindowClass.medium;
    return WindowClass.expanded;
  }
}

/// Shorthand to read the palette from anywhere below the app theme.
extension NoirThemeX on BuildContext {
  NoirPalette get noir => Theme.of(this).extension<NoirPalette>()!;
}
