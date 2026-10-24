import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/lyrics/domain/lyrics.dart';
import 'package:noir/integrations/lyrics/lrclib_client.dart';
import 'package:noir/integrations/lyrics/lrclib_source.dart';

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

/// Lyrics services, tried in order.
final lyricsSourcesProvider = Provider<List<LyricsSource>>(
  (ref) => [LrclibLyricsSource(LrclibClient(ref.watch(httpClientProvider)))],
);

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
    for (final source in _sources) {
      try {
        final lyrics = await source.find(request, cancel: cancel);
        if (lyrics != null) return _remember(request, lyrics);
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) rethrow;
        failure ??= e;
      }
    }
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
