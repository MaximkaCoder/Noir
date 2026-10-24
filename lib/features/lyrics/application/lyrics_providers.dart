import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/lyrics/domain/lyrics.dart';
import 'package:noir/integrations/lyrics/lrclib_client.dart';
import 'package:noir/integrations/lyrics/lrclib_source.dart';
import 'package:noir/integrations/lyrics/ytm_lyrics_source.dart';

/// Whether Now Playing shows lyrics. In memory only; off at launch.
final lyricsVisibleProvider = NotifierProvider<LyricsVisible, bool>(
  LyricsVisible.new,
);

class LyricsVisible extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  // A method reads better than a setter at call sites.
  // ignore: use_setters_to_change_properties
  void set({required bool visible}) => state = visible;
}

/// Lyrics services, in order of preference ([LyricsRepository]). YouTube
/// tracks ask YouTube Music first, by their video; local files ask LRCLIB
/// first and YouTube Music's song search only if that has no timed lyrics.
final lyricsSourcesProvider = Provider<List<LyricsSource>>((ref) {
  final ytm = ref.watch(innerTubeClientProvider);
  return [
    YtmLyricsSource.byVideo(ytm),
    LrclibLyricsSource(LrclibClient(ref.watch(httpClientProvider))),
    YtmLyricsSource.bySearch(ytm),
  ];
});

final lyricsRepositoryProvider = Provider<LyricsRepository>(
  (ref) => LyricsRepository(ref.watch(lyricsSourcesProvider)),
);

/// Lyrics for one track; null when no service has any. Only fetched while
/// something shows lyrics, and cancelled when it stops (e.g. track change).
final lyricsProvider = FutureProvider.autoDispose
    .family<Lyrics?, LyricsRequest>(
      (ref, request) {
        final cancel = CancelToken();
        ref.onDispose(cancel.cancel);
        return ref
            .watch(lyricsRepositoryProvider)
            .find(request, cancel: cancel);
      },
      // Errors offer a Retry button instead of hammering the service.
      retry: (_, _) => null,
    );

/// Asks each source in turn and remembers the answers (including "none")
/// for the last [capacity] tracks. Errors are not remembered.
///
/// Time-synced lyrics (or "instrumental") end the search at once; plain
/// lyrics are kept while later sources get a chance to answer with timed
/// ones, and are the answer if none does.
class LyricsRepository {
  LyricsRepository(this._sources, {this.capacity = 50});

  final List<LyricsSource> _sources;
  final int capacity;
  final _cache = <LyricsRequest, Lyrics?>{}; // Insertion-ordered.

  Future<Lyrics?> find(LyricsRequest request, {CancelToken? cancel}) async {
    if (_cache.containsKey(request)) {
      // Re-insert to mark as most recently used.
      return _cache[request] = _cache.remove(request);
    }
    Object? failure;
    PlainLyrics? plain;
    for (final source in _sources) {
      try {
        final lyrics = await source.find(request, cancel: cancel);
        if (lyrics is PlainLyrics) {
          plain ??= lyrics;
        } else if (lyrics != null) {
          return _remember(request, lyrics);
        }
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) rethrow;
        failure ??= e;
      } on LyricsUnavailable catch (e) {
        failure ??= e.cause;
      }
      if (cancel?.isCancelled ?? false) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(),
          reason: 'cancelled',
        );
      }
    }
    if (plain != null) return _remember(request, plain);
    if (failure != null) throw LyricsUnavailable(failure);
    return _remember(request, null);
  }

  Lyrics? _remember(LyricsRequest request, Lyrics? lyrics) {
    _cache[request] = lyrics;
    while (_cache.length > capacity) {
      _cache.remove(_cache.keys.first);
    }
    return lyrics;
  }
}
