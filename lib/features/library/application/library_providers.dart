import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/features/home/data/history_repository.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/shared/models/media.dart';

final tracksProvider = StreamProvider.family<List<Track>, TrackSort>(
  (ref, sort) => ref.watch(libraryRepositoryProvider).watchTracks(sort: sort),
);

/// Hearted local files and songs from YouTube Music, by title. Combined
/// without a reload, so a new heart doesn't flash a loading page.
final favoritesProvider = Provider<AsyncValue<List<Track>>>((ref) {
  final songs = ref.watch(favoriteSongsProvider);
  final files = ref.watch(_favoriteFilesProvider);
  for (final part in [songs, files]) {
    if (part case AsyncError(:final error, :final stackTrace)) {
      return AsyncError(error, stackTrace);
    }
  }
  final (s, f) = (songs.value, files.value);
  if (s == null || f == null) return const AsyncLoading();
  return AsyncData(
    [...s, ...f]
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())),
  );
});

final _favoriteFilesProvider = StreamProvider<List<Track>>(
  (ref) => ref.watch(libraryRepositoryProvider).watchFavorites(),
);

/// Hearted songs that aren't local files, kept on this device.
final favoriteSongsProvider = StreamProvider<List<Track>>(
  (ref) => ref.watch(libraryRepositoryProvider).watchFavoriteSongs(),
);

/// Whether the song with this `Track.id` is in [favoriteSongsProvider].
final isFavoriteSongProvider = Provider.family<bool, String>(
  (ref, id) => ref.watch(
    favoriteSongsProvider.select(
      (songs) => songs.value?.any((t) => t.id == id) ?? false,
    ),
  ),
);

final albumsProvider = StreamProvider<List<Album>>(
  (ref) => ref.watch(libraryRepositoryProvider).watchAlbums(),
);

final artistsProvider = StreamProvider<List<Artist>>(
  (ref) => ref.watch(libraryRepositoryProvider).watchArtists(),
);

final trackCountProvider = StreamProvider<int>(
  (ref) => ref.watch(libraryRepositoryProvider).watchTrackCount(),
);

final libraryFoldersProvider = StreamProvider<List<LibraryFolder>>(
  (ref) => ref.watch(libraryRepositoryProvider).watchFolders(),
);

final recentTracksProvider = StreamProvider<List<Track>>(
  (ref) => ref.watch(historyRepositoryProvider).watchRecentTracks(),
);
