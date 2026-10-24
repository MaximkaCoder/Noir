import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/shared/models/media.dart';

final youTubePlaylistsProvider = StreamProvider<List<YouTubePlaylist>>(
  (ref) => ref.watch(youTubeRepositoryProvider).watchPlaylists(),
);

final youTubePlaylistProvider = StreamProvider.family<YouTubePlaylist?, String>(
  (ref, id) => ref.watch(youTubeRepositoryProvider).watchPlaylist(id),
);

final youTubePlaylistTracksProvider =
    StreamProvider.family<List<Track>, String>(
      (ref, id) => ref.watch(youTubeRepositoryProvider).watchPlaylistTracks(id),
    );

final youTubeLikesProvider = StreamProvider<List<Track>>(
  (ref) => ref.watch(youTubeRepositoryProvider).watchLikes(),
);

/// Opens a video or playlist in YouTube Music (attribution and fallback for
/// items the embedded player cannot play).
Uri youTubeMusicUrl({String? videoId, String? playlistId}) => videoId != null
    ? Uri.https('music.youtube.com', '/watch', {'v': videoId})
    : Uri.https('music.youtube.com', '/playlist', {'list': playlistId});
