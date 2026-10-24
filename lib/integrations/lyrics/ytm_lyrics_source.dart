import 'package:dio/dio.dart';
import 'package:noir/features/lyrics/domain/lrc.dart';
import 'package:noir/features/lyrics/domain/lyrics.dart';
import 'package:noir/features/lyrics/domain/song_guess.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_lyrics.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

/// Lyrics from YouTube Music, anonymously through [InnerTubeClient]: the
/// song's Lyrics tab, time-synced when YouTube Music has timings (with each
/// line's own end time), plain otherwise.
///
/// [YtmLyricsSource.byVideo] answers for YouTube tracks only, by their
/// video. [YtmLyricsSource.bySearch] answers for local files only: it looks
/// the song up in YouTube Music's song search (title, artist, and the
/// duration within [durationTolerance]) and uses that song's lyrics.
class YtmLyricsSource implements LyricsSource {
  YtmLyricsSource.byVideo(this._client) : _search = false;
  YtmLyricsSource.bySearch(this._client) : _search = true;

  final InnerTubeClient _client;
  final bool _search;

  static const name = 'YouTube Music';
  static const durationTolerance = Duration(seconds: 3);

  @override
  Future<Lyrics?> find(LyricsRequest request, {CancelToken? cancel}) async {
    try {
      final videoId = _search
          ? request.source == MediaSource.youtube
                ? null
                : await _searchSong(request)
          : request.videoId;
      if (videoId == null || (cancel?.isCancelled ?? false)) return null;
      final browseId = await _client.lyricsBrowseId(videoId);
      if (browseId == null || (cancel?.isCancelled ?? false)) return null;
      final lyrics = await _client.lyrics(browseId);
      return lyrics == null ? null : toLyrics(lyrics);
    } on InnerTubeException catch (e) {
      throw LyricsUnavailable(e);
    }
  }

  /// The video of the YouTube Music song most like [request], if one is
  /// close enough.
  Future<String?> _searchSong(LyricsRequest request) async {
    final guesses = songGuesses(title: request.title, artist: request.artist);
    if (guesses.isEmpty || guesses.first.artist == null) return null;
    final first = guesses.first;
    final page = await _client.search('${first.artist} ${first.title}');
    return pickSong(
      [
        for (final item in page.items)
          if (item is YtmTrackItem && !item.isVideo) item.track,
      ],
      guesses,
      request.duration,
    )?.uri;
  }

  /// The song in [songs] most like one of [guesses] and, when both are
  /// known, within [durationTolerance] of [duration].
  static Track? pickSong(
    List<Track> songs,
    List<SongGuess> guesses,
    Duration? duration,
  ) {
    Track? best;
    var bestScore = double.negativeInfinity;
    for (final song in songs) {
      final length = song.duration;
      if (duration != null &&
          length != null &&
          (length - duration).abs() > durationTolerance) {
        continue;
      }
      for (final g in guesses) {
        final titleScore = similarity(cleanSongTitle(song.title), g.title);
        if (titleScore < 0.6) continue;
        final artistScore = g.artist == null
            ? 0.5
            : similarity(song.artist ?? '', g.artist!);
        if (g.artist != null && artistScore < 0.4) continue;
        final score = 2 * titleScore + artistScore;
        if (score > bestScore) {
          bestScore = score;
          best = song;
        }
      }
    }
    return best;
  }

  /// "YouTube Music · Musixmatch" for attribution.
  static String sourceName(String? provider) =>
      provider == null ? name : '$name · $provider';

  static Lyrics? toLyrics(YtmLyrics lyrics) {
    final source = sourceName(lyrics.provider);
    final lines = lyrics.lines;
    if (lines != null && lines.any((l) => l.text.isNotEmpty)) {
      return SyncedLyrics([
        for (final l in lines)
          LyricLine(l.start, l.text, end: l.end > l.start ? l.end : null),
      ], source: source);
    }
    final text = lyrics.text;
    if (text != null && text.trim().isNotEmpty) {
      return PlainLyrics(text, source: source);
    }
    return null;
  }
}
