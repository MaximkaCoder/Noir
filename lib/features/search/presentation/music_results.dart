import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/discover/presentation/load_more.dart';
import 'package:noir/features/discover/presentation/ytm_items.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/search/application/music_search_controller.dart';
import 'package:noir/features/search/application/search_controller.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/widgets/media_tiles.dart';
import 'package:noir/shared/widgets/track_row.dart';

/// Filters offered on the Search page, in order.
const musicSearchFilters = {
  YtmSearchFilter.songs: 'Songs',
  YtmSearchFilter.videos: 'Videos',
  YtmSearchFilter.albums: 'Albums',
  YtmSearchFilter.artists: 'Artists',
  YtmSearchFilter.playlists: 'Playlists',
};

/// The "YouTube Music" part of Search, under the local results: filter
/// chips, then results that play or open on tap and page in as you scroll.
/// A sliver.
class MusicResults extends ConsumerWidget {
  const MusicResults({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(musicSearchControllerProvider);
    final ctrl = ref.read(musicSearchControllerProvider.notifier);
    if (s.query.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final t = Theme.of(context).textTheme;
    final items = s.items;
    final tracks = [
      for (final i in items)
        if (i is YtmTrackItem) i.track,
    ];
    void commit() => unawaited(ref.read(searchProvider.notifier).commit());

    final Widget body;
    if (s.error != null && !s.loading) {
      body = SliverToBoxAdapter(
        child: ErrorState(
          compact: true,
          title: "YouTube Music couldn't be searched",
          message: s.error!,
          actionLabel: 'Try again',
          onAction: () => unawaited(ctrl.submit()),
        ),
      );
    } else if (s.resultsFor == null ||
        (!s.isCurrent && s.resultsFor?.filter != s.filter)) {
      // First search, or another filter: the old list would mislead.
      body = const SliverToBoxAdapter(child: LoadingState(rows: 4));
    } else if (items.isEmpty) {
      body = SliverToBoxAdapter(
        child: s.loading
            ? const LoadingState(rows: 4)
            : EmptyState(
                compact: true,
                icon: Icons.search_off_rounded,
                title: 'Nothing on YouTube Music for "${s.query}"',
                message: 'Try another filter or a different spelling.',
              ),
      );
    } else {
      body = SliverOpacity(
        // The previous query's results stay, dimmed, until new ones arrive.
        opacity: s.isCurrent ? 1 : 0.5,
        sliver: SliverList.builder(
          itemCount: items.length + (s.hasMore && s.isCurrent ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == items.length) {
              return LoadMoreTrigger(
                key: ValueKey('more-${items.length}'),
                onLoadMore: ctrl.loadMore,
                placeholder: const LoadingState(rows: 2),
              );
            }
            final item = items[i];
            final key = ValueKey('ytm-$i-${item.title}');
            return switch (item) {
              YtmTrackItem(:final track) => TrackRow(
                key: key,
                track: track,
                onPlay: () {
                  commit();
                  unawaited(
                    ref
                        .read(playbackProvider.notifier)
                        .playTracks(tracks, startIndex: tracks.indexOf(track)),
                  );
                },
              ),
              _ => CollectionRow(
                key: key,
                title: item.title,
                subtitle: ytmSubtitle(item),
                leading: ytmArtwork(item, 44),
                onTap: () {
                  commit();
                  openYtmItem(
                    context,
                    ref,
                    item,
                    siblings: items,
                    base: '/search',
                  );
                },
              ),
            };
          },
        ),
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(
              top: NoirSpacing.xxl,
              bottom: NoirSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text('YouTube Music', style: t.titleMedium),
                ),
                const SizedBox(height: NoirSpacing.md),
                Wrap(
                  spacing: NoirSpacing.xs,
                  runSpacing: NoirSpacing.xs,
                  children: [
                    for (final MapEntry(key: filter, value: label)
                        in musicSearchFilters.entries)
                      PillChip(
                        label: label,
                        selected: s.filter == filter,
                        onSelected: () => ctrl.setFilter(filter),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        body,
      ],
    );
  }
}
