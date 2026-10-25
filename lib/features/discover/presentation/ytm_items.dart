import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/menus.dart';
import 'package:noir/features/discover/presentation/ytm_artist_screen.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/search/application/music_search_controller.dart';
import 'package:noir/features/search/application/search_controller.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/widgets/media_tiles.dart';

/// "Artist", "Album · Daft Punk · 2013", … under a YouTube Music item.
String ytmSubtitle(YtmItem item) => switch (item) {
  YtmTrackItem(:final track, :final isVideo) =>
    isVideo ? 'Video · ${track.artistOrUnknown}' : track.artistOrUnknown,
  YtmAlbumItem(:final albumType, :final artist, :final year) => [
    albumType ?? 'Album',
    ?artist,
    if (year != null) '$year',
  ].join(' · '),
  YtmPlaylistItem(:final subtitle) => subtitle ?? 'Playlist',
  YtmArtistItem(:final subtitle) => subtitle ?? 'Artist',
};

/// Artwork for a YouTube Music item: round for artists.
Widget ytmArtwork(YtmItem item, double size) => switch (item) {
  YtmArtistItem() => artistAvatar(item.thumbnailUrl, size),
  YtmPlaylistItem() => Artwork(
    path: item.thumbnailUrl,
    size: size,
    icon: Icons.queue_music_rounded,
  ),
  YtmAlbumItem() => Artwork(
    path: item.thumbnailUrl,
    size: size,
    icon: Icons.album_outlined,
  ),
  YtmTrackItem() => Artwork(path: item.thumbnailUrl, size: size),
};

/// Opens [item]: songs and videos play together with the other songs in
/// [siblings] (a shelf or result list), or with [radio] as the start of
/// their own radio; albums and playlists open under
/// [base] (`/discover` on Home, `/search` on Search); artists open a
/// YouTube Music search for their songs.
void openYtmItem(
  BuildContext context,
  WidgetRef ref,
  YtmItem item, {
  required List<YtmItem> siblings,
  required String base,
  bool radio = false,
}) {
  switch (item) {
    case YtmTrackItem() when radio:
      unawaited(ref.read(playbackProvider.notifier).startRadio(item.track));
    case YtmTrackItem():
      final tracks = [
        for (final s in siblings)
          if (s is YtmTrackItem) s.track,
      ];
      final start = tracks.indexWhere((t) => t.uri == item.videoId);
      unawaited(
        ref
            .read(playbackProvider.notifier)
            .playTracks(
              start < 0 ? [item.track] : tracks,
              startIndex: start < 0 ? 0 : start,
            ),
      );
    case YtmAlbumItem(:final browseId):
      context.go('$base/album/${Uri.encodeComponent(browseId)}');
    case YtmPlaylistItem(:final playlistId):
      context.go('$base/playlist/${Uri.encodeComponent(playlistId)}');
    case YtmArtistItem(:final browseId):
      openYtmArtist(context, browseId);
  }
}

/// Shows Search with [query] in the field and YouTube Music songs for it.
void searchMusicFor(BuildContext context, WidgetRef ref, String query) {
  ref.read(searchProvider.notifier).setQuery(query);
  final music = ref.read(musicSearchControllerProvider.notifier)
    ..setFilter(YtmSearchFilter.songs);
  unawaited(music.submit(query));
  context.go('/search');
}

/// Right-click / long-press menu for a song or video tile.
Future<void> showYtmTrackMenu(
  BuildContext context,
  WidgetRef ref,
  YtmTrackItem item,
  Offset position,
) async {
  final playback = ref.read(playbackProvider.notifier);
  final action = await showNoirMenu<String>(
    context,
    anchor: position & Size.zero,
    items: const [
      NoirMenuItem('radio', 'Start radio', icon: Icons.radio_rounded),
      NoirMenuItem('next', 'Play next', icon: Icons.playlist_play_rounded),
      NoirMenuItem('queue', 'Add to queue', icon: Icons.queue_music_rounded),
    ],
  );
  switch (action) {
    case 'radio':
      unawaited(playback.startRadio(item.track));
    case 'next':
      playback.playNext(item.track);
    case 'queue':
      playback.addToQueue([item.track]);
  }
}

/// A YouTube Music item as a [MediaTile] for horizontal shelves.
class YtmTile extends ConsumerWidget {
  const YtmTile({
    required this.item,
    required this.siblings,
    required this.width,
    this.base = '/discover',
    this.radio = false,
    super.key,
  });

  final YtmItem item;
  final List<YtmItem> siblings;
  final double width;
  final String base;

  /// Songs start their own radio instead of playing [siblings].
  final bool radio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = this.item;
    return MediaTile(
      width: width,
      title: item.title,
      subtitle: ytmSubtitle(item),
      artwork: (s) => ytmArtwork(item, s),
      onTap: () => openYtmItem(
        context,
        ref,
        item,
        siblings: siblings,
        base: base,
        radio: radio,
      ),
      onContextMenu: item is YtmTrackItem
          ? (position) =>
                unawaited(showYtmTrackMenu(context, ref, item, position))
          : null,
    );
  }
}
