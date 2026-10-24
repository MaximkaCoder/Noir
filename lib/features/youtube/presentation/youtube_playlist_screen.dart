import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/home/application/pinned_playlists.dart';
import 'package:noir/features/home/presentation/pin_button.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/widgets/collection_header.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';
import 'package:noir/shared/widgets/track_row.dart';
import 'package:url_launcher/url_launcher.dart';

/// A playlist from the connected YouTube account (read-only in NOIR).
class YouTubePlaylistScreen extends ConsumerWidget {
  const YouTubePlaylistScreen({required this.id, super.key});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlist = ref.watch(youTubePlaylistProvider(id));
    final tracks = ref.watch(youTubePlaylistTracksProvider(id));
    if (playlist case AsyncData(value: null)) {
      return const EmptyState(
        icon: Icons.playlist_remove_rounded,
        title: 'Playlist not found',
        message: 'It may have been deleted on YouTube, or you disconnected.',
      );
    }
    final p = playlist.value;
    return _YouTubeTrackList(
      tracks: tracks,
      title: p?.title ?? '',
      artwork: p?.thumbnailUrl,
      eyebrow: 'YouTube playlist',
      pin: PinnedRef(PinKind.youtube, id),
      openUrl: youTubeMusicUrl(playlistId: id),
      emptyMessage:
          'Nothing playable here yet. Deleted and private videos are skipped.',
    );
  }
}

class YouTubeLikesScreen extends ConsumerWidget {
  const YouTubeLikesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(youTubeLikesProvider);
    return _YouTubeTrackList(
      tracks: tracks,
      title: 'Liked videos',
      artwork: tracks.value?.firstOrNull?.artworkUrl,
      eyebrow: 'YouTube',
      pin: PinnedRef.youtubeLiked,
      openUrl: youTubeMusicUrl(playlistId: 'LL'),
      emptyMessage: 'Videos you like on YouTube appear here after a sync.',
    );
  }
}

class _YouTubeTrackList extends ConsumerWidget {
  const _YouTubeTrackList({
    required this.tracks,
    required this.title,
    required this.artwork,
    required this.eyebrow,
    required this.pin,
    required this.openUrl,
    required this.emptyMessage,
  });

  final AsyncValue<List<Track>> tracks;
  final String title;
  final String? artwork;
  final String eyebrow;
  final PinnedRef pin;
  final Uri openUrl;
  final String emptyMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.read(playbackProvider.notifier);
    final list = tracks.value;
    if (list == null) {
      return tracks.hasError
          ? const ErrorState(message: "These songs couldn't be loaded.")
          : const Padding(padding: EdgeInsets.all(40), child: LoadingState());
    }
    final total = list.fold(
      Duration.zero,
      (sum, t) => sum + (t.duration ?? Duration.zero),
    );
    return PageScaffold(
      slivers: [
        SliverToBoxAdapter(
          child: CollectionHeader(
            eyebrow: eyebrow,
            artwork: (s) => Artwork(path: artwork, size: s, radius: 16),
            title: title,
            subtitle: '${songCount(list.length)} · ${formatTotal(total)}',
            onPlay: list.isEmpty
                ? null
                : () => unawaited(playback.playTracks(list)),
            onShuffle: list.isEmpty
                ? null
                : () => unawaited(playback.shuffleTracks(list)),
            actions: [
              PinButton(pin),
              NoirIconButton(
                icon: Icons.open_in_new_rounded,
                tooltip: 'Open in YouTube Music',
                onPressed: () => unawaited(
                  launchUrl(openUrl, mode: LaunchMode.externalApplication),
                ),
              ),
            ],
          ),
        ),
        if (list.isEmpty)
          SliverToBoxAdapter(
            child: EmptyState(
              title: 'No songs',
              message: emptyMessage,
              compact: true,
            ),
          ),
        SliverList.builder(
          itemCount: list.length,
          itemBuilder: (context, i) => TrackRow(
            key: ValueKey('${list[i].id}#$i'),
            track: list[i],
            number: i + 1,
            onPlay: () => unawaited(playback.playTracks(list, startIndex: i)),
          ),
        ),
      ],
    );
  }
}
