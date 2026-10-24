import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';

/// Anonymous YouTube Music client for discovery.
///
/// It gets its own Dio instead of `httpClientProvider`: these requests must
/// never pass through a client that could one day carry the user's Google
/// credentials (interceptors, cookie jars).
final innerTubeClientProvider = Provider<InnerTubeClient>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );
  ref.onDispose(dio.close);
  return InnerTubeClient(dio: dio);
});

/// The client already retries transient failures with backoff; Riverpod's
/// automatic retry on top would hammer YouTube Music.
Duration? _noRetry(int retryCount, Object error) => null;

/// Keeps an auto-dispose provider's value for [duration] after its last
/// listener leaves.
void _cacheFor(Ref ref, Duration duration) {
  final link = ref.keepAlive();
  final timer = Timer(duration, link.close);
  ref.onDispose(timer.cancel);
}

// ----------------------------------------------------------------- home --

@immutable
class HomeFeed {
  const HomeFeed({
    required this.shelves,
    required this.fetchedAt,
    this.chips = const [],
    this.chipParams,
    this.continuation,
  });

  final List<YtmShelf> shelves;

  /// Mood chips from the first page.
  final List<YtmChip> chips;

  /// The selected chip, null for the plain home feed.
  final String? chipParams;
  final String? continuation;
  final DateTime fetchedAt;

  bool get hasMore => continuation != null;

  HomeFeed _append(YtmHomePage page) => HomeFeed(
    shelves: [...shelves, ...page.shelves],
    chips: chips,
    chipParams: chipParams,
    continuation: page.continuation,
    fetchedAt: fetchedAt,
  );
}

final homeFeedProvider = AsyncNotifierProvider<HomeFeedController, HomeFeed>(
  HomeFeedController.new,
  retry: _noRetry,
);

/// YouTube Music's anonymous home feed, kept in memory and reused for
/// [maxAge].
class HomeFeedController extends AsyncNotifier<HomeFeed> {
  static const maxAge = Duration(minutes: 30);

  /// Bumped by every reload so stale results (an older reload or a
  /// loadMore that started before it) are dropped.
  int _generation = 0;
  bool _loadingMore = false;

  @override
  Future<HomeFeed> build() => _fetch(null);

  /// Reloads the feed when it is older than [maxAge], or always with
  /// [force]. If it fails while a feed is shown, that feed stays and the
  /// [InnerTubeException] is rethrown for the caller to report.
  Future<void> refresh({bool force = false}) {
    final current = state.value;
    if (!force &&
        current != null &&
        DateTime.now().difference(current.fetchedAt) < maxAge) {
      return Future.value();
    }
    return _reload(current?.chipParams);
  }

  /// Switches to a mood chip ([YtmChip.params]); null returns to the plain
  /// feed.
  Future<void> selectChip(String? params) => _reload(params);

  /// Appends the next page of shelves. Returns false when there is nothing
  /// more, a page is already loading, or the request failed.
  Future<bool> loadMore() async {
    final current = state.value;
    final token = current?.continuation;
    if (current == null || token == null || _loadingMore) return false;
    _loadingMore = true;
    final generation = _generation;
    try {
      final page = await ref.read(innerTubeClientProvider).homeMore(token);
      if (!ref.mounted || generation != _generation) return false;
      state = AsyncData(current._append(page));
      return true;
    } on InnerTubeException {
      return false;
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _reload(String? params) async {
    final generation = ++_generation;
    try {
      final feed = await _fetch(params);
      if (ref.mounted && generation == _generation) state = AsyncData(feed);
    } on InnerTubeException catch (e, stack) {
      if (!ref.mounted || generation != _generation) return;
      if (state.value != null) rethrow;
      state = AsyncError(e, stack);
    }
  }

  Future<HomeFeed> _fetch(String? params) async {
    final page = await ref.read(innerTubeClientProvider).home(params: params);
    return HomeFeed(
      shelves: page.shelves,
      chips: page.chips,
      chipParams: params,
      continuation: page.continuation,
      fetchedAt: DateTime.now(),
    );
  }
}

// ---------------------------------------------------------------- radio --

final radioProvider = AsyncNotifierProvider.autoDispose
    .family<RadioController, YtmTrackPage, String>(
      RadioController.new,
      retry: _noRetry,
    );

/// Endless radio seeded by a video id: the first page, then [loadMore]
/// appends further tracks (duplicates dropped).
class RadioController extends AsyncNotifier<YtmTrackPage> {
  RadioController(this.videoId);

  final String videoId;
  bool _loadingMore = false;

  @override
  Future<YtmTrackPage> build() {
    _cacheFor(ref, const Duration(minutes: 10));
    return ref.read(innerTubeClientProvider).radio(videoId);
  }

  /// Returns false when there is nothing more, a page is already loading,
  /// or the request failed.
  Future<bool> loadMore() async {
    final current = state.value;
    final token = current?.continuation;
    if (current == null || token == null || _loadingMore) return false;
    _loadingMore = true;
    try {
      final page = await ref
          .read(innerTubeClientProvider)
          .radioMore(token, playlistId: current.playlistId);
      if (!ref.mounted) return false;
      final seen = {for (final t in current.tracks) t.uri};
      state = AsyncData(
        YtmTrackPage(
          tracks: [
            ...current.tracks,
            ...page.tracks.where((t) => seen.add(t.uri)),
          ],
          continuation: page.continuation,
          playlistId: page.playlistId ?? current.playlistId,
        ),
      );
      return true;
    } on InnerTubeException {
      return false;
    } finally {
      _loadingMore = false;
    }
  }
}

// --------------------------------------------------------------- search --

typedef MusicSearchQuery = ({String query, YtmSearchFilter filter});

/// First page of YouTube Music results for a query and filter.
final musicSearchProvider = FutureProvider.autoDispose
    .family<YtmSearchPage, MusicSearchQuery>((ref, q) {
      if (q.query.trim().isEmpty) {
        return const YtmSearchPage(items: []);
      }
      _cacheFor(ref, const Duration(minutes: 5));
      return ref
          .read(innerTubeClientProvider)
          .search(q.query.trim(), filter: q.filter);
    }, retry: _noRetry);

final musicSearchSuggestionsProvider = FutureProvider.autoDispose
    .family<YtmSearchSuggestions, String>((ref, query) {
      if (query.trim().isEmpty) {
        return const YtmSearchSuggestions(queries: []);
      }
      _cacheFor(ref, const Duration(minutes: 5));
      return ref.read(innerTubeClientProvider).searchSuggestions(query);
    }, retry: _noRetry);

// ---------------------------------------------------------- collections --

/// A playlist opened from a shelf or search ([YtmPlaylistItem.playlistId]).
final ytmPlaylistProvider = FutureProvider.autoDispose
    .family<YtmCollection, String>((ref, playlistId) {
      _cacheFor(ref, const Duration(minutes: 10));
      return ref.read(innerTubeClientProvider).playlist(playlistId);
    }, retry: _noRetry);

/// An album opened from a shelf or search ([YtmAlbumItem.browseId]).
final ytmAlbumProvider = FutureProvider.autoDispose
    .family<YtmCollection, String>((ref, browseId) {
      _cacheFor(ref, const Duration(minutes: 10));
      return ref.read(innerTubeClientProvider).album(browseId);
    }, retry: _noRetry);
