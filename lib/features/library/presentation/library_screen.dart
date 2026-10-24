import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/menus.dart';
import 'package:noir/core/widgets/reveal.dart';
import 'package:noir/core/widgets/shelf_row.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/library/application/library_providers.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playlists/application/playlist_providers.dart';
import 'package:noir/features/playlists/presentation/add_to_playlist.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/widgets/media_tiles.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';
import 'package:noir/shared/widgets/track_row.dart';

enum LibraryTab { playlists, artists, albums, tracks, favorites }

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({this.initialTab, super.key});

  final LibraryTab? initialTab;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  late LibraryTab _tab = widget.initialTab ?? LibraryTab.playlists;
  TrackSort _sort = TrackSort.title;
  bool _filtering = false;
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Picks up playlists created on YouTube since the last sync (throttled).
    unawaited(ref.read(youTubeSyncProvider.notifier).refreshPlaylists());
  }

  @override
  void didUpdateWidget(LibraryScreen old) {
    super.didUpdateWidget(old);
    if (widget.initialTab != null && widget.initialTab != old.initialTab) {
      _tab = widget.initialTab!;
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  bool _matches(String text) =>
      text.toLowerCase().contains(_filter.text.trim().toLowerCase());

  @override
  Widget build(BuildContext context) {
    final count = ref.watch(trackCountProvider).value ?? 0;
    final hasFavorites =
        (ref.watch(favoritesProvider).value ?? const []).isNotEmpty;
    // Only offer categories that can actually be populated.
    final tabs = [
      LibraryTab.playlists,
      if (count > 0) ...[
        LibraryTab.artists,
        LibraryTab.albums,
        LibraryTab.tracks,
      ],
      if (hasFavorites) LibraryTab.favorites,
    ];
    final tab = tabs.contains(_tab) ? _tab : LibraryTab.playlists;
    final scan = ref.watch(libraryScanProvider);

    return PageScaffold(
      title: 'Your Library',
      actions: [
        NoirIconButton(
          icon: _filtering ? Icons.search_off_rounded : Icons.search_rounded,
          tooltip: _filtering ? 'Close filter' : 'Filter library',
          onPressed: () => setState(() {
            _filtering = !_filtering;
            if (!_filtering) _filter.clear();
          }),
        ),
        _AddMenu(
          onNewPlaylist: () => setState(() => _tab = LibraryTab.playlists),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(child: _ScanBanner(scan)),
        const SliverToBoxAdapter(child: _RecentlyPlayed()),
        SliverToBoxAdapter(
          child: Padding(
            // The chips' [ShelfRow.lift] completes the top gap.
            padding: const EdgeInsets.only(
              top: NoirSpacing.lg - ShelfRow.lift,
              bottom: NoirSpacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: ShelfRow(
                    height: MediaQuery.textScalerOf(context).scale(22) + 22,
                    spacing: NoirSpacing.xs,
                    arrowSize: 32,
                    children: [
                      for (final t in tabs)
                        Center(
                          child: PillChip(
                            label: _label(t),
                            selected: t == tab,
                            onSelected: () => setState(() => _tab = t),
                          ),
                        ),
                    ],
                  ),
                ),
                if (tab == LibraryTab.tracks)
                  _SortButton(
                    sort: _sort,
                    onChanged: (s) => setState(() => _sort = s),
                  ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Reveal(
            visible: _filtering,
            child: Padding(
              padding: const EdgeInsets.only(bottom: NoirSpacing.md),
              child: TextField(
                controller: _filter,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Filter ${_label(tab).toLowerCase()}',
                  prefixIcon: const Icon(Icons.filter_list_rounded, size: 18),
                  isDense: true,
                  filled: true,
                  fillColor: context.noir.hover,
                  border: const OutlineInputBorder(
                    borderRadius: NoirRadii.pillAll,
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
        ),
        ...switch (tab) {
          LibraryTab.playlists => _playlists(),
          LibraryTab.artists => _artists(),
          LibraryTab.albums => _albums(),
          LibraryTab.tracks => _tracks(ref.watch(tracksProvider(_sort))),
          LibraryTab.favorites => _tracks(ref.watch(favoritesProvider)),
        },
        if (count == 0)
          SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.library_music_outlined,
              title: 'No music yet',
              message:
                  'Add a folder or individual files to build your library.',
              actionLabel: LibraryScanController.supportsFolders
                  ? 'Choose a music folder'
                  : 'Add files',
              onAction: () => unawaited(
                LibraryScanController.supportsFolders
                    ? ref.read(libraryScanProvider.notifier).addFolder()
                    : ref.read(libraryScanProvider.notifier).importFiles(),
              ),
            ),
          ),
      ],
    );
  }

  static String _label(LibraryTab t) => switch (t) {
    LibraryTab.playlists => 'Playlists',
    LibraryTab.artists => 'Artists',
    LibraryTab.albums => 'Albums',
    LibraryTab.tracks => 'Tracks',
    LibraryTab.favorites => 'Favorites',
  };

  List<Widget> _playlists() {
    final async = ref.watch(playlistsProvider);
    final items = [
      for (final p in async.value ?? const <Playlist>[])
        if (_matches(p.name)) p,
    ];
    return [
      if (async.isLoading && !async.hasValue)
        const SliverToBoxAdapter(child: LoadingState()),
      SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final p = items[i];
          return CollectionRow(
            key: ValueKey(p.id),
            title: p.name,
            subtitle: songCount(p.trackCount),
            leading: ArtworkCollage(paths: p.artworkPaths, size: 48),
            onTap: () => context.go('/library/playlist/${p.id}'),
          );
        },
      ),
      if (async.hasValue && items.isEmpty && _filter.text.isEmpty)
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.queue_music_rounded,
            title: 'No playlists yet',
            message: 'Playlists you create live on this device.',
            actionLabel: 'Create playlist',
            compact: true,
            onAction: () async {
              final id = await createPlaylist(context, ref);
              if (id != null && mounted) context.go('/library/playlist/$id');
            },
          ),
        ),
      ..._youTubePlaylists(),
    ];
  }

  /// Playlists synced from the connected YouTube account, clearly labeled.
  List<Widget> _youTubePlaylists() {
    final playlists = [
      for (final p
          in ref.watch(youTubePlaylistsProvider).value ??
              const <YouTubePlaylist>[])
        if (_matches(p.title)) p,
    ];
    final likes = ref.watch(youTubeLikesProvider).value ?? const <Track>[];
    final likesTitle = ref.watch(youTubeLikesTitleProvider);
    final connected =
        ref.watch(accountConnectionProvider).value?.isConnected ?? false;
    if (!connected && playlists.isEmpty) return const [];
    return [
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: NoirSpacing.xl),
          child: SectionHeader('From YouTube'),
        ),
      ),
      if (likes.isNotEmpty && _matches(likesTitle))
        SliverToBoxAdapter(
          child: CollectionRow(
            title: likesTitle,
            subtitle: songCount(likes.length),
            leading: Artwork(
              path: likes.first.artworkUrl,
              size: 48,
              icon: Icons.thumb_up_alt_outlined,
            ),
            onTap: () => context.go('/library/youtube/liked'),
          ),
        ),
      SliverList.builder(
        itemCount: playlists.length,
        itemBuilder: (context, i) {
          final p = playlists[i];
          return CollectionRow(
            key: ValueKey('yt-${p.id}'),
            title: p.title,
            subtitle: songCount(p.trackCount),
            leading: Artwork(path: p.thumbnailUrl, size: 48),
            onTap: () => context.go('/library/youtube/${p.id}'),
          );
        },
      ),
    ];
  }

  List<Widget> _artists() {
    final items = [
      for (final a in ref.watch(artistsProvider).value ?? const <Artist>[])
        if (_matches(a.name)) a,
    ];
    return [
      SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final a = items[i];
          return CollectionRow(
            key: ValueKey(a.name),
            title: a.name,
            subtitle:
                '${songCount(a.trackCount)}'
                '${a.albumCount > 0 ? ' · ${a.albumCount} albums' : ''}',
            leading: artistAvatar(a.artworkPath, 48),
            onTap: () => context.go('/library/artist', extra: a.name),
          );
        },
      ),
    ];
  }

  List<Widget> _albums() {
    final items = [
      for (final a in ref.watch(albumsProvider).value ?? const <Album>[])
        if (_matches('${a.title} ${a.artist}')) a,
    ];
    return [
      SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final a = items[i];
          return CollectionRow(
            key: ValueKey('${a.title}|${a.artist}'),
            title: a.title,
            subtitle: [a.artist, if (a.year != null) '${a.year}'].join(' · '),
            leading: Artwork(path: a.artworkPath, size: 48),
            onTap: () => context.go('/library/album', extra: a),
          );
        },
      ),
    ];
  }

  List<Widget> _tracks(AsyncValue<List<Track>> async) {
    final items = [
      for (final t in async.value ?? const <Track>[])
        if (_matches('${t.title} ${t.artist ?? ''} ${t.album ?? ''}')) t,
    ];
    return [
      if (async.isLoading && !async.hasValue)
        const SliverToBoxAdapter(child: LoadingState()),
      SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, i) => TrackRow(
          key: ValueKey(items[i].id),
          track: items[i],
          onPlay: () => unawaited(
            ref
                .read(playbackProvider.notifier)
                .playTracks(items, startIndex: i),
          ),
        ),
      ),
    ];
  }
}

/// Last played albums (or single tracks), newest first, above the tabs.
class _RecentlyPlayed extends ConsumerWidget {
  const _RecentlyPlayed();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentTracksProvider).value ?? const <Track>[];
    // Distinct albums (or loose tracks) in order of last play.
    final items = <Track>[];
    final seenAlbums = <String>{};
    for (final t in recent) {
      if (t.album == null || seenAlbums.add('${t.album}|${t.artist}')) {
        items.add(t);
      }
    }
    if (items.isEmpty) return const SizedBox.shrink();
    final compact =
        WindowClass.of(MediaQuery.sizeOf(context).width) == WindowClass.compact;
    final tile = compact ? 128.0 : 150.0;
    return Padding(
      padding: const EdgeInsets.only(top: NoirSpacing.lg),
      child: TileRow(
        title: 'Recently played',
        tileWidth: tile,
        children: [
          for (final t in items)
            MediaTile(
              key: ValueKey(t.id),
              width: tile,
              title: t.album ?? t.title,
              subtitle: t.artistOrUnknown,
              artwork: (s) => Artwork(path: t.artworkPath, size: s),
              onTap: () => _open(context, ref, t),
            ),
        ],
      ),
    );
  }

  void _open(BuildContext context, WidgetRef ref, Track t) {
    if (t.album == null) {
      unawaited(ref.read(playbackProvider.notifier).playTracks([t]));
    } else {
      context.go(
        '/library/album',
        extra: Album(
          title: t.album!,
          artist: t.artistOrUnknown,
          trackCount: 0,
          artworkPath: t.artworkPath,
        ),
      );
    }
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.sort, required this.onChanged});

  final TrackSort sort;
  final ValueChanged<TrackSort> onChanged;

  @override
  Widget build(BuildContext context) {
    return NoirMenuButton<TrackSort>(
      tooltip: 'Sort',
      icon: Icons.sort_rounded,
      onSelected: onChanged,
      items: () => [
        for (final (value, label) in const [
          (TrackSort.title, 'Title'),
          (TrackSort.artist, 'Artist'),
          (TrackSort.album, 'Album'),
          (TrackSort.recentlyAdded, 'Recently added'),
        ])
          NoirMenuItem(value, label, checked: value == sort),
      ],
    );
  }
}

class _AddMenu extends ConsumerWidget {
  const _AddMenu({required this.onNewPlaylist});

  final VoidCallback onNewPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.read(libraryScanProvider.notifier);
    return NoirMenuButton<String>(
      tooltip: 'Add',
      icon: Icons.add_rounded,
      onSelected: (v) async {
        switch (v) {
          case 'playlist':
            onNewPlaylist();
            final id = await createPlaylist(context, ref);
            if (id != null && context.mounted) {
              context.go('/library/playlist/$id');
            }
          case 'folder':
            await scan.addFolder();
          case 'files':
            await scan.importFiles();
        }
      },
      items: () => [
        const NoirMenuItem(
          'playlist',
          'New playlist',
          icon: Icons.playlist_add_rounded,
        ),
        if (LibraryScanController.supportsFolders)
          const NoirMenuItem(
            'folder',
            'Add music folder…',
            icon: Icons.create_new_folder_outlined,
          ),
        const NoirMenuItem(
          'files',
          'Add files…',
          icon: Icons.library_add_outlined,
        ),
      ],
    );
  }
}

/// Progress / result of the last library change.
class _ScanBanner extends ConsumerWidget {
  const _ScanBanner(this.scan);

  final ScanState scan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final dismiss = ref.read(libraryScanProvider.notifier).dismissResult;
    final (icon, text, closable) = switch (scan) {
      ScanIdle() => (null, null, false),
      Scanning(:final label) => (null, '$label…', false),
      ScanFinished(:final summary) => (
        Icons.check_rounded,
        [
          '${summary.indexed} added or updated',
          if (summary.removed > 0) '${summary.removed} removed',
          if (summary.unreadableTags > 0)
            '${summary.unreadableTags} without readable tags',
        ].join(' · '),
        true,
      ),
      ScanFailed(:final message) => (
        Icons.error_outline_rounded,
        message,
        true,
      ),
    };
    return Reveal(
      visible: text != null,
      child: Padding(
        padding: const EdgeInsets.only(top: NoirSpacing.md),
        child: Row(
          children: [
            if (icon == null)
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon, size: 16),
            const SizedBox(width: NoirSpacing.sm),
            Expanded(child: Text(text ?? '', style: t.bodySmall)),
            if (closable)
              NoirIconButton(
                icon: Icons.close_rounded,
                tooltip: 'Dismiss',
                size: 16,
                onPressed: dismiss,
              ),
          ],
        ),
      ),
    );
  }
}
