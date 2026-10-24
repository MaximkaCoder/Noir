import 'package:flutter/material.dart' show ThemeMode;
import 'package:freezed_annotation/freezed_annotation.dart';

part 'app_settings.freezed.dart';
part 'app_settings.g.dart';

enum Density { comfortable, compact }

/// Performance trades blur strength and decorative motion for lower GPU use.
enum PerformanceMode { balanced, performance }

/// What happens when the user plays one track from a list.
enum PlayBehavior {
  /// Replace the queue with the whole list, starting at the chosen track.
  playContext,

  /// Replace the queue with only the chosen track.
  playSingle,
}

@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    @Default(ThemeMode.dark) ThemeMode themeMode,
    @Default(true) bool liquidGlass,
    @Default(true) bool animations,
    @Default(Density.comfortable) Density density,
    @Default(PerformanceMode.balanced) PerformanceMode performanceMode,

    /// 0 disables crossfade. Applies to local playback only.
    @Default(0) int crossfadeSeconds,
    @Default(0.8) double defaultVolume,
    @Default(true) bool resumeSession,
    @Default(PlayBehavior.playContext) PlayBehavior playBehavior,
    @Default(false) bool sidebarCollapsed,
  }) = _AppSettings;

  factory AppSettings.fromJson(Map<String, Object?> json) =>
      _$AppSettingsFromJson(json);
}
