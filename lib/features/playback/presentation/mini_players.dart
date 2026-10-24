import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/playback_controls.dart';
import 'package:noir/features/queue/presentation/queue_panel.dart';
import 'package:noir/features/youtube/presentation/save_button.dart';
import 'package:noir/shared/models/media.dart';
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

/// Floating glass player for desktop windows, Spotify-style: track on the
/// left, transport and progress in the center, queue / volume / full player
/// on the right. Slides in when playback starts and out when the queue is
/// cleared; narrower islands drop the volume slider, then the times, then
/// shuffle and repeat.
class PlayerIsland extends ConsumerStatefulWidget {
  const PlayerIsland({super.key});

  @override
  ConsumerState<PlayerIsland> createState() => _PlayerIslandState();
}

class _PlayerIslandState extends ConsumerState<PlayerIsland> {
  /// Last state with a track, so the island leaves with its content.
  PlaybackState? _last;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(playbackProvider);
    final visible = s.current != null;
    if (visible) _last = s;
    final last = _last;
    final fx = NoirEffects.of(context);
    final duration = fx.motion(NoirMotion.layout);
    return ExcludeFocus(
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 1),
          duration: duration,
          curve: visible ? NoirMotion.standard : NoirMotion.exit,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: duration,
            curve: visible ? NoirMotion.standard : NoirMotion.exit,
            child: last == null ? const SizedBox.shrink() : _IslandBar(last),
          ),
        ),
      ),
    );
  }
}

class _IslandBar extends ConsumerWidget {
  const _IslandBar(this.state);

  final PlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fx = NoirEffects.of(context);
    final wide =
        WindowClass.of(MediaQuery.sizeOf(context).width) ==
        WindowClass.expanded;
    final queueOpen = wide && ref.watch(queuePanelOpenProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NoirSpacing.md,
        0,
        NoirSpacing.md,
        NoirSpacing.md,
      ),
      child: GlassSurface(
        borderRadius: NoirRadii.xlAll,
        shadow: 0.8,
        // Content scrolls underneath: a denser fill keeps text legible.
        fillOpacity: fx.glass ? 1.8 : 1,
        highlight: 0.6,
        padding: const EdgeInsets.fromLTRB(
          NoirSpacing.sm + 2,
          NoirSpacing.sm,
          NoirSpacing.sm,
          NoirSpacing.xs,
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            return Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _IslandTrack(state, showFavorite: w >= 520),
                ),
                const SizedBox(width: NoirSpacing.md),
                Expanded(
                  flex: 4,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 600),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PlaybackControls(showModes: w >= 600),
                          ProgressSlider(
                            inlineLabels: true,
                            showLabels: w >= 720,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: NoirSpacing.md),
                Expanded(
                  flex: 3,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _ToggleButton(
                        icon: Icons.queue_music_rounded,
                        tooltip: queueOpen ? 'Hide queue' : 'Queue',
                        active: queueOpen,
                        onPressed: () => openQueue(context, ref),
                      ),
                      Flexible(child: VolumeControl(showSlider: w >= 860)),
                      NoirIconButton(
                        icon: Icons.open_in_full_rounded,
                        tooltip: 'Open player (Ctrl+P)',
                        size: 18,
                        onPressed: () => openNowPlaying(context),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Artwork, title and artist (opens Now Playing) plus the local favorite.
class _IslandTrack extends ConsumerWidget {
  const _IslandTrack(this.state, {required this.showFavorite});

  final PlaybackState state;
  final bool showFavorite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = state.current!.track;
    final fx = NoirEffects.of(context);
    return Row(
      children: [
        Flexible(
          child: Semantics(
            button: true,
            label: 'Now playing. Open player',
            child: GestureDetector(
              onTap: () => openNowPlaying(context),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Hero(
                      tag: 'now-playing-art',
                      child: Artwork(path: track.artwork, size: 48),
                    ),
                    const SizedBox(width: NoirSpacing.md),
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: fx.motion(NoirMotion.medium),
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.centerLeft,
                          children: [...previous, ?current],
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(state.current!.uid),
                          child: _NowPlayingText(state),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // YouTube songs: the heart saves to the user's chosen playlist.
        if (showFavorite && track.source == MediaSource.youtube)
          YouTubeSaveButton(track),
        // Favorites are local; YouTube items have no local id.
        if (showFavorite && track.localId != null)
          AnimatedSwitcher(
            duration: fx.motion(NoirMotion.fast),
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: NoirIconButton(
              key: ValueKey(track.isFavorite),
              icon: track.isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              tooltip: track.isFavorite
                  ? 'Remove from favorites (this device)'
                  : 'Add to favorites (this device)',
              active: track.isFavorite,
              size: 18,
              onPressed: () => unawaited(
                ref.read(playbackProvider.notifier).toggleFavorite(track),
              ),
            ),
          ),
      ],
    );
  }
}

/// Icon button with a soft filled background while [active].
class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    return Semantics(
      toggled: active,
      child: AnimatedContainer(
        duration: NoirEffects.of(context).motion(NoirMotion.fast),
        curve: NoirMotion.standard,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? c.selected : Colors.transparent,
        ),
        child: NoirIconButton(
          icon: icon,
          tooltip: tooltip,
          active: active,
          size: 18,
          onPressed: onPressed,
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
                      child: Artwork(path: s.current!.track.artwork, size: 40),
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
