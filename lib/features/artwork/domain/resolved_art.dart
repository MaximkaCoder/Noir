import 'package:flutter/foundation.dart';
import 'package:noir/features/artwork/domain/art_urls.dart';
import 'package:noir/features/lyrics/domain/song_guess.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

/// What NOIR found out about a YouTube video's artwork, plus the
/// YouTube Music metadata that came with it (byline links, video type).
@immutable
class ResolvedArt {
  const ResolvedArt({
    required this.squareBase,
    required this.checkedAt,
    this.links,
    this.videoType,
  });

  /// Nothing better than the video thumbnail was found.
  const ResolvedArt.none({required this.checkedAt, this.links, this.videoType})
    : squareBase = null;

  /// Square album art on googleusercontent, without its size suffix.
  final String? squareBase;

  /// When this was looked up; "nothing found" answers expire.
  final DateTime checkedAt;

  /// Where the artist and album names lead on YouTube Music; null when
  /// YouTube Music does not know the video.
  final YtmTrackLinks? links;

  /// `MUSIC_VIDEO_TYPE_ATV`, `_OMV`, `_UGC`, … as YouTube Music reports it.
  final String? videoType;

  /// No square art: show a crop of the video thumbnail.
  bool get isVideoThumb => squareBase == null;

  /// The square art sized for [px] physical pixels, if there is any.
  String? squareUrl(double px) {
    final base = squareBase;
    return base == null ? null : resizeGoogleArt('$base=s0', px);
  }

  Map<String, Object?> toJson() {
    final links = this.links;
    return {
      'b': squareBase,
      't': checkedAt.millisecondsSinceEpoch,
      'v': ?videoType,
      if (links != null) ...{
        'ar': [
          for (final a in links.artists) [a.name, a.browseId],
        ],
        if (links.album case final album?) 'al': [album.name, album.browseId],
      },
    };
  }

  static ResolvedArt? fromJson(Object? json) {
    if (json is! Map) return null;
    final base = json['b'];
    final t = json['t'];
    final v = json['v'];
    if (t is! int || (base != null && base is! String)) return null;
    final artists = json['ar'];
    return ResolvedArt(
      squareBase: base as String?,
      checkedAt: DateTime.fromMillisecondsSinceEpoch(t),
      videoType: v is String ? v : null,
      links: artists is! List
          ? null
          : YtmTrackLinks(
              artists: [for (final a in artists) ?_link(a)],
              album: _link(json['al']),
            ),
    );
  }

  static YtmLink? _link(Object? json) =>
      json is List && json.length == 2 && json[0] is String && json[1] is String
      ? (name: json[0] as String, browseId: json[1] as String)
      : null;

  @override
  bool operator ==(Object other) =>
      other is ResolvedArt &&
      other.squareBase == squareBase &&
      other.checkedAt == checkedAt &&
      other.links == links &&
      other.videoType == videoType;

  @override
  int get hashCode => Object.hash(squareBase, checkedAt, links, videoType);

  @override
  String toString() => 'ResolvedArt(${squareBase ?? 'video thumbnail'})';
}

/// Square art from a get_queue entry: its own (songs) or that of the song
/// twin YouTube Music pairs it with.
String? squareArtOf(YtmQueueEntry entry) {
  for (final url in [entry.thumbnailUrl, entry.counterpart?.thumbnailUrl]) {
    if (url != null && isGoogleArt(url)) return googleArtBase(url);
  }
  return null;
}

/// How far a song's length may differ from its video's.
const counterpartDurationTolerance = Duration(seconds: 5);

/// The allowance when the title and artist match almost exactly.
const counterpartExactMatchTolerance = Duration(seconds: 90);

/// What to search YouTube Music's songs for to find [video]'s audio twin:
/// the cleaned title and artist ("Artist - Song (Official Video)" →
/// `Song Artist`). Null when the title cleans to nothing.
String? counterpartQuery(YtmQueueEntry video) {
  final guess = songGuesses(
    title: video.title,
    artist: video.artist,
  ).firstOrNull;
  if (guess == null) return null;
  return [guess.title, ?guess.artist].join(' ');
}

/// Whether [song] (the top song search result) is the audio version of
/// [video]: lengths within [counterpartDurationTolerance], titles that
/// match once cleaned, and — when both are known — related artists.
bool acceptsCounterpart(YtmQueueEntry video, Track song) {
  final a = video.duration;
  final b = song.duration;
  if (a == null || b == null) return false;
  final guess = songGuesses(
    title: video.title,
    artist: video.artist,
  ).firstOrNull;
  if (guess == null) return false;
  final titleMatch = similarity(guess.title, cleanSongTitle(song.title));
  if (titleMatch < 0.8) return false;
  final videoArtist = guess.artist;
  final songArtist = song.artist;
  final artistMatch = videoArtist != null && songArtist != null
      ? similarity(videoArtist, songArtist)
      : null;
  if (artistMatch != null && artistMatch < 0.5) return false;
  // Music videos often run longer than the song (intros, skits), so a near
  // exact title and artist match may differ by up to a minute and a half.
  final exact = titleMatch >= 0.95 && (artistMatch ?? 0) >= 0.8;
  final tolerance = exact
      ? counterpartExactMatchTolerance
      : counterpartDurationTolerance;
  if ((a - b).abs() > tolerance) return false;
  final art = song.artworkUrl;
  return art != null && isGoogleArt(art);
}
