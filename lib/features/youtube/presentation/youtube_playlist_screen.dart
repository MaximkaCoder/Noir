import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/home/application/pinned_playlists.dart';
import 'package:noir/features/home/presentation/pin_button.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/application/youtube_refresh.dart';
import 'package:noir/features/youtube/application/youtube_save.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/features/youtube/presentation/save_button.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/widgets/collection_header.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';
import 'package:noir/shared/widgets/track_filter.dart';
import 'package:noir/shared/widgets/track_row.dart';

/// A playlist from the connected YouTube account. Opening it — or coming
/// back to NOIR while it is open — fetches changes made on YouTube in the
/// background; removing a song removes it on YouTube.
class YouTubePlaylistScreen extends ConsumerStatefulWidget {
  const YouTubePlaylistScreen({required this.id, super.key});

  final String id;

  @override
  ConsumerState<YouTubePlaylistScreen> createState() =>
      _YouTubePlaylistScreenState();
}

class _YouTubePlaylistScreenState extends ConsumerState<YouTubePlaylistScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Windows reports "resumed" when the window gets focus back, e.g. after
    // editing the playlist in a browser.
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    _refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
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
      emptyMessage:
          'Nothing playable here yet. Deleted and private videos are skipped.',
      onRemove: (track) =>
          unawaited(removeFromYouTube(context, ref, widget.id, track)),
    );
  }
}

/// Removes [track] from [playlistId] on YouTube (unlikes it for
/// [likedVideosId]), asking for the permission first when needed.
Future<void> removeFromYouTube(
  BuildContext context,
  WidgetRef ref,
  String playlistId,
  Track track,
) async {
  final ctrl = ref.read(youTubeSaveProvider.notifier);
  var outcome = await ctrl.removeFrom(playlistId, track);
  if (outcome.result == SaveResult.needsPermission && context.mounted) {
    if (!await askForWriteAccess(context, ref) || !context.mounted) return;
    outcome = await ctrl.removeFrom(playlistId, track);
  }
  if (outcome.result == SaveResult.failed && context.mounted) {
    showToast(context, outcome.message!);
  }
}

/// Music among the videos the user liked on YouTube. Opening it fetches new
/// likes in the background.
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
    return _YouTubeTrackList(
      tracks: tracks,
      title: likedMusicTitle,
      artwork: tracks.value?.firstOrNull?.artworkUrl,
      eyebrow: 'YouTube',
      refreshKey: YouTubeRefreshController.likesKey,
      pin: PinnedRef.youtubeLiked,
      emptyMessage: 'No music among your liked videos yet.',
      onRemove: (track) =>
          unawaited(removeFromYouTube(context, ref, likedVideosId, track)),
    );
  }
}

class _YouTubeTrackList extends ConsumerStatefulWidget {
  const _YouTubeTrackList({
    required this.tracks,
    required this.title,
    required this.artwork,
    required this.eyebrow,
    required this.refreshKey,
    required this.pin,
    required this.emptyMessage,
    this.onRemove,
  });

  final AsyncValue<List<Track>> tracks;
  final String title;
  final String? artwork;
  final String eyebrow;

  /// Key of this page in [youTubeRefreshProvider].
  final String refreshKey;
  final PinnedRef pin;
  final String emptyMessage;

  /// Adds "Remove from playlist" to each song's menu.
  final void Function(Track track)? onRemove;

  @override
  ConsumerState<_YouTubeTrackList> createState() => _YouTubeTrackListState();
}

class _YouTubeTrackListState extends ConsumerState<_YouTubeTrackList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final _YouTubeTrackList(
      :tracks,
      :title,
      :artwork,
      :eyebrow,
      :refreshKey,
      :pin,
      :emptyMessage,
      :onRemove,
    ) = widget;
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
    final shown = matchingTracks(list, _query);
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
            onSurprise: list.length < 2
                ? null
                : () => unawaited(playback.surprise(list)),
            actions: [PinButton(pin)],
          ),
        ),
        if (list.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: NoirSpacing.md),
              child: Align(
                alignment: Alignment.centerRight,
                child: TrackFilterField(
                  onChanged: (q) => setState(() => _query = q),
                ),
              ),
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
        if (list.isNotEmpty && shown.isEmpty)
          const SliverToBoxAdapter(
            child: EmptyState(
              title: 'Nothing found',
              message: 'No song in this list matches your search.',
              compact: true,
            ),
          ),
        SliverList.builder(
          itemCount: shown.length,
          itemBuilder: (context, n) {
            final i = shown[n];
            return TrackRow(
              key: ValueKey('${list[i].id}#$i'),
              track: list[i],
              number: i + 1,
              onPlay: () => unawaited(
                _query.isEmpty
                    ? playback.playTracks(list, startIndex: i)
                    : playback.playTracks([
                        for (final j in shown) list[j],
                      ], startIndex: n),
              ),
              onRemove: onRemove == null ? null : () => onRemove(list[i]),
            );
          },
        ),
      ],
    );
  }
}
