import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/noir_backdrop.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/playback_controls.dart';
import 'package:noir/features/playback/presentation/youtube_video_layer.dart';
import 'package:noir/features/playlists/presentation/add_to_playlist.dart';
import 'package:noir/features/queue/presentation/queue_panel.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/presentation/youtube_cover.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';
import 'package:url_launcher/url_launcher.dart';

/// NOIR's signature screen: large artwork, title, progress, transport and
/// what plays next. Dismiss with the chevron, Esc, or a downward swipe.
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playbackProvider);
    final current = s.current;
    void close() => Navigator.of(context).maybePop();

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              NoirBackdrop(artworkPath: current?.track.artwork),
              SafeArea(
                child: GestureDetector(
                  onVerticalDragEnd: (d) {
                    if ((d.primaryVelocity ?? 0) > 400) close();
                  },
                  child: Column(
                    children: [
                      _TopBar(onClose: close, state: s),
                      Expanded(
                        child: current == null
                            ? const EmptyState(
                                icon: Icons.music_off_rounded,
                                title: 'Nothing playing',
                                message:
                                    'Pick a song from your library to start.',
                              )
                            : LayoutBuilder(
                                builder: (context, box) => box.maxWidth >= 760
                                    ? _WideLayout(state: s, box: box)
                                    : _NarrowLayout(state: s, box: box),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.onClose, required this.state});

  final VoidCallback onClose;
  final PlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = state.current?.track;
    return WindowDragArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(
          children: [
            if (reservesWindowControlsSpace) const SizedBox(width: 72),
            NoirIconButton(
              icon: Icons.keyboard_arrow_down_rounded,
              tooltip: 'Close player (Esc)',
              size: 26,
              onPressed: onClose,
            ),
            const Spacer(),
            if (track != null && track.localId != null)
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: Icon(
                  Icons.more_horiz_rounded,
                  color: context.noir.textSecondary,
                ),
                onSelected: (v) async {
                  if (v == 'playlist') {
                    await addToPlaylist(context, ref, [track]);
                  }
                  if (v == 'queue' && context.mounted) openQueue(context, ref);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'playlist',
                    child: Text('Add to playlist…'),
                  ),
                  PopupMenuItem(value: 'queue', child: Text('Show queue')),
                ],
              ),
            if (usesCustomWindowChrome) ...[
              const SizedBox(width: NoirSpacing.sm),
              const WindowControls(),
            ],
          ],
        ),
      ),
    );
  }
}

class _WideLayout extends ConsumerWidget {
  const _WideLayout({required this.state, required this.box});

  final PlaybackState state;
  final BoxConstraints box;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final art = (box.maxWidth * 0.32).clamp(240.0, 420.0);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _LargeArtwork(state: state, size: art),
                  const SizedBox(width: 48),
                  Expanded(child: _TrackInfo(state: state, large: true)),
                ],
              ),
              const SizedBox(height: 36),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [PlaybackControls(large: true)],
              ),
              const SizedBox(height: 8),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [VolumeControl()],
              ),
              const SizedBox(height: 28),
              _UpNext(state: state),
            ],
          ),
        ),
      ),
    );
  }
}

class _NarrowLayout extends ConsumerWidget {
  const _NarrowLayout({required this.state, required this.box});

  final PlaybackState state;
  final BoxConstraints box;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidePlayer = ref.watch(
      settingsProvider.select((s) => s.hideYouTubePlayer),
    );
    final art = (box.maxWidth - 48).clamp(160.0, box.maxHeight * 0.45);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Column(
        children: [
          const SizedBox(height: 8),
          _LargeArtwork(state: state, size: art),
          const SizedBox(height: 28),
          _TrackInfo(state: state, large: false),
          const SizedBox(height: 20),
          const PlaybackControls(large: true),
          if (state.current!.track.source == MediaSource.youtube &&
              !hidePlayer) ...[
            const SizedBox(height: 24),
            const _YouTubePlayerTile(),
          ],
          const SizedBox(height: 24),
          _UpNext(state: state),
        ],
      ),
    );
  }
}

class _LargeArtwork extends StatelessWidget {
  const _LargeArtwork({required this.state, required this.size});

  final PlaybackState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final track = state.current!.track;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NoirRadii.xlAll,
        boxShadow: [
          BoxShadow(
            color: context.noir.shadow,
            blurRadius: 48,
            offset: const Offset(0, 24),
          ),
        ],
      ),
      child: Hero(
        tag: 'now-playing-art',
        child: track.source == MediaSource.youtube
            ? YouTubeCover(videoId: track.uri, size: size)
            : Artwork(
                path: track.artwork,
                size: size,
                radius: NoirRadii.xl,
                semanticLabel: 'Artwork for ${track.album ?? track.title}',
              ),
      ),
    );
  }
}

class _TrackInfo extends ConsumerWidget {
  const _TrackInfo({required this.state, required this.large});

  final PlaybackState state;
  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    final track = state.current!.track;
    final failed =
        state.status == PlaybackStatus.error ||
        state.status == PlaybackStatus.unavailable;
    return Column(
      crossAxisAlignment: large
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: large ? t.displaySmall : t.headlineSmall,
              ),
            ),
            if (track.localId != null)
              NoirIconButton(
                icon: track.isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                tooltip: track.isFavorite
                    ? 'Remove from favorites (this device)'
                    : 'Add to favorites (this device)',
                active: track.isFavorite,
                onPressed: () => unawaited(
                  ref.read(playbackProvider.notifier).toggleFavorite(track),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          track.artistOrUnknown,
          style: t.titleMedium?.copyWith(
            color: c.textSecondary,
            fontWeight: FontWeight.w400,
          ),
        ),
        if (track.album != null) ...[
          const SizedBox(height: 4),
          Text(
            track.album!,
            style: t.bodyLarge?.copyWith(color: c.textTertiary),
          ),
        ],
        if (track.source == MediaSource.youtube) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.smart_display_outlined,
                size: 16,
                color: c.textSecondary,
              ),
              const SizedBox(width: 6),
              Text('Playing from YouTube', style: t.labelMedium),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => unawaited(
                  launchUrl(
                    youTubeMusicUrl(videoId: track.uri),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: c.textPrimary,
                  textStyle: t.labelMedium,
                ),
                child: const Text('Open in YouTube Music'),
              ),
            ],
          ),
        ],
        if (failed) ...[
          const SizedBox(height: 12),
          Text(
            state.message ?? "This item can't be played.",
            style: t.bodySmall?.copyWith(color: c.destructive),
          ),
        ],
        SizedBox(height: large ? 28 : 20),
        const ProgressSlider(),
        if (large &&
            track.source == MediaSource.youtube &&
            !ref.watch(
              settingsProvider.select((s) => s.hideYouTubePlayer),
            )) ...[
          const SizedBox(height: 20),
          const _YouTubePlayerTile(),
        ],
      ],
    );
  }
}

/// YouTube requires its player to stay visible (≥ 200×200, nothing on top)
/// while it plays, so NOIR keeps a compact player next to the cover.
class _YouTubePlayerTile extends StatelessWidget {
  const _YouTubePlayerTile();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final width = YouTubeVideoLayer.miniSize.width.clamp(
          200.0,
          box.maxWidth,
        );
        return Align(
          alignment: Alignment.centerLeft,
          child: VideoSlot(
            size: Size(width, YouTubeVideoLayer.miniSize.height),
          ),
        );
      },
    );
  }
}

class _UpNext extends ConsumerWidget {
  const _UpNext({required this.state});

  final PlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final upcoming = state.upcoming.take(5).toList();
    if (upcoming.isEmpty) return const SizedBox.shrink();
    final start = state.index! + 1;
    return GlassSurface(
      borderRadius: NoirRadii.xlAll,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Up next', style: t.labelLarge)),
              TextButton(
                onPressed: () => openQueue(context, ref),
                style: TextButton.styleFrom(
                  foregroundColor: context.noir.textSecondary,
                  textStyle: t.labelMedium,
                ),
                child: const Text('Open queue'),
              ),
            ],
          ),
          for (final (i, item) in upcoming.indexed)
            InkWell(
              key: ValueKey(item.uid),
              borderRadius: NoirRadii.mdAll,
              onTap: () => unawaited(
                ref.read(playbackProvider.notifier).jumpTo(start + i),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${i + 1}',
                        style: t.bodySmall?.copyWith(
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ),
                    Artwork(path: item.track.artwork, size: 40, radius: 6),
                    const SizedBox(width: NoirSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodyMedium,
                          ),
                          Text(
                            item.track.artistOrUnknown,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (item.track.duration != null)
                      Text(
                        formatClock(item.track.duration!),
                        style: t.bodySmall?.copyWith(
                          fontFeatures: tabularFigures,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
