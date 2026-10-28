import 'package:flutter/foundation.dart';

/// What the edge player shows, sent from the app to the edge player's own
/// engine through the Windows runner (windows/runner/edge_player.cpp).
@immutable
class EdgeSnapshot {
  const EdgeSnapshot({
    required this.side,
    this.visible = false,
    this.title = '',
    this.artist = '',
    this.artwork = '',
    this.playing = false,
    this.canPrevious = false,
    this.canNext = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.at,
    this.volume = 1,
    this.canLike = false,
    this.liked = false,
    this.anchorX,
    this.anchorY,
    this.capturable = false,
  });

  factory EdgeSnapshot.fromMap(Map<Object?, Object?> map) => EdgeSnapshot(
    side: map['side'] as String? ?? 'off',
    visible: map['visible'] as bool? ?? false,
    title: map['title'] as String? ?? '',
    artist: map['artist'] as String? ?? '',
    artwork: map['artwork'] as String? ?? '',
    playing: map['playing'] as bool? ?? false,
    canPrevious: map['canPrevious'] as bool? ?? false,
    canNext: map['canNext'] as bool? ?? false,
    position: Duration(milliseconds: map['positionMs'] as int? ?? 0),
    duration: Duration(milliseconds: map['durationMs'] as int? ?? 0),
    at: switch (map['atMs']) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      _ => null,
    },
    volume: (map['volume'] as num? ?? 1).toDouble(),
    canLike: map['canLike'] as bool? ?? false,
    liked: map['liked'] as bool? ?? false,
    anchorX: map['anchorX'] as int?,
    anchorY: map['anchorY'] as int?,
    capturable: map['capturable'] as bool? ?? false,
  );

  /// "left", "right", or "off" (no edge player).
  final String side;

  /// NOIR is minimized and something is loaded; otherwise the player slides
  /// away.
  final bool visible;
  final String title;
  final String artist;

  /// An https image or a local file path; empty when there is none.
  final String artwork;
  final bool playing;
  final bool canPrevious;
  final bool canNext;

  /// The position at [at]; while [playing] it moves on from there.
  final Duration position;
  final Duration duration;
  final DateTime? at;
  final double volume;
  final bool canLike;
  final bool liked;

  /// Where the player was last dropped, physical screen pixels.
  final int? anchorX;
  final int? anchorY;

  /// Shown in screenshots and screen sharing; then the runner sends no
  /// picture of the screen behind it.
  final bool capturable;

  /// The position now, moved on from [position] while playing.
  Duration positionAt(DateTime now) {
    final at = this.at;
    final moved = playing && at != null
        ? position + now.difference(at)
        : position;
    if (duration <= Duration.zero) return moved;
    return moved > duration ? duration : moved;
  }

  Map<String, Object?> toMap() => {
    'side': side,
    'visible': visible,
    'title': title,
    'artist': artist,
    'artwork': artwork,
    'playing': playing,
    'canPrevious': canPrevious,
    'canNext': canNext,
    'positionMs': position.inMilliseconds,
    'durationMs': duration.inMilliseconds,
    'atMs': at?.millisecondsSinceEpoch,
    'volume': volume,
    'canLike': canLike,
    'liked': liked,
    'anchorX': anchorX,
    'anchorY': anchorY,
    'capturable': capturable,
  };
}

/// What the edge player asks the app to do.
enum EdgeCommand { playPause, previous, next, seek, volume, like, open }
