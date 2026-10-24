import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/playlists/data/playlist_repository.dart';
import 'package:noir/shared/models/media.dart';

final playlistsProvider = StreamProvider<List<Playlist>>(
  (ref) => ref.watch(playlistRepositoryProvider).watchPlaylists(),
);

final playlistProvider = StreamProvider.family<Playlist?, int>(
  (ref, id) => ref.watch(playlistRepositoryProvider).watchPlaylist(id),
);

final playlistTracksProvider = StreamProvider.family<List<PlaylistTrack>, int>(
  (ref, id) => ref.watch(playlistRepositoryProvider).watchTracks(id),
);
