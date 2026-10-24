import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/library/application/library_providers.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playlists/presentation/add_to_playlist.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/widgets/collection_header.dart';
import 'package:noir/shared/widgets/media_tiles.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';
import 'package:noir/shared/widgets/track_row.dart';

final _albumTracksProvider = FutureProvider.family<List<Track>, Album>((
  ref,
  album,
) {
  // Re-query when the library changes (e.g. favorites, rescans).
  ref.watch(tracksProvider(TrackSort.title));
  return ref.watch(libraryRepositoryProvider).albumTracks(album);
});

final _artistTracksProvider = FutureProvider.family<List<Track>, String>((
  ref,
  artist,
) {
  ref.watch(tracksProvider(TrackSort.title));
  return ref.watch(libraryRepositoryProvider).artistTracks(artist);
});

String collectionSubtitle(List<Track> tracks) {
  final total = tracks.fold(
    Duration.zero,
    (sum, t) => sum + (t.duration ?? Duration.zero),
  );
  return '${songCount(tracks.length)} · ${formatTotal(total)}';
}

/// Shared body: header + numbered track list.
class TrackCollectionPage extends ConsumerWidget {
  const TrackCollectionPage({
    required this.tracks,
    required this.header,
    this.emptyMessage = 'Nothing here yet.',
    super.key,
  });

  final AsyncValue<List<Track>> tracks;
  final Widget Function(List<Track> tracks) header;
  final String emptyMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.read(playbackProvider.notifier);
    return switch (tracks) {
      AsyncData(:final value) => PageScaffold(
        slivers: [
          SliverToBoxAdapter(child: header(value)),
          if (value.isEmpty)
            SliverToBoxAdapter(
              child: EmptyState(
                title: 'No songs',
                message: emptyMessage,
                compact: true,
              ),
            ),
          SliverList.builder(
            itemCount: value.length,
            itemBuilder: (context, i) => TrackRow(
              key: ValueKey(value[i].id),
              track: value[i],
              number: i + 1,
              onPlay: () =>
                  unawaited(playback.playTracks(value, startIndex: i)),
            ),
          ),
        ],
      ),
      AsyncError() => const ErrorState(
        message: "These songs couldn't be loaded. Try again in a moment.",
      ),
      _ => const Padding(padding: EdgeInsets.all(40), child: LoadingState()),
    };
  }
}

List<Widget> _addAllAction(
  BuildContext context,
  WidgetRef ref,
  List<Track> t,
) => [
  NoirIconButton(
    icon: Icons.playlist_add_rounded,
    tooltip: 'Add all to playlist',
    onPressed: t.isEmpty
        ? null
        : () => unawaited(addToPlaylist(context, ref, t)),
  ),
  NoirIconButton(
    icon: Icons.queue_music_rounded,
    tooltip: 'Add all to queue',
    onPressed: t.isEmpty
        ? null
        : () => ref.read(playbackProvider.notifier).addToQueue(t),
  ),
];

class AlbumScreen extends ConsumerWidget {
  const AlbumScreen({required this.album, super.key});

  final Album album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.read(playbackProvider.notifier);
    return TrackCollectionPage(
      tracks: ref.watch(_albumTracksProvider(album)),
      header: (tracks) => CollectionHeader(
        eyebrow: 'Album',
        artwork: (s) => Artwork(
          path: tracks.firstOrNull?.artworkPath ?? album.artworkPath,
          size: s,
          radius: 16,
        ),
        title: album.title,
        subtitle: [
          album.artist,
          if (album.year != null) '${album.year}',
          collectionSubtitle(tracks),
        ].join(' · '),
        onPlay: tracks.isEmpty
            ? null
            : () => unawaited(playback.playTracks(tracks)),
        onShuffle: tracks.isEmpty
            ? null
            : () => unawaited(playback.shuffleTracks(tracks)),
        actions: _addAllAction(context, ref, tracks),
      ),
    );
  }
}

class ArtistScreen extends ConsumerWidget {
  const ArtistScreen({required this.artist, super.key});

  final String artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.read(playbackProvider.notifier);
    return TrackCollectionPage(
      tracks: ref.watch(_artistTracksProvider(artist)),
      header: (tracks) => CollectionHeader(
        eyebrow: 'Artist',
        artwork: (s) => artistAvatar(
          tracks.where((t) => t.artworkPath != null).firstOrNull?.artworkPath,
          s,
        ),
        title: artist,
        subtitle: collectionSubtitle(tracks),
        onPlay: tracks.isEmpty
            ? null
            : () => unawaited(playback.playTracks(tracks)),
        onShuffle: tracks.isEmpty
            ? null
            : () => unawaited(playback.shuffleTracks(tracks)),
        actions: _addAllAction(context, ref, tracks),
      ),
    );
  }
}

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.read(playbackProvider.notifier);
    return TrackCollectionPage(
      tracks: ref.watch(favoritesProvider),
      emptyMessage:
          'Use the heart on any song. Favorites are stored on this device '
          'and do not sync to any online service.',
      header: (tracks) => CollectionHeader(
        eyebrow: 'On this device',
        artwork: (s) => ArtworkCollage(
          paths: <String>{for (final t in tracks) ?t.artworkPath}
              .take(4)
              .toList(),
          size: s,
          radius: 16,
        ),
        title: 'Favorites',
        subtitle: collectionSubtitle(tracks),
        onPlay: tracks.isEmpty
            ? null
            : () => unawaited(playback.playTracks(tracks)),
        onShuffle: tracks.isEmpty
            ? null
            : () => unawaited(playback.shuffleTracks(tracks)),
        actions: _addAllAction(context, ref, tracks),
      ),
    );
  }
}
