import 'package:dio/dio.dart';
import 'package:noir/features/lyrics/domain/lrc.dart';
import 'package:noir/features/lyrics/domain/lyrics.dart';
import 'package:noir/features/lyrics/domain/song_guess.dart';
import 'package:noir/integrations/lyrics/lrclib_client.dart';
import 'package:noir/shared/models/media.dart';

/// Looks a track up on LRCLIB: exact `/get` for the best guesses, then
/// `/search`, keeping only results within [durationTolerance].
///
/// At most four requests per track.
class LrclibLyricsSource implements LyricsSource {
  LrclibLyricsSource(this._client);

  final LrclibClient _client;

  static const name = 'LRCLIB';
  static const durationTolerance = Duration(seconds: 10);

  @override
  Future<Lyrics?> find(LyricsRequest request, {CancelToken? cancel}) async {
    final guesses = songGuesses(title: request.title, artist: request.artist);
    if (guesses.isEmpty) return null;

    // 1. Exact lookups. `/get` may query upstream services and answer 503
    // when busy; that only means "unknown", so search still runs.
    for (final g in guesses.where((g) => g.artist != null).take(2)) {
      try {
        final record = await _client.get(
          trackName: g.title,
          artistName: g.artist!,
          albumName: request.source == MediaSource.local ? request.album : null,
          duration: request.duration,
          cancel: cancel,
        );
        if (record != null && _durationOk(record, request.duration)) {
          final lyrics = toLyrics(record);
          if (lyrics != null) return lyrics;
        }
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) rethrow;
      }
    }

    // 2. Search. Errors here mean LRCLIB is unreachable.
    final first = guesses.first;
    var results = first.artist == null
        ? const <LrclibRecord>[]
        : await _client.search(
            trackName: first.title,
            artistName: first.artist,
            cancel: cancel,
          );
    var best = pickBest(results, guesses, request.duration);
    if (best == null) {
      results = await _client.search(
        query: [?first.artist, first.title].join(' '),
        cancel: cancel,
      );
      best = pickBest(results, guesses, request.duration);
    }
    return best == null ? null : toLyrics(best);
  }

  static bool _durationOk(LrclibRecord r, Duration? expected) =>
      expected == null ||
      r.duration == null ||
      (r.duration! - expected).abs() <= durationTolerance;

  /// The record most like one of [guesses], or null when none is close
  /// enough. Synced lyrics win ties.
  static LrclibRecord? pickBest(
    List<LrclibRecord> records,
    List<SongGuess> guesses,
    Duration? duration,
  ) {
    LrclibRecord? best;
    var bestScore = double.negativeInfinity;
    for (final r in records) {
      if (!r.hasContent || !_durationOk(r, duration)) continue;
      final title = cleanSongTitle(r.trackName);
      for (final g in guesses) {
        final titleScore = similarity(title, g.title);
        if (titleScore < 0.5) continue;
        final artistScore = g.artist == null
            ? 0.5
            : similarity(r.artistName, g.artist!);
        if (g.artist != null && artistScore < 0.3) continue;
        final off = duration == null || r.duration == null
            ? 5.0
            : (r.duration! - duration).abs().inMilliseconds / 1000;
        final score =
            2 * titleScore +
            artistScore +
            (r.syncedLyrics != null ? 0.5 : 0) -
            off / 10;
        if (score > bestScore) {
          bestScore = score;
          best = r;
        }
      }
    }
    return best;
  }

  static Lyrics? toLyrics(LrclibRecord r) {
    if (r.instrumental) return const InstrumentalLyrics(source: name);
    final synced = r.syncedLyrics == null
        ? const <LyricLine>[]
        : parseLrc(r.syncedLyrics!);
    if (synced.any((l) => l.text.isNotEmpty)) {
      return SyncedLyrics(synced, source: name);
    }
    if (r.plainLyrics != null) return PlainLyrics(r.plainLyrics!, source: name);
    return null;
  }
}
