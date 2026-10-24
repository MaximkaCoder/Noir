import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/playback_controls.dart';
import 'package:noir/features/queue/presentation/queue_panel.dart';
import 'package:noir/shared/models/playback.dart';

void openNowPlaying(BuildContext context) => context.push('/now-playing');

/// Title + subtitle; the subtitle turns into the error message on failure.
class _NowPlayingText extends StatelessWidget {
  const _NowPlayingText(this.state);

  final PlaybackState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final track = state.current!.track;
    final failed =
        state.status == PlaybackStatus.error ||
        state.status == PlaybackStatus.unavailable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: t.labelLarge,
        ),
        Text(
          failed ? (state.message ?? "Can't play") : track.artistOrUnknown,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: t.labelSmall?.copyWith(
            color: failed ? context.noir.destructive : null,
          ),
        ),
      ],
    );
  }
}

/// Compact card docked at the bottom of the desktop sidebar.
class SidebarPlayerCard extends ConsumerWidget {
  const SidebarPlayerCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playbackProvider);
    if (s.current == null) return const SizedBox.shrink();
    final ctrl = ref.read(playbackProvider.notifier);
    return Semantics(
      label: 'Now playing. Open player',
      child: GestureDetector(
        onTap: () => openNowPlaying(context),
        child: GlassSurface(
          interactive: true,
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Hero(
                    tag: 'now-playing-art',
                    child: Artwork(
                      path: s.current!.track.artworkPath,
                      size: 40,
                    ),
                  ),
                  const SizedBox(width: NoirSpacing.sm + 2),
                  Expanded(child: _NowPlayingText(s)),
                  NoirIconButton(
                    icon: s.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    tooltip: s.isPlaying ? 'Pause' : 'Play',
                    color: context.noir.textPrimary,
                    onPressed: () => unawaited(ctrl.togglePlayPause()),
                  ),
                  NoirIconButton(
                    icon: Icons.skip_next_rounded,
                    tooltip: 'Next',
                    color: context.noir.textPrimary,
                    onPressed: s.hasNext ? () => unawaited(ctrl.next()) : null,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: ProgressLine(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-width bar for medium desktop windows.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playbackProvider);
    if (s.current == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NoirSpacing.md,
        0,
        NoirSpacing.md,
        NoirSpacing.md,
      ),
      child: GlassSurface(
        shadow: 0.6,
        borderRadius: NoirRadii.xlAll,
        padding: const EdgeInsets.symmetric(
          horizontal: NoirSpacing.md,
          vertical: NoirSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => openNowPlaying(context),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Row(
                    children: [
                      Hero(
                        tag: 'now-playing-art',
                        child: Artwork(
                          path: s.current!.track.artworkPath,
                          size: 44,
                        ),
                      ),
                      const SizedBox(width: NoirSpacing.md),
                      Expanded(child: _NowPlayingText(s)),
                    ],
                  ),
                ),
              ),
            ),
            const Flexible(
              flex: 2,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PlaybackControls(),
                  ProgressSlider(showLabels: false),
                ],
              ),
            ),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const Flexible(child: VolumeControl()),
                  NoirIconButton(
                    icon: Icons.queue_music_rounded,
                    tooltip: 'Queue',
                    onPressed: () => openQueue(context, ref),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Floating player above the bottom navigation on phones.
class MobileMiniPlayer extends ConsumerWidget {
  const MobileMiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playbackProvider);
    if (s.current == null) return const SizedBox.shrink();
    final ctrl = ref.read(playbackProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NoirSpacing.sm,
        0,
        NoirSpacing.sm,
        NoirSpacing.sm,
      ),
      child: Semantics(
        label: 'Now playing. Open player',
        child: GestureDetector(
          onTap: () => openNowPlaying(context),
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -200) openNowPlaying(context);
          },
          child: GlassSurface(
            shadow: 0.6,
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Hero(
                      tag: 'now-playing-art',
                      child: Artwork(
                        path: s.current!.track.artworkPath,
                        size: 40,
                      ),
                    ),
                    const SizedBox(width: NoirSpacing.md),
                    Expanded(child: _NowPlayingText(s)),
                    NoirIconButton(
                      icon: s.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      tooltip: s.isPlaying ? 'Pause' : 'Play',
                      size: 26,
                      color: context.noir.textPrimary,
                      onPressed: () => unawaited(ctrl.togglePlayPause()),
                    ),
                    NoirIconButton(
                      icon: Icons.skip_next_rounded,
                      tooltip: 'Next',
                      size: 24,
                      color: context.noir.textPrimary,
                      onPressed: s.hasNext
                          ? () => unawaited(ctrl.next())
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const ProgressLine(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
