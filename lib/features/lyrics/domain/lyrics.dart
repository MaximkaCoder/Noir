import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:noir/features/lyrics/domain/lrc.dart';
import 'package:noir/shared/models/media.dart';

/// Lyrics for one track, with the service they came from (for attribution).
sealed class Lyrics {
  const Lyrics({required this.source});

  /// Human-readable service name, e.g. "LRCLIB".
  final String source;
}

final class SyncedLyrics extends Lyrics {
  const SyncedLyrics(this.lines, {required super.source});

  final List<LyricLine> lines;
}

/// Lyrics without timestamps.
final class PlainLyrics extends Lyrics {
  const PlainLyrics(this.text, {required super.source});

  final String text;
}

final class InstrumentalLyrics extends Lyrics {
  const InstrumentalLyrics({required super.source});
}

/// What lyrics services get to know about a track. Also the cache key, so
/// it ignores fields that don't affect the lookup (e.g. favorite state).
@immutable
class LyricsRequest {
  const LyricsRequest({
    required this.id,
    required this.source,
    required this.title,
    this.artist,
    this.album,
    this.duration,
  });

  factory LyricsRequest.fromTrack(Track track) => LyricsRequest(
    id: track.id,
    source: track.source,
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration: track.duration,
  );

  final String id;
  final MediaSource source;
  final String title;

  /// Tag artist, or the channel name for YouTube videos.
  final String? artist;
  final String? album;
  final Duration? duration;

  @override
  bool operator ==(Object other) =>
      other is LyricsRequest &&
      other.id == id &&
      other.source == source &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(id, source, title, artist, album, duration);
}

/// A lyrics service. Returns null when it has nothing for the track; throws
/// on network or server errors.
abstract interface class LyricsSource {
  Future<Lyrics?> find(LyricsRequest request, {CancelToken? cancel});
}

/// No source could be reached; lookups that merely found nothing don't
/// throw.
class LyricsUnavailable implements Exception {
  const LyricsUnavailable(this.cause);

  final Object cause;

  @override
  String toString() => 'LyricsUnavailable($cause)';
}
