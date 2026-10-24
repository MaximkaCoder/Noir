import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';

/// YouTube Music results shown under the local ones on the Search page.
/// Anonymous InnerTube requests: no account, no API quota.
@immutable
class MusicSearchState {
  const MusicSearchState({
    this.query = '',
    this.filter = YtmSearchFilter.songs,
    this.items = const [],
    this.resultsFor,
    this.continuation,
    this.loading = false,
    this.error,
  });

  /// The query as typed (trimmed).
  final String query;
  final YtmSearchFilter filter;

  /// Results of the last completed search; kept while a newer one runs so
  /// the list does not flash.
  final List<YtmItem> items;

  /// Query and filter [items] belong to; null before the first search.
  final ({String query, YtmSearchFilter filter})? resultsFor;
  final String? continuation;
  final bool loading;

  /// User-facing reason the last search failed.
  final String? error;

  bool get hasMore => continuation != null;

  /// Whether [items] answer the current query and filter.
  bool get isCurrent => resultsFor == (query: query, filter: filter);
}

final musicSearchControllerProvider =
    NotifierProvider<MusicSearchController, MusicSearchState>(
      MusicSearchController.new,
    );

class MusicSearchController extends Notifier<MusicSearchState> {
  static const debounce = Duration(milliseconds: 400);

  Timer? _timer;

  /// Bumped by every search so results of a replaced one are dropped.
  int _generation = 0;
  bool _loadingMore = false;

  @override
  MusicSearchState build() {
    ref.onDispose(() => _timer?.cancel());
    return const MusicSearchState();
  }

  /// Called on every keystroke; the search runs once typing pauses for
  /// [debounce].
  void setQuery(String query) {
    final q = query.trim();
    if (q == state.query) return;
    _timer?.cancel();
    if (q.isEmpty) {
      _generation++;
      state = MusicSearchState(filter: state.filter);
      return;
    }
    state = _copy(query: q, loading: true);
    _timer = Timer(debounce, () => unawaited(_run()));
  }

  /// Searches right away (Enter, a history entry, an artist tile).
  Future<void> submit([String? query]) {
    _timer?.cancel();
    if (query != null && query.trim() != state.query) {
      state = _copy(query: query.trim());
    }
    if (state.query.isEmpty) return Future.value();
    if (state.isCurrent && state.error == null && !state.loading) {
      return Future.value();
    }
    return _run();
  }

  void setFilter(YtmSearchFilter filter) {
    if (filter == state.filter) return;
    _timer?.cancel();
    state = _copy(filter: filter);
    if (state.query.isNotEmpty) unawaited(_run());
  }

  /// Appends the next page. Returns false when there is nothing more, a
  /// page is already loading, or the request failed.
  Future<bool> loadMore() async {
    final token = state.continuation;
    if (token == null || _loadingMore || !state.isCurrent) return false;
    _loadingMore = true;
    final generation = _generation;
    try {
      final page = await ref.read(innerTubeClientProvider).searchMore(token);
      if (!ref.mounted || generation != _generation) return false;
      state = MusicSearchState(
        query: state.query,
        filter: state.filter,
        items: [...state.items, ...page.items],
        resultsFor: state.resultsFor,
        continuation: page.continuation,
      );
      return true;
    } on InnerTubeException {
      return false;
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _run() async {
    final q = (query: state.query, filter: state.filter);
    final generation = ++_generation;
    state = _copy(loading: true, error: null);
    try {
      final page = await ref.read(musicSearchProvider(q).future);
      if (!ref.mounted || generation != _generation) return;
      state = MusicSearchState(
        query: q.query,
        filter: q.filter,
        items: page.items,
        resultsFor: q,
        continuation: page.continuation,
      );
    } on Object catch (e) {
      if (!ref.mounted) return;
      // Don't keep the failure cached: "Try again" must really try again.
      ref.invalidate(musicSearchProvider(q));
      if (generation != _generation) return;
      state = _copy(
        loading: false,
        error: e is InnerTubeException
            ? e.message
            : "YouTube Music couldn't be searched.",
      );
    }
  }

  static const _keep = Object();

  MusicSearchState _copy({
    String? query,
    YtmSearchFilter? filter,
    bool? loading,
    Object? error = _keep,
  }) => MusicSearchState(
    query: query ?? state.query,
    filter: filter ?? state.filter,
    items: state.items,
    resultsFor: state.resultsFor,
    continuation: state.continuation,
    loading: loading ?? state.loading,
    error: identical(error, _keep) ? state.error : error as String?,
  );
}
