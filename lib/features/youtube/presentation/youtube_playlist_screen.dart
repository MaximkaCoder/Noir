import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/home/application/pinned_playlists.dart';
import 'package:noir/features/home/presentation/pin_button.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/application/youtube_refresh.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/widgets/collection_header.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';
import 'package:noir/shared/widgets/track_row.dart';
import 'package:url_launcher/url_launcher.dart';

/// A playlist from the connected YouTube account (read-only in NOIR).
/// Opening it fetches changes made on YouTube in the background.
class YouTubePlaylistScreen extends ConsumerStatefulWidget {
  const YouTubePlaylistScreen({required this.id, super.key});

  final String id;

  @override
  ConsumerState<YouTubePlaylistScreen> createState() =>
      _YouTubePlaylistScreenState();
}

class _YouTubePlaylistScreenState extends ConsumerState<YouTubePlaylistScreen> {
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(YouTubePlaylistScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) _refresh();
  }

  // After the frame: providers must not change while widgets build.
  void _refresh() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    unawaited(
      ref.read(youTubeRefreshProvider.notifier).refreshPlaylist(widget.id),
    );
  });

  @override
  Widget build(BuildContext context) {
    final id = widget.id;
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
      refreshKey: id,
      pin: PinnedRef(PinKind.youtube, id),
      openUrl: youTubeMusicUrl(playlistId: id),
      emptyMessage:
          'Nothing playable here yet. Deleted and private videos are skipped.',
    );
  }
}

/// Videos the user liked on YouTube; music only unless "All likes" is
/// chosen. Opening it fetches new likes in the background.
class YouTubeLikesScreen extends ConsumerStatefulWidget {
  const YouTubeLikesScreen({super.key});

  @override
  ConsumerState<YouTubeLikesScreen> createState() => _YouTubeLikesScreenState();
}

class _YouTubeLikesScreenState extends ConsumerState<YouTubeLikesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(youTubeRefreshProvider.notifier).refreshLikes());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tracks = ref.watch(youTubeLikesProvider);
    final musicOnly = ref.watch(likesMusicOnlyProvider);
    void show({required bool musicOnly}) =>
        ref.read(likesMusicOnlyProvider.notifier).set(musicOnly: musicOnly);
    return _YouTubeTrackList(
      tracks: tracks,
      title: ref.watch(youTubeLikesTitleProvider),
      artwork: tracks.value?.firstOrNull?.artworkUrl,
      eyebrow: 'YouTube',
      refreshKey: YouTubeRefreshController.likesKey,
      pin: PinnedRef.youtubeLiked,
      openUrl: youTubeMusicUrl(playlistId: 'LL'),
      filters: [
        PillChip(
          label: 'Music',
          selected: musicOnly,
          onSelected: () => show(musicOnly: true),
        ),
        PillChip(
          label: 'All likes',
          selected: !musicOnly,
          onSelected: () => show(musicOnly: false),
        ),
      ],
      emptyMessage: musicOnly
          ? 'No music among your liked videos yet. "All likes" shows '
                'everything you liked on YouTube.'
          : 'Videos you like on YouTube appear here after a sync.',
    );
  }
}

class _YouTubeTrackList extends ConsumerWidget {
  const _YouTubeTrackList({
    required this.tracks,
    required this.title,
    required this.artwork,
    required this.eyebrow,
    required this.refreshKey,
    required this.pin,
    required this.openUrl,
    required this.emptyMessage,
    this.filters = const [],
  });

  final AsyncValue<List<Track>> tracks;
  final String title;
  final String? artwork;
  final String eyebrow;

  /// Key of this page in [youTubeRefreshProvider].
  final String refreshKey;
  final PinnedRef pin;
  final Uri openUrl;
  final String emptyMessage;

  /// Chips shown under the header.
  final List<Widget> filters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.read(playbackProvider.notifier);
    final syncing =
        ref.watch(
          youTubeRefreshProvider.select((s) => s.running.contains(refreshKey)),
        ) ||
        ref.watch(
          youTubeSyncProvider.select((s) => s.status == SyncStatus.syncing),
        );
    // A failed refresh keeps the saved list; just say so.
    ref.listen(youTubeRefreshProvider.select((s) => s.errors[refreshKey]), (
      _,
      message,
    ) {
      if (message != null) showToast(context, message);
    });
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
            subtitle:
                '${songCount(list.length)} · ${formatTotal(total)}'
                '${syncing ? ' · Syncing…' : ''}',
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
        if (filters.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: NoirSpacing.md),
              child: Wrap(spacing: NoirSpacing.xs, children: filters),
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
