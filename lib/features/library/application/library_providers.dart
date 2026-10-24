import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/features/home/data/history_repository.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/shared/models/media.dart';

final tracksProvider = StreamProvider.family<List<Track>, TrackSort>(
  (ref, sort) => ref.watch(libraryRepositoryProvider).watchTracks(sort: sort),
);

final favoritesProvider = StreamProvider<List<Track>>(
  (ref) => ref.watch(libraryRepositoryProvider).watchFavorites(),
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
