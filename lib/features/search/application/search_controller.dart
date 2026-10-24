import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playlists/data/playlist_repository.dart';
import 'package:noir/features/search/data/search_history_repository.dart';
import 'package:noir/shared/models/media.dart';

/// Results from the local library only. Provider (YouTube) search is a
/// separate, quota-limited source and is never mixed in silently.
class SearchResults {
  const SearchResults({
    required this.query,
    required this.tracks,
    required this.artists,
    required this.albums,
    required this.playlists,
  });

  final String query;
  final List<Track> tracks;
  final List<Artist> artists;
  final List<Album> albums;
  final List<Playlist> playlists;

  bool get isEmpty =>
      tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty;
}

class SearchState {
  const SearchState({
    this.query = '',
    this.results,
    this.searching = false,
    this.failed = false,
  });

  final String query;

  /// Latest completed results; kept while a newer query runs so the list
  /// does not flash. Null when nothing has been searched yet.
  final SearchResults? results;
  final bool searching;
  final bool failed;
}

final searchProvider = NotifierProvider<LibrarySearchController, SearchState>(
  LibrarySearchController.new,
);

final searchHistoryProvider = StreamProvider<List<String>>(
  (ref) => ref.watch(searchHistoryRepositoryProvider).watch(),
);

class LibrarySearchController extends Notifier<SearchState> {
  static const debounce = Duration(milliseconds: 250);

  Timer? _timer;
  int _generation = 0;

  @override
  SearchState build() {
    ref.onDispose(() => _timer?.cancel());
    return const SearchState();
  }

  /// Called on every keystroke; the query runs once typing pauses.
  void setQuery(String query) {
    _timer?.cancel();
    final q = query.trim();
    if (q.isEmpty) {
      _generation++;
      state = const SearchState();
      return;
    }
    state = SearchState(query: query, results: state.results, searching: true);
    _timer = Timer(debounce, () => unawaited(_run(q)));
  }

  /// Saves the query to local history (on submit or when a result is used).
  Future<void> commit() =>
      ref.read(searchHistoryRepositoryProvider).add(state.query);

  Future<void> _run(String q) async {
    final generation = ++_generation;
    try {
      final results = await _search(q);
      // Drop results of a query that has since been replaced.
      if (generation != _generation) return;
      state = SearchState(query: state.query, results: results);
    } on Object {
      if (generation != _generation) return;
      state = SearchState(query: state.query, failed: true);
    }
  }

  Future<SearchResults> _search(String q) async {
    final library = ref.read(libraryRepositoryProvider);
    final lower = q.toLowerCase();
    bool hit(String s) => s.toLowerCase().contains(lower);
    final (tracks, artists, albums, playlists) = await (
      library.searchTracks(q),
      library.watchArtists().first,
      library.watchAlbums().first,
      ref.read(playlistRepositoryProvider).watchPlaylists().first,
    ).wait;
    return SearchResults(
      query: q,
      tracks: tracks,
      artists: [
        for (final a in artists)
          if (hit(a.name)) a,
      ],
      albums: [
        for (final a in albums)
          if (hit(a.title) || hit(a.artist)) a,
      ],
      playlists: [
        for (final p in playlists)
          if (hit(p.name)) p,
      ],
    );
  }
}
