import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/discover/presentation/load_more.dart';
import 'package:noir/features/discover/presentation/ytm_items.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/widgets/collection_header.dart';
import 'package:noir/shared/widgets/media_tiles.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';
import 'package:noir/shared/widgets/track_row.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where YouTube Music pages open: `/search` while the Search branch is
/// showing (also beneath routes pushed over the shell, like Now Playing),
/// `/discover` (Home) otherwise.
String ytmBranchBase(BuildContext context) {
  bool onSearch(List<RouteMatchBase> matches) => matches.any(
    (m) =>
        m.matchedLocation == '/search' ||
        m.matchedLocation.startsWith('/search/') ||
        (m is ShellRouteMatch && onSearch(m.matches)),
  );
  final config = GoRouter.of(context).routerDelegate.currentConfiguration;
  return onSearch(config.matches) ? '/search' : '/discover';
}

/// Opens the YouTube Music artist [browseId] (`UC…`) in the current
/// branch ([ytmBranchBase]).
void openYtmArtist(BuildContext context, String browseId) => context.go(
  '${ytmBranchBase(context)}/artist/${Uri.encodeComponent(browseId)}',
);

/// A YouTube Music artist: header, top songs (all of them on demand), then
/// albums, singles, videos and related artists in rows. Read-only.
class YtmArtistScreen extends ConsumerStatefulWidget {
  const YtmArtistScreen({
    required this.browseId,
    this.base = '/discover',
    super.key,
  });

  /// Channel id (`UC…`).
  final String browseId;

  /// Where albums and playlists open (`/discover` or `/search`).
  final String base;

  /// Top songs shown before "Show all".
  static const topCount = 5;

  @override
  ConsumerState<YtmArtistScreen> createState() => _YtmArtistScreenState();
}

class _YtmArtistScreenState extends ConsumerState<YtmArtistScreen> {
  bool _allSongs = false;

  @override
  Widget build(BuildContext context) {
    final provider = ytmArtistProvider(widget.browseId);
    final async = ref.watch(provider);
    final artist = async.value;
    if (artist == null) {
      if (async.hasError && !async.isLoading) {
        return ErrorState(
          title: "This artist couldn't be opened",
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
    final top = artist.topSongs;
    final playlistId = artist.songsPlaylistId;
    final all = _allSongs && playlistId != null
        ? ytmCollectionProvider((
            kind: YtmCollectionKind.playlist,
            id: playlistId,
          ))
        : null;
    final allAsync = all == null ? null : ref.watch(all);
    final allSongs = allAsync?.value;
    final songs =
        allSongs?.tracks ?? top.take(YtmArtistScreen.topCount).toList();
    final more = allSongs?.continuation != null;
    final compact =
        WindowClass.of(MediaQuery.sizeOf(context).width) == WindowClass.compact;
    final tile = compact ? 136.0 : 160.0;

    return PageScaffold(
      slivers: [
        SliverToBoxAdapter(
          child: _ArtistHeader(
            artist: artist,
            onPlay: top.isEmpty
                ? null
                : () => unawaited(playback.playTracks(songs)),
            onShuffle: top.isEmpty
                ? null
                : () => unawaited(playback.shuffleTracks(songs)),
            onRadio: top.isEmpty
                ? null
                : () => unawaited(playback.startRadio(top.first)),
          ),
        ),
        if (top.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SectionHeader(
              'Top songs',
              action: playlistId == null
                  ? null
                  : _allSongs
                  ? 'Show less'
                  : 'Show all',
              onAction: () => setState(() => _allSongs = !_allSongs),
            ),
          ),
          SliverList.builder(
            itemCount: songs.length + (more ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == songs.length) {
                return LoadMoreTrigger(
                  key: ValueKey('more-${songs.length}'),
                  onLoadMore: ref.read(all!.notifier).loadMore,
                  placeholder: const LoadingState(rows: 2),
                );
              }
              return TrackRow(
                key: ValueKey('${songs[i].id}#$i'),
                track: songs[i],
                number: i + 1,
                onPlay: () =>
                    unawaited(playback.playTracks(songs, startIndex: i)),
              );
            },
          ),
          if (allAsync != null && allSongs == null)
            SliverToBoxAdapter(
              child: allAsync.hasError && !allAsync.isLoading
                  ? ErrorState(
                      title: "Couldn't load all songs",
                      message: 'YouTube Music is unavailable right now.',
                      actionLabel: 'Try again',
                      onAction: () => ref.invalidate(all!),
                      compact: true,
                    )
                  : const LoadingState(rows: 2),
            ),
        ],
        for (final shelf in artist.shelves)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(shelf.title),
                  // Plain row for now; to be replaced by the shared shelf.
                  TileRow(
                    tileWidth: tile,
                    children: [
                      for (final (i, item) in shelf.items.indexed)
                        _ArtistShelfTile(
                          key: ValueKey('$i-${item.title}'),
                          item: item,
                          siblings: shelf.items,
                          width: tile,
                          base: widget.base,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (artist.description case final about? when about.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 28),
              child: _About(text: about),
            ),
          ),
      ],
    );
  }
}

/// Banner with the name over it when the artist has one; otherwise the
/// usual collection header with a round picture.
class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({
    required this.artist,
    required this.onPlay,
    required this.onShuffle,
    required this.onRadio,
  });

  final YtmArtist artist;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final VoidCallback? onRadio;

  @override
  Widget build(BuildContext context) {
    final subtitle = [?artist.subscribers, ?artist.audience].join(' · ');
    final actions = [
      NoirIconButton(
        icon: Icons.radio_rounded,
        tooltip: 'Start radio',
        onPressed: onRadio,
      ),
      NoirIconButton(
        icon: Icons.open_in_new_rounded,
        tooltip: 'Open in YouTube Music',
        onPressed: () => unawaited(
          launchUrl(
            Uri.https('music.youtube.com', '/channel/${artist.browseId}'),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ),
    ];
    final banner = artist.bannerUrl;
    if (banner == null) {
      return CollectionHeader(
        eyebrow: 'Artist',
        artwork: (s) => artistAvatar(artist.thumbnailUrl, s),
        title: artist.name,
        subtitle: subtitle.isEmpty ? 'YouTube Music' : subtitle,
        onPlay: onPlay,
        onShuffle: onShuffle,
        actions: actions,
      );
    }

    final t = Theme.of(context).textTheme;
    final compact =
        WindowClass.of(MediaQuery.sizeOf(context).width) == WindowClass.compact;
    return Padding(
      padding: const EdgeInsets.only(
        top: NoirSpacing.lg,
        bottom: NoirSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final height = (box.maxWidth * 0.36).clamp(180.0, 320.0);
              final dpr = MediaQuery.devicePixelRatioOf(context);
              return ClipRRect(
                borderRadius: NoirRadii.lgAll,
                child: SizedBox(
                  width: box.maxWidth,
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: context.noir.surfaceElevated),
                      Image.network(
                        banner,
                        fit: BoxFit.cover,
                        alignment: const Alignment(0, -0.3),
                        cacheWidth: (box.maxWidth * dpr).ceil(),
                        gaplessPlayback: true,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      // Keeps the name legible over any picture, in either
                      // theme.
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0.35, 1],
                            colors: [
                              Colors.black.withValues(alpha: 0),
                              Colors.black.withValues(alpha: 0.66),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: NoirSpacing.xl,
                        right: NoirSpacing.xl,
                        bottom: NoirSpacing.lg,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Artist',
                              style: t.labelMedium?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Semantics(
                              header: true,
                              child: Text(
                                artist.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    (compact
                                            ? t.headlineMedium
                                            : t.displaySmall)
                                        ?.copyWith(color: Colors.white),
                              ),
                            ),
                            if (subtitle.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                subtitle,
                                style: t.bodySmall?.copyWith(
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: NoirSpacing.lg),
          Row(
            children: [
              PrimaryPlayButton(playing: false, onPressed: onPlay, size: 44),
              const SizedBox(width: NoirSpacing.sm),
              NoirIconButton(
                icon: Icons.shuffle_rounded,
                tooltip: 'Shuffle play',
                onPressed: onShuffle,
              ),
              ...actions,
            ],
          ),
        ],
      ),
    );
  }
}

/// A shelf item; related artists open their own page here instead of a
/// search.
class _ArtistShelfTile extends ConsumerWidget {
  const _ArtistShelfTile({
    required this.item,
    required this.siblings,
    required this.width,
    required this.base,
    super.key,
  });

  final YtmItem item;
  final List<YtmItem> siblings;
  final double width;
  final String base;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = this.item;
    return MediaTile(
      width: width,
      title: item.title,
      subtitle: ytmSubtitle(item),
      artwork: (s) => ytmArtwork(item, s),
      onTap: () => item is YtmArtistItem
          ? openYtmArtist(context, item.browseId)
          : openYtmItem(context, ref, item, siblings: siblings, base: base),
      onContextMenu: item is YtmTrackItem
          ? (position) =>
                unawaited(showYtmTrackMenu(context, ref, item, position))
          : null,
    );
  }
}

/// The artist's biography, clamped until expanded.
class _About extends StatefulWidget {
  const _About({required this.text});

  final String text;

  @override
  State<_About> createState() => _AboutState();
}

class _AboutState extends State<_About> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'About',
          action: _open ? 'Less' : 'More',
          onAction: () => setState(() => _open = !_open),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: AnimatedSize(
            duration: NoirEffects.of(context).motion(NoirMotion.medium),
            curve: NoirMotion.standard,
            alignment: Alignment.topLeft,
            child: Text(
              widget.text,
              maxLines: _open ? null : 3,
              overflow: _open ? null : TextOverflow.ellipsis,
              style: t.bodyMedium?.copyWith(color: context.noir.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}
