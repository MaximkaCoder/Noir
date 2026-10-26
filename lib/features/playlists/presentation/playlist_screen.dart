import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/menus.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/home/application/pinned_playlists.dart';
import 'package:noir/features/home/presentation/pin_button.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playlists/application/playlist_providers.dart';
import 'package:noir/features/playlists/data/playlist_repository.dart';
import 'package:noir/shared/widgets/collection_header.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';
import 'package:noir/shared/widgets/track_filter.dart';
import 'package:noir/shared/widgets/track_row.dart';

/// A local playlist: play, shuffle, rename, delete, reorder, remove songs.
class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({required this.id, super.key});

  final int id;

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final id = widget.id;
    final playlist = ref.watch(playlistProvider(id));
    final entries = ref.watch(playlistTracksProvider(id));
    final repo = ref.read(playlistRepositoryProvider);
    final playback = ref.read(playbackProvider.notifier);

    if (playlist case AsyncData(value: null)) {
      return const EmptyState(
        icon: Icons.playlist_remove_rounded,
        title: 'Playlist not found',
        message: 'It may have been deleted.',
      );
    }
    final p = playlist.value;
    final list = entries.value;
    if (p == null || list == null) {
      return const Padding(padding: EdgeInsets.all(40), child: LoadingState());
    }
    final tracks = [for (final e in list) e.track];
    final shown = matchingTracks(tracks, _query);

    return PageScaffold(
      slivers: [
        SliverToBoxAdapter(
          child: CollectionHeader(
            eyebrow: 'Playlist · on this device',
            artwork: (s) =>
                ArtworkCollage(paths: p.artworkPaths, size: s, radius: 16),
            title: p.name,
            subtitle:
                '${songCount(p.trackCount)} · ${formatTotal(p.totalDuration)}',
            onPlay: tracks.isEmpty
                ? null
                : () => unawaited(playback.playTracks(tracks)),
            onShuffle: tracks.isEmpty
                ? null
                : () => unawaited(playback.shuffleTracks(tracks)),
            onSurprise: tracks.length < 2
                ? null
                : () => unawaited(playback.surprise(tracks)),
            actions: [
              PinButton(PinnedRef(PinKind.local, '${p.id}')),
              NoirMenuButton<String>(
                tooltip: 'More',
                icon: Icons.more_horiz_rounded,
                onSelected: (v) async {
                  switch (v) {
                    case 'queue':
                      playback.addToQueue(tracks);
                    case 'rename':
                      final name = await promptText(
                        context,
                        title: 'Rename playlist',
                        confirmLabel: 'Save',
                        initial: p.name,
                      );
                      if (name != null) await repo.rename(p.id, name);
                    case 'delete':
                      final ok = await confirm(
                        context,
                        title: 'Delete "${p.name}"?',
                        message:
                            'The playlist is removed from this device. Your '
                            'music files are not affected.',
                        confirmLabel: 'Delete',
                        destructive: true,
                      );
                      if (ok && context.mounted) {
                        context.go('/library');
                        await repo.delete(p.id);
                      }
                  }
                },
                items: () => [
                  if (tracks.isNotEmpty)
                    const NoirMenuItem(
                      'queue',
                      'Add to queue',
                      icon: Icons.queue_music_rounded,
                    ),
                  const NoirMenuItem(
                    'rename',
                    'Rename…',
                    icon: Icons.edit_outlined,
                  ),
                  const NoirMenuItem(
                    'delete',
                    'Delete…',
                    icon: Icons.delete_outline_rounded,
                  ),
                ],
              ),
            ],
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
          const SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.playlist_add_rounded,
              title: 'This playlist is empty',
              message: 'Use "Add to playlist…" from any song\'s menu.',
              compact: true,
            ),
          ),
        // Reordering needs the whole list, so a search shows plain rows.
        if (_query.isNotEmpty) ...[
          if (shown.isEmpty)
            const SliverToBoxAdapter(
              child: EmptyState(
                title: 'Nothing found',
                message: 'No song in this playlist matches your search.',
                compact: true,
              ),
            ),
          SliverList.builder(
            itemCount: shown.length,
            itemBuilder: (context, n) {
              final e = list[shown[n]];
              return TrackRow(
                key: ValueKey(e.entryId),
                track: e.track,
                number: shown[n] + 1,
                onPlay: () => unawaited(
                  playback.playTracks([
                    for (final j in shown) tracks[j],
                  ], startIndex: n),
                ),
                onRemove: () => unawaited(repo.removeEntry(p.id, e.entryId)),
              );
            },
          ),
        ] else
          SliverReorderableList(
            itemCount: list.length,
            onReorderItem: (from, to) {
              final ids = [for (final e in list) e.entryId];
              final moved = ids.removeAt(from);
              ids.insert(to, moved);
              unawaited(repo.reorder(p.id, ids));
            },
            itemBuilder: (context, i) {
              final e = list[i];
              return Material(
                key: ValueKey(e.entryId),
                type: MaterialType.transparency,
                child: TrackRow(
                  track: e.track,
                  number: i + 1,
                  onPlay: () =>
                      unawaited(playback.playTracks(tracks, startIndex: i)),
                  onRemove: () => unawaited(repo.removeEntry(p.id, e.entryId)),
                  trailing: _Trailing(entry: e, index: i),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _Trailing extends StatelessWidget {
  const _Trailing({required this.entry, required this.index});

  final PlaylistTrack entry;
  final int index;

  @override
  Widget build(BuildContext context) {
    final d = entry.track.duration;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          d == null ? '' : formatClock(d),
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontFeatures: tabularFigures),
        ),
        const SizedBox(width: 8),
        ReorderableDragStartListener(
          index: index,
          child: const MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Tooltip(
              message: 'Drag to reorder',
              child: Icon(Icons.drag_indicator_rounded, size: 18),
            ),
          ),
        ),
      ],
    );
  }
}
