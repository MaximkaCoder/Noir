import 'package:flutter/widgets.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/features/settings/domain/app_settings.dart';

/// Effective visual-effects configuration, combining the user's settings with
/// the system reduced-motion preference. Read via [NoirEffects.of].
@immutable
class EffectsConfig {
  const EffectsConfig({
    required this.glass,
    required this.blurSigma,
    required this.highlights,
    required this.ambient,
    required this.animations,
  });

  factory EffectsConfig.resolve(
    AppSettings settings, {
    required bool systemReducedMotion,
  }) {
    final performance = settings.performanceMode == PerformanceMode.performance;
    return EffectsConfig(
      glass: settings.liquidGlass,
      blurSigma: !settings.liquidGlass
          ? 0
          : performance
          ? NoirBlur.reduced
          : NoirBlur.full,
      highlights: settings.liquidGlass && !performance,
      ambient: settings.liquidGlass && !performance,
      animations: settings.animations && !systemReducedMotion,
    );
  }

  /// Translucent blurred surfaces vs. opaque solid ones.
  final bool glass;
  final double blurSigma;

  /// Specular edge highlights on glass.
  final bool highlights;

  /// Artwork-tinted background behind the shell.
  final bool ambient;

  /// Non-essential motion. Essential feedback stays regardless.
  final bool animations;

  /// [d] when animations are on, otherwise instant.
  Duration motion(Duration d) => animations ? d : Duration.zero;

  @override
  bool operator ==(Object other) =>
      other is EffectsConfig &&
      other.glass == glass &&
      other.blurSigma == blurSigma &&
      other.highlights == highlights &&
      other.ambient == ambient &&
      other.animations == animations;

  @override
  int get hashCode =>
      Object.hash(glass, blurSigma, highlights, ambient, animations);
}

class NoirEffects extends InheritedWidget {
  const NoirEffects({required this.config, required super.child, super.key});

  final EffectsConfig config;

  static EffectsConfig of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoirEffects>()?.config ??
      const EffectsConfig(
        glass: false,
        blurSigma: 0,
        highlights: false,
        ambient: false,
        animations: false,
      );

  @override
  bool updateShouldNotify(NoirEffects oldWidget) => config != oldWidget.config;
}
