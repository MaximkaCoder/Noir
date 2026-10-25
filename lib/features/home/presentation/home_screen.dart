import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/menus.dart';
import 'package:noir/features/discover/presentation/discover_section.dart';
import 'package:noir/features/home/application/pinned_playlists.dart';
import 'package:noir/features/library/application/library_providers.dart';
import 'package:noir/features/playlists/application/playlist_providers.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/widgets/media_tiles.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';

/// Quiet, editorial start page: the user's saved collections in one row,
/// then Discover (YouTube Music's anonymous home feed). The player island
/// already shows what's playing; local music lives in Library.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact =
        WindowClass.of(MediaQuery.sizeOf(context).width) == WindowClass.compact;
    final tile = compact ? 128.0 : 150.0;
    // Pull to refresh (touch) reloads Discover.
    return RefreshIndicator(
      onRefresh: () => refreshDiscover(ref, force: true, context: context),
      child: PageScaffold(
        slivers: [
          const SliverToBoxAdapter(
            child: _Greeting(subtitle: "Here's what's playing today."),
          ),
          SliverToBoxAdapter(child: ListenAgainSection(tileWidth: tile)),
          SliverToBoxAdapter(child: _PlaylistsRow(tile: tile)),
          ForYouSection(tileWidth: tile),
          DiscoverSection(tileWidth: tile),
        ],
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.subtitle});

  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: NoirSpacing.sm, bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(greetingFor(DateTime.now()), style: t.headlineMedium),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: t.bodyLarge),
        ],
      ),
    );
  }
}

typedef _Collection = ({
  String title,
  String subtitle,
  Widget Function(double size) artwork,
});

/// Every saved collection in one row: pinned first (newest pin first), then
/// Liked music, Favorites, this device's playlists and YouTube playlists.
/// Right-click or long-press a tile to pin or unpin it.
class _PlaylistsRow extends ConsumerWidget {
  const _PlaylistsRow({required this.tile});

  final double tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pins = ref.watch(pinnedProvider);
    final playlists = ref.watch(playlistsProvider).value ?? const <Playlist>[];
    final youtube =
        ref.watch(youTubePlaylistsProvider).value ?? const <YouTubePlaylist>[];
    final likes = ref.watch(youTubeLikesProvider).value ?? const <Track>[];
    final favorites = ref.watch(favoritesProvider).value ?? const <Track>[];
    final likesTitle = ref.watch(youTubeLikesTitleProvider);

    _Collection liked() => (
      title: likesTitle,
      subtitle: 'YouTube · ${songCount(likes.length)}',
      artwork: (s) => Artwork(
        path: likes.firstOrNull?.artwork,
        size: s,
        icon: Icons.thumb_up_alt_outlined,
      ),
    );
    _Collection favorite() => (
      title: 'Favorites',
      subtitle: songCount(favorites.length),
      artwork: (s) => Artwork(
        path: favorites.firstOrNull?.artwork,
        size: s,
        icon: Icons.favorite_rounded,
      ),
    );

    // Unpinned order. Empty Liked / Favorites only show when pinned.
    final all = <PinnedRef, _Collection>{
      if (likes.isNotEmpty) PinnedRef.youtubeLiked: liked(),
      if (favorites.isNotEmpty) PinnedRef.favorites: favorite(),
      for (final p in playlists)
        PinnedRef(PinKind.local, '${p.id}'): (
          title: p.name,
          subtitle: songCount(p.trackCount),
          artwork: (s) => ArtworkCollage(paths: p.artworkPaths, size: s),
        ),
      for (final p in youtube)
        PinnedRef(PinKind.youtube, p.id): (
          title: p.title,
          subtitle: 'YouTube · ${songCount(p.trackCount)}',
          artwork: (s) => Artwork(path: p.thumbnailUrl, size: s),
        ),
    };
    final items = <(PinnedRef, _Collection, bool)>[
      for (final pin in pins)
        // Pinned items deleted elsewhere simply don't show.
        if (switch (pin.kind) {
              PinKind.youtubeLiked => liked(),
              PinKind.favorites => favorite(),
              _ => all[pin],
            }
            case final c?)
          (pin, c, true),
      for (final MapEntry(:key, :value) in all.entries)
        if (!pins.contains(key)) (key, value, false),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    return TileRow(
      title: 'Your playlists',
      tileWidth: tile,
      children: [
        for (final (pin, c, pinned) in items)
          MediaTile(
            key: ValueKey('${pin.kind.name}-${pin.id}'),
            width: tile,
            title: c.title,
            subtitle: c.subtitle,
            artwork: c.artwork,
            onTap: () => context.go(pin.location),
            onContextMenu: (position) async {
              final action = await showNoirMenu<String>(
                context,
                anchor: position & Size.zero,
                items: [
                  if (pinned)
                    const NoirMenuItem(
                      'pin',
                      'Unpin from Home',
                      icon: Icons.push_pin_outlined,
                    )
                  else
                    const NoirMenuItem(
                      'pin',
                      'Pin to Home',
                      icon: Icons.push_pin_rounded,
                    ),
                ],
              );
              if (action == 'pin') {
                ref.read(pinnedProvider.notifier).toggle(pin);
              }
            },
          ),
      ],
    );
  }
}
