import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
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

/// The liked videos the Likes page shows: only music unless the user chose
/// "All likes" ([likesMusicOnlyProvider]).
final youTubeLikesProvider = StreamProvider<List<Track>>(
  (ref) => ref
      .watch(youTubeRepositoryProvider)
      .watchLikes(musicOnly: ref.watch(likesMusicOnlyProvider)),
);

/// Name of the Likes page for the current filter.
final youTubeLikesTitleProvider = Provider<String>(
  (ref) => ref.watch(likesMusicOnlyProvider) ? 'Liked music' : 'Liked videos',
);

final likesMusicOnlyProvider = NotifierProvider<LikesFilterController, bool>(
  LikesFilterController.new,
);

/// Whether the Likes page hides non-music videos (the default). The YouTube
/// Data API returns every liked video; see `isMusicVideo` for the heuristic.
/// Stored on this device.
class LikesFilterController extends Notifier<bool> {
  static const _key = 'youtube_likes_filter';

  bool _chosen = false;

  @override
  bool build() {
    unawaited(_load());
    return true;
  }

  void set({required bool musicOnly}) {
    _chosen = true;
    state = musicOnly;
    unawaited(
      ref.read(settingsRepositoryProvider).writeJson(_key, {
        'musicOnly': musicOnly,
      }),
    );
  }

  Future<void> _load() async {
    final json = await ref.read(settingsRepositoryProvider).readJson(_key);
    final saved = json?['musicOnly'];
    // A choice made while loading wins over the stored one.
    if (saved is bool && !_chosen && ref.mounted) state = saved;
  }
}

/// Opens a video or playlist in YouTube Music (attribution and fallback for
/// items the embedded player cannot play).
Uri youTubeMusicUrl({String? videoId, String? playlistId}) => videoId != null
    ? Uri.https('music.youtube.com', '/watch', {'v': videoId})
    : Uri.https('music.youtube.com', '/playlist', {'list': playlistId});
