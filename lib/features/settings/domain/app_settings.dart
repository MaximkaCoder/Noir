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

/// How one track hands over to the next on NOIR's own player.
enum TransitionMode {
  /// Each track plays to its end, then the next starts.
  off,

  /// A plain crossfade of [AppSettings.crossfadeSeconds].
  crossfade,

  /// Planned from the tracks' analyses: beat-matched blends, gapless album
  /// tracks, vocal-aware timing.
  smart,

  /// Like a DJ set: each track plays a few minutes and hands over on a
  /// drop.
  disco,
}

/// Where the edge player docks on Windows: a small player that comes out
/// from behind the screen edge while NOIR is minimized.
enum EdgePlayerSide { left, right, top, bottom }

@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    @Default(ThemeMode.dark) ThemeMode themeMode,
    @Default(true) bool liquidGlass,

    /// How much Liquid Glass the floating surfaces show, 0–100: higher is
    /// clearer (less tint and frost) with more saturation and refraction.
    @Default(70) int glassLevel,
    @Default(true) bool animations,
    @Default(Density.comfortable) Density density,
    @Default(PerformanceMode.balanced) PerformanceMode performanceMode,

    /// Transitions apply to tracks played through NOIR's own player
    /// (local files and cached audio).
    @JsonKey(unknownEnumValue: TransitionMode.off)
    @Default(TransitionMode.off)
    TransitionMode transitionMode,

    /// Length of a plain crossfade, 1–12 s.
    @Default(6) int crossfadeSeconds,

    /// The last volume set, restored at startup.
    @Default(0.8) double volume,
    @Default(true) bool resumeSession,
    @Default(PlayBehavior.playContext) PlayBehavior playBehavior,
    @Default(false) bool sidebarCollapsed,
    @JsonKey(unknownEnumValue: LyricsMode.lines)
    @Default(LyricsMode.lines)
    LyricsMode lyricsMode,

    /// The Windows edge player is on.
    @Default(true) bool edgePlayerEnabled,

    /// The edge player shows in screenshots and screen sharing. Then it
    /// can't see the screen behind it, so its glass is the flowing artwork
    /// alone instead of the blurred screen too.
    @Default(false) bool edgePlayerCapturable,

    /// The edge it is docked to; set by dragging it.
    @JsonKey(unknownEnumValue: EdgePlayerSide.right)
    @Default(EdgePlayerSide.right)
    EdgePlayerSide edgePlayer,

    /// Where the edge player's middle was last dropped, in physical screen
    /// pixels: it docks to that monitor there. Unset: the primary monitor,
    /// centered.
    int? edgePlayerX,
    int? edgePlayerY,

    /// Plays YouTube without a visible player and keeps playing when the
    /// window is hidden (owner decision; YouTube API Services policies
    /// III.I.7 and III.I.9 ask for a visible player). Always on: not stored
    /// and not offered in Settings; tests may turn it off.
    @JsonKey(includeFromJson: false, includeToJson: false)
    @Default(true)
    bool hideYouTubePlayer,
  }) = _AppSettings;

  factory AppSettings.fromJson(Map<String, Object?> json) =>
      _$AppSettingsFromJson(json);
}
