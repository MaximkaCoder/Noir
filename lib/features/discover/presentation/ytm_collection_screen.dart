import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/discover/presentation/load_more.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/widgets/collection_header.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';
import 'package:noir/shared/widgets/track_row.dart';
import 'package:url_launcher/url_launcher.dart';

/// A YouTube Music playlist or album opened from Discover or Search.
/// Read-only; long playlists load further tracks as you scroll.
class YtmCollectionScreen extends ConsumerWidget {
  const YtmCollectionScreen({required this.kind, required this.id, super.key});

  final YtmCollectionKind kind;

  /// Playlist id or album browse id.
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = ytmCollectionProvider((kind: kind, id: id));
    final async = ref.watch(provider);
    final collection = async.value;
    if (collection == null) {
      if (async.hasError && !async.isLoading) {
        return ErrorState(
          title: kind == YtmCollectionKind.album
              ? "This album couldn't be opened"
              : "This playlist couldn't be opened",
          message: switch (async.error) {
            InnerTubeException(:final message) => message,
            _ => 'YouTube Music is unavailable right now.',
          },
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(provider),
        );
      }
      return const Padding(padding: EdgeInsets.all(40), child: LoadingState());
    }

    final playback = ref.read(playbackProvider.notifier);
    final tracks = collection.tracks;
    final more = collection.continuation != null;
    final total = tracks.fold(
      Duration.zero,
      (sum, t) => sum + (t.duration ?? Duration.zero),
    );
    final isAlbum = kind == YtmCollectionKind.album;
    return PageScaffold(
      slivers: [
        SliverToBoxAdapter(
          child: CollectionHeader(
            eyebrow:
                collection.subtitle?.replaceAll(' • ', ' · ') ??
                (isAlbum ? 'Album' : 'Playlist'),
            artwork: (s) => Artwork(
              path: collection.thumbnailUrl,
              size: s,
              radius: 16,
              icon: isAlbum ? Icons.album_outlined : Icons.queue_music_rounded,
            ),
            title: collection.title,
            subtitle: [
              ?collection.author,
              '${songCount(tracks.length)}${more ? '+' : ''}',
              if (total > Duration.zero) formatTotal(total),
            ].join(' · '),
            onPlay: tracks.isEmpty
                ? null
                : () => unawaited(playback.playTracks(tracks)),
            onShuffle: tracks.isEmpty
                ? null
                : () => unawaited(playback.shuffleTracks(tracks)),
            actions: [
              NoirIconButton(
                icon: Icons.open_in_new_rounded,
                tooltip: 'Open in YouTube Music',
                onPressed: () => unawaited(
                  launchUrl(
                    _openUrl(collection),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (tracks.isEmpty && !more)
          const SliverToBoxAdapter(
            child: EmptyState(
              title: 'No songs',
              message: 'Nothing here can be played.',
              compact: true,
            ),
          ),
        SliverList.builder(
          itemCount: tracks.length + (more ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == tracks.length) {
              return LoadMoreTrigger(
                key: ValueKey('more-${tracks.length}'),
                onLoadMore: ref.read(provider.notifier).loadMore,
                placeholder: const LoadingState(rows: 2),
              );
            }
            return TrackRow(
              key: ValueKey('${tracks[i].id}#$i'),
              track: tracks[i],
              number: i + 1,
              // Album tracks share the cover shown above.
              showArtwork: !isAlbum,
              onPlay: () =>
                  unawaited(playback.playTracks(tracks, startIndex: i)),
            );
          },
        ),
      ],
    );
  }

  Uri _openUrl(YtmCollection c) {
    if (c.playlistId case final list?) return youTubeMusicUrl(playlistId: list);
    if (kind == YtmCollectionKind.playlist) {
      return youTubeMusicUrl(
        playlistId: id.startsWith('VL') ? id.substring(2) : id,
      );
    }
    return Uri.https('music.youtube.com', '/browse/$id');
  }
}
