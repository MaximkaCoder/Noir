import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/shell/adaptive_shell.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/search/application/music_search_controller.dart';
import 'package:noir/features/search/application/search_controller.dart';
import 'package:noir/features/search/data/search_history_repository.dart';
import 'package:noir/features/search/presentation/music_results.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/widgets/media_tiles.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';
import 'package:noir/shared/widgets/track_row.dart';

enum _Filter { all, artists, albums, tracks, playlists }

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final _controller = TextEditingController(
    text: ref.read(searchProvider).query,
  );
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setQuery(String q) {
    _showText(q);
    ref.read(searchProvider.notifier).setQuery(q);
    final music = ref.read(musicSearchControllerProvider.notifier);
    if (q.trim().isEmpty) {
      music.setQuery(q);
    } else {
      unawaited(music.submit(q));
    }
  }

  void _showText(String q) => _controller.value = TextEditingValue(
    text: q,
    selection: TextSelection.collapsed(offset: q.length),
  );

  void _onChanged(String q) {
    ref.read(searchProvider.notifier).setQuery(q);
    ref.read(musicSearchControllerProvider.notifier).setQuery(q);
  }

  void _onSubmitted(String q) {
    unawaited(ref.read(searchProvider.notifier).commit());
    unawaited(ref.read(musicSearchControllerProvider.notifier).submit(q));
  }

  @override
  Widget build(BuildContext context) {
    // A search started elsewhere (an artist on Home) shows its query here.
    ref.listen(searchProvider.select((s) => s.query), (_, q) {
      if (q != _controller.text) _showText(q);
    });
    final search = ref.watch(searchProvider);
    final results = search.results;
    return PageScaffold(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: NoirSpacing.sm),
            child: _SearchField(
              controller: _controller,
              focusNode: ref.watch(searchFocusProvider),
              onChanged: _onChanged,
              onSubmitted: _onSubmitted,
              onClear: () => _setQuery(''),
            ),
          ),
        ),
        if (search.query.trim().isEmpty)
          ..._history()
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: NoirSpacing.lg),
              child: Wrap(
                spacing: NoirSpacing.xs,
                runSpacing: NoirSpacing.xs,
                children: [
                  for (final f in _Filter.values)
                    PillChip(
                      label: switch (f) {
                        _Filter.all => 'All',
                        _Filter.artists => 'Artists',
                        _Filter.albums => 'Albums',
                        _Filter.tracks => 'Tracks',
                        _Filter.playlists => 'Playlists',
                      },
                      selected: _filter == f,
                      onSelected: () => setState(() => _filter = f),
                    ),
                ],
              ),
            ),
          ),
          if (search.failed)
            const SliverToBoxAdapter(
              child: ErrorState(
                message: 'Search failed. Try a different query.',
                compact: true,
              ),
            )
          else if (results != null)
            ..._results(results)
          else
            const SliverToBoxAdapter(child: LoadingState(rows: 4)),
          const MusicResults(),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: NoirSpacing.xl),
              child: Text(
                'Your library is searched on this device. YouTube Music '
                'results come from its public catalog, without your account.',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _history() {
    final history = ref.watch(searchHistoryProvider).value ?? const <String>[];
    final t = Theme.of(context).textTheme;
    if (history.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.search_rounded,
            title: 'Search your music',
            message: 'Find songs, artists, albums and playlists.',
          ),
        ),
      ];
    }
    final repo = ref.read(searchHistoryRepositoryProvider);
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: NoirSpacing.xl),
          child: SectionHeader(
            'Recent searches',
            action: 'Clear',
            onAction: () => unawaited(repo.clear()),
          ),
        ),
      ),
      SliverList.builder(
        itemCount: history.length,
        itemBuilder: (context, i) => ListTile(
          key: ValueKey(history[i]),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: NoirSpacing.sm,
          ),
          shape: const RoundedRectangleBorder(borderRadius: NoirRadii.mdAll),
          leading: const Icon(Icons.history_rounded, size: 18),
          title: Text(history[i], style: t.bodyMedium),
          trailing: NoirIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Remove from history',
            size: 16,
            onPressed: () => unawaited(repo.remove(history[i])),
          ),
          onTap: () => _setQuery(history[i]),
        ),
      ),
    ];
  }

  List<Widget> _results(SearchResults r) {
    if (r.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No results for "${r.query}"',
            message: 'Check the spelling or try a shorter query.',
            compact: true,
          ),
        ),
      ];
    }
    final playback = ref.read(playbackProvider.notifier);
    final commit = ref.read(searchProvider.notifier).commit;
    bool show(_Filter f) => _filter == _Filter.all || _filter == f;
    final limit = _filter == _Filter.all ? 5 : 1 << 20;

    void openAlbum(Album a) {
      unawaited(commit());
      context.go('/library/album', extra: a);
    }

    void openArtist(Artist a) {
      unawaited(commit());
      context.go('/library/artist', extra: a.name);
    }

    final top = _filter == _Filter.all ? _topResult(r) : null;
    return [
      if (top != null) ...[
        const SliverToBoxAdapter(child: SectionHeader('Top result')),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: NoirSpacing.xl),
            child: _TopResultCard(
              title: top.$1,
              kind: top.$2,
              artwork: top.$3,
              onTap: top.$4,
            ),
          ),
        ),
      ],
      if (show(_Filter.artists) && r.artists.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Artists')),
        SliverList.list(
          children: [
            for (final a in r.artists.take(limit))
              CollectionRow(
                key: ValueKey('a-${a.name}'),
                title: a.name,
                subtitle: songCount(a.trackCount),
                leading: artistAvatar(a.artworkPath, 44),
                onTap: () => openArtist(a),
              ),
          ],
        ),
        const SliverToBoxAdapter(child: SizedBox(height: NoirSpacing.xl)),
      ],
      if (show(_Filter.albums) && r.albums.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Albums')),
        SliverList.list(
          children: [
            for (final a in r.albums.take(limit))
              CollectionRow(
                key: ValueKey('al-${a.title}|${a.artist}'),
                title: a.title,
                subtitle: [
                  a.artist,
                  if (a.year != null) '${a.year}',
                ].join(' · '),
                leading: Artwork(path: a.artworkPath, size: 44),
                onTap: () => openAlbum(a),
              ),
          ],
        ),
        const SliverToBoxAdapter(child: SizedBox(height: NoirSpacing.xl)),
      ],
      if (show(_Filter.tracks) && r.tracks.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Tracks')),
        SliverList.builder(
          itemCount: r.tracks.take(_filter == _Filter.all ? 8 : 1 << 20).length,
          itemBuilder: (context, i) => TrackRow(
            key: ValueKey(r.tracks[i].id),
            track: r.tracks[i],
            onPlay: () {
              unawaited(commit());
              unawaited(playback.playTracks(r.tracks, startIndex: i));
            },
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: NoirSpacing.xl)),
      ],
      if (show(_Filter.playlists) && r.playlists.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SectionHeader('Playlists')),
        SliverList.list(
          children: [
            for (final p in r.playlists.take(limit))
              CollectionRow(
                key: ValueKey('p-${p.id}'),
                title: p.name,
                subtitle: songCount(p.trackCount),
                leading: ArtworkCollage(paths: p.artworkPaths, size: 44),
                onTap: () {
                  unawaited(commit());
                  context.go('/library/playlist/${p.id}');
                },
              ),
          ],
        ),
      ],
    ];
  }

  /// Exact artist match wins, then albums, then the first track.
  (String, String, Widget, VoidCallback)? _topResult(SearchResults r) {
    final q = r.query.toLowerCase();
    final artist =
        r.artists.where((a) => a.name.toLowerCase() == q).firstOrNull ??
        r.artists.firstOrNull;
    if (artist != null) {
      return (
        artist.name,
        'Artist',
        artistAvatar(artist.artworkPath, 64),
        () => context.go('/library/artist', extra: artist.name),
      );
    }
    final album = r.albums.firstOrNull;
    if (album != null) {
      return (
        album.title,
        'Album · ${album.artist}',
        Artwork(path: album.artworkPath, size: 64),
        () => context.go('/library/album', extra: album),
      );
    }
    final track = r.tracks.firstOrNull;
    if (track != null) {
      return (
        track.title,
        'Song · ${track.artistOrUnknown}',
        Artwork(path: track.artwork, size: 64),
        () =>
            unawaited(ref.read(playbackProvider.notifier).playTracks([track])),
      );
    }
    return null;
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    return GlassSurface(
      borderRadius: NoirRadii.pillAll,
      blur: 0,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            const SizedBox(width: 16),
            Icon(Icons.search_rounded, size: 20, color: c.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus:
                    WindowClass.of(MediaQuery.sizeOf(context).width) !=
                    WindowClass.compact,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
                textInputAction: TextInputAction.search,
                style: t.bodyMedium,
                decoration: InputDecoration(
                  hintText: 'Songs, artists, albums, playlists',
                  hintStyle: t.bodySmall,
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: controller,
              builder: (context, value, _) => value.text.isEmpty
                  ? const SizedBox(width: 16)
                  : NoirIconButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Clear search',
                      size: 18,
                      onPressed: onClear,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopResultCard extends StatelessWidget {
  const _TopResultCard({
    required this.title,
    required this.kind,
    required this.artwork,
    required this.onTap,
  });

  final String title;
  final String kind;
  final Widget artwork;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Top result: $title, $kind',
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GlassSurface(
            interactive: true,
            blur: 0,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                artwork,
                const SizedBox(width: NoirSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: t.titleMedium, maxLines: 1),
                      const SizedBox(height: 2),
                      Text(kind, style: t.bodySmall),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: context.noir.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
