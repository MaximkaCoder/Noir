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

/// How Now Playing shows time-synced lyrics.
enum LyricsMode {
  /// The whole song as a list, the current line highlighted.
  lines,

  /// The current line large, filling word by word, with the next below.
  karaoke,
}

@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    @Default(ThemeMode.dark) ThemeMode themeMode,
    @Default(true) bool liquidGlass,

    /// How much Liquid Glass the floating surfaces show, 0–100: higher is
    /// clearer (less tint and frost) with more saturation and refraction.
    @Default(60) int glassLevel,
    @Default(true) bool animations,
    @Default(Density.comfortable) Density density,
    @Default(PerformanceMode.balanced) PerformanceMode performanceMode,

    /// 0 disables crossfade. Applies to local playback only.
    @Default(0) int crossfadeSeconds,
    @Default(0.8) double defaultVolume,
    @Default(true) bool resumeSession,
    @Default(PlayBehavior.playContext) PlayBehavior playBehavior,
    @Default(false) bool sidebarCollapsed,
    @JsonKey(unknownEnumValue: LyricsMode.lines)
    @Default(LyricsMode.lines)
    LyricsMode lyricsMode,

    /// Experimental, off by default: plays YouTube without a visible player
    /// and keeps playing when the window is hidden. This breaks YouTube API
    /// Services policies (III.I.7, III.I.9) and can get NOIR's API access
    /// revoked; it exists for personal testing only.
    @Default(false) bool hideYouTubePlayer,
  }) = _AppSettings;

  factory AppSettings.fromJson(Map<String, Object?> json) =>
      _$AppSettingsFromJson(json);
}
