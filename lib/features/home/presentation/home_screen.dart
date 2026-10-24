import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/library/application/library_providers.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playlists/application/playlist_providers.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/widgets/media_tiles.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';

/// Quiet, editorial start page built only from the user's own data.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(trackCountProvider);
    return switch (count) {
      AsyncData(value: 0) => const _Welcome(),
      AsyncError() => const ErrorState(
        message:
            "Your library couldn't be opened. Restart NOIR; if it keeps "
            'happening, export diagnostics from Settings → About.',
      ),
      AsyncData() => const _Dashboard(),
      _ => const SizedBox.shrink(),
    };
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

class _Dashboard extends ConsumerWidget {
  const _Dashboard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentTracksProvider).value ?? const <Track>[];
    final playlists = ref.watch(playlistsProvider).value ?? const <Playlist>[];
    final albums = ref.watch(albumsProvider).value ?? const <Album>[];
    final compact =
        WindowClass.of(MediaQuery.sizeOf(context).width) == WindowClass.compact;
    final tile = compact ? 128.0 : 150.0;

    // Distinct albums (or loose tracks) in order of last play.
    final recentItems = <Track>[];
    final seenAlbums = <String>{};
    for (final t in recent) {
      if (t.album == null || seenAlbums.add('${t.album}|${t.artist}')) {
        recentItems.add(t);
      }
    }

    return PageScaffold(
      slivers: [
        const SliverToBoxAdapter(
          child: _Greeting(subtitle: "Here's what's playing today."),
        ),
        SliverToBoxAdapter(
          child: _HeroRow(resume: recent.firstOrNull, compact: compact),
        ),
        if (recentItems.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 36)),
          SliverToBoxAdapter(
            child: SectionHeader(
              'Recently played',
              action: 'See all',
              onAction: () => context.go('/library'),
            ),
          ),
          SliverToBoxAdapter(
            child: TileRow(
              tileWidth: tile,
              children: [
                for (final t in recentItems)
                  MediaTile(
                    key: ValueKey(t.id),
                    width: tile,
                    title: t.album ?? t.title,
                    subtitle: t.artistOrUnknown,
                    artwork: (s) => Artwork(path: t.artworkPath, size: s),
                    onTap: () => _openRecent(context, ref, t),
                  ),
              ],
            ),
          ),
        ],
        if (playlists.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
          const SliverToBoxAdapter(child: SectionHeader('Your playlists')),
          SliverToBoxAdapter(
            child: TileRow(
              tileWidth: tile,
              children: [
                for (final p in playlists)
                  MediaTile(
                    key: ValueKey(p.id),
                    width: tile,
                    title: p.name,
                    subtitle: songCount(p.trackCount),
                    artwork: (s) =>
                        ArtworkCollage(paths: p.artworkPaths, size: s),
                    onTap: () => context.go('/library/playlist/${p.id}'),
                  ),
              ],
            ),
          ),
        ],
        if (albums.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
          SliverToBoxAdapter(
            child: SectionHeader(
              'Albums',
              action: 'See all',
              onAction: () => context.go('/library?tab=albums'),
            ),
          ),
          SliverToBoxAdapter(
            child: TileRow(
              tileWidth: tile,
              children: [
                for (final a in albums.take(20))
                  MediaTile(
                    key: ValueKey('${a.title}|${a.artist}'),
                    width: tile,
                    title: a.title,
                    subtitle: a.artist,
                    artwork: (s) => Artwork(path: a.artworkPath, size: s),
                    onTap: () => context.go('/library/album', extra: a),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  void _openRecent(BuildContext context, WidgetRef ref, Track t) {
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

/// Wide "continue listening" card plus a smaller shuffle card.
class _HeroRow extends ConsumerWidget {
  const _HeroRow({required this.resume, required this.compact});

  final Track? resume;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.read(playbackProvider.notifier);
    final current = ref.watch(playbackProvider.select((s) => s.current?.track));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.isPlaying));
    final hero = current ?? resume;
    final count = ref.watch(trackCountProvider).value ?? 0;

    final main = hero == null
        ? null
        : _HeroCard(
            artworkPath: hero.artworkPath,
            title: hero.title,
            subtitle: current != null
                ? '${hero.artistOrUnknown} · now playing'
                : '${hero.artistOrUnknown} · pick up where you left off',
            playing: current != null && isPlaying,
            onPlay: () async {
              if (current != null) {
                await playback.togglePlayPause();
              } else {
                await playback.playTracks([hero]);
              }
            },
          );
    final shuffle = _SmallCard(
      title: 'Shuffle library',
      subtitle: songCount(count),
      icon: Icons.shuffle_rounded,
      onTap: () async {
        final all = await ref
            .read(libraryRepositoryProvider)
            .watchTracks()
            .first;
        await playback.shuffleTracks(all);
      },
    );

    if (compact || main == null) {
      return Column(
        children: [
          ?main,
          if (main != null) const SizedBox(height: NoirSpacing.md),
          shuffle,
        ],
      );
    }
    return SizedBox(
      height: 120 + MediaQuery.textScalerOf(context).scale(52),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 7, child: main),
          const SizedBox(width: NoirSpacing.lg),
          Expanded(flex: 3, child: shuffle),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.artworkPath,
    required this.title,
    required this.subtitle,
    required this.playing,
    required this.onPlay,
  });

  final String? artworkPath;
  final String title;
  final String subtitle;
  final bool playing;
  final Future<void> Function() onPlay;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      container: true,
      label: 'Continue listening: $title',
      child: ClipRRect(
        borderRadius: NoirRadii.xlAll,
        child: SizedBox(
          height: 120 + MediaQuery.textScalerOf(context).scale(52),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (artworkPath != null)
                Image.file(
                  File(artworkPath!),
                  fit: BoxFit.cover,
                  cacheWidth: (720 * dpr).round(),
                  color: Colors.black.withValues(alpha: 0.35),
                  colorBlendMode: BlendMode.darken,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              else
                ColoredBox(color: context.noir.surfaceElevated),
              // Scrim keeps the white text readable on any artwork.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xCC000000), Color(0x00000000)],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: NoirRadii.xlAll,
                  border: Border.all(color: context.noir.glassBorder),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.titleMedium?.copyWith(color: Colors.white),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodySmall?.copyWith(
                              color: Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Theme(
                      data: Theme.of(context)
                          .copyWith(extensions: [NoirPalette.dark]),
                      child: PrimaryPlayButton(
                        playing: playing,
                        onPressed: () => unawaited(onPlay()),
                        size: 44,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallCard extends StatelessWidget {
  const _SmallCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '$title, $subtitle',
      child: GestureDetector(
        onTap: () => unawaited(onTap()),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GlassSurface(
            interactive: true,
            borderRadius: NoirRadii.xlAll,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: context.noir.textSecondary),
                const SizedBox(height: NoirSpacing.xl),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: t.titleSmall),
                          const SizedBox(height: 2),
                          Text(subtitle, style: t.labelSmall),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 18,
                      color: context.noir.textSecondary,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// First launch / empty library.
class _Welcome extends ConsumerWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scan = ref.watch(libraryScanProvider);
    final ctrl = ref.read(libraryScanProvider.notifier);
    return PageScaffold(
      slivers: [
        const SliverToBoxAdapter(
          child: _Greeting(subtitle: 'Less interface. More music.'),
        ),
        SliverToBoxAdapter(
          child: GlassSurface(
            borderRadius: NoirRadii.xlAll,
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bring your music', style: t.titleLarge),
                const SizedBox(height: NoirSpacing.sm),
                Text(
                  'NOIR plays audio files you own. Choose a folder and NOIR '
                  'indexes it on this device — nothing is uploaded.',
                  style: t.bodyLarge,
                ),
                const SizedBox(height: NoirSpacing.xl),
                if (scan is Scanning)
                  Row(
                    children: [
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: NoirSpacing.md),
                      Text(scan.label, style: t.bodyMedium),
                    ],
                  )
                else
                  Wrap(
                    spacing: NoirSpacing.md,
                    runSpacing: NoirSpacing.md,
                    children: [
                      if (LibraryScanController.supportsFolders)
                        PillButton(
                          label: 'Choose a music folder',
                          icon: Icons.create_new_folder_outlined,
                          filled: true,
                          onPressed: () => unawaited(ctrl.addFolder()),
                        ),
                      PillButton(
                        label: 'Add files',
                        icon: Icons.library_add_outlined,
                        filled: !LibraryScanController.supportsFolders,
                        onPressed: () => unawaited(ctrl.importFiles()),
                      ),
                    ],
                  ),
                if (scan case ScanFailed(:final message)) ...[
                  const SizedBox(height: NoirSpacing.lg),
                  Text(
                    message,
                    style: t.bodySmall?.copyWith(
                      color: context.noir.destructive,
                    ),
                  ),
                ],
                if (scan case ScanFinished(:final summary)
                    when summary.indexed == 0) ...[
                  const SizedBox(height: NoirSpacing.lg),
                  Text(
                    'No supported audio files were found there. NOIR reads '
                    'MP3, M4A, AAC, FLAC, OGG, Opus and WAV.',
                    style: t.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: NoirSpacing.lg)),
        SliverToBoxAdapter(
          child: Text(
            'Google / YouTube connection is planned for a later version. '
            'See Settings → Accounts for what it will and will not be able '
            'to do.',
            style: t.bodySmall,
          ),
        ),
      ],
    );
  }
}
