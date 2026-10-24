import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/liquid_glass.dart';
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [_Title(state), _Subtitle(state)],
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.state, {super.key});

  final PlaybackState state;

  @override
  Widget build(BuildContext context) {
    return Text(
      state.current!.track.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelLarge,
    );
  }
}

/// The artist, or the error message on failure.
class _Subtitle extends StatelessWidget {
  const _Subtitle(this.state, {super.key});

  final PlaybackState state;

  @override
  Widget build(BuildContext context) {
    final failed =
        state.status == PlaybackStatus.error ||
        state.status == PlaybackStatus.unavailable;
    return Text(
      failed
          ? (state.message ?? "Can't play")
          : state.current!.track.artistOrUnknown,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: failed ? context.noir.destructive : null),
    );
  }
}

/// Floating Liquid Glass capsule for desktop windows, Apple Music-style:
/// transport on the left; artwork, title and a hairline progress in the
/// middle (hovering thickens the line and swaps the artist for the times);
/// favorite, queue, volume and the full player on the right. Centered and
/// at most [maxWidth] wide. Slides in when playback starts and out when the
/// queue is cleared; narrower capsules drop the volume slider, then shuffle
/// and repeat, then the favorite.
class PlayerIsland extends ConsumerStatefulWidget {
  const PlayerIsland({super.key});

  static const double maxWidth = 900;

  /// The progress line, for tests.
  static const progressKey = ValueKey('player-island-progress');

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
    final wide =
        WindowClass.of(MediaQuery.sizeOf(context).width) ==
        WindowClass.expanded;
    final queueOpen = wide && ref.watch(queuePanelOpenProvider);
    final track = state.current!.track;
    final artwork = track.artwork;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NoirSpacing.lg,
        0,
        NoirSpacing.lg,
        NoirSpacing.lg,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: PlayerIsland.maxWidth),
          child: LiquidGlass(
            tintImage: artwork == null
                ? null
                : isRemoteImage(artwork)
                ? NetworkImage(artwork)
                : FileImage(File(artwork)) as ImageProvider,
            padding: const EdgeInsets.symmetric(
              horizontal: NoirSpacing.md + 2,
              vertical: NoirSpacing.xxs,
            ),
            child: LayoutBuilder(
              builder: (context, box) {
                final w = box.maxWidth;
                return Row(
                  children: [
                    PlaybackControls(showModes: w >= 640),
                    const _IslandDivider(),
                    Expanded(child: _IslandNowPlaying(state)),
                    const _IslandDivider(),
                    if (w >= 520) _FavoriteButton(track),
                    _ToggleButton(
                      icon: Icons.queue_music_rounded,
                      tooltip: queueOpen ? 'Hide queue' : 'Queue',
                      active: queueOpen,
                      onPressed: () => openQueue(context, ref),
                    ),
                    VolumeControl(showSlider: w >= 860),
                    NoirIconButton(
                      icon: Icons.open_in_full_rounded,
                      tooltip: 'Open player (Ctrl+P)',
                      size: 18,
                      onPressed: () => openNowPlaying(context),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _IslandDivider extends StatelessWidget {
  const _IslandDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: NoirSpacing.sm + 2),
      color: context.noir.glassBorder,
    );
  }
}

/// Heart: saves YouTube songs to the chosen playlist; a local favorite
/// otherwise (YouTube items have no local id).
class _FavoriteButton extends ConsumerWidget {
  const _FavoriteButton(this.track);

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (track.source == MediaSource.youtube) return YouTubeSaveButton(track);
    if (track.localId == null) return const SizedBox.shrink();
    return AnimatedSwitcher(
      duration: NoirEffects.of(context).motion(NoirMotion.fast),
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
    );
  }
}

/// Artwork, title and artist (opens Now Playing) over a hairline progress
/// along the capsule's bottom edge. The whole block is the hover target, so
/// the 2 px line never has to be hit precisely to reveal the times.
class _IslandNowPlaying extends StatefulWidget {
  const _IslandNowPlaying(this.state);

  final PlaybackState state;

  @override
  State<_IslandNowPlaying> createState() => _IslandNowPlayingState();
}

class _IslandNowPlayingState extends State<_IslandNowPlaying> {
  /// Height of the progress line's hit area; mirrored above the content so
  /// it stays centered on the capsule's axis.
  static const double _lineBox = 12;

  bool _hovered = false;
  bool _scrubbing = false;

  /// Progress fraction while dragging, shown before the seek lands.
  final _scrub = ValueNotifier<double?>(null);

  @override
  void dispose() {
    _scrub.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final uid = state.current!.uid;
    final fx = NoirEffects.of(context);
    final reveal = _hovered || _scrubbing;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: _lineBox),
            child: Semantics(
              button: true,
              label: 'Now playing. Open player',
              child: GestureDetector(
                onTap: () => openNowPlaying(context),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Row(
                    children: [
                      Hero(
                        tag: 'now-playing-art',
                        child: Artwork(
                          path: state.current!.track.artwork,
                          size: 36,
                        ),
                      ),
                      const SizedBox(width: NoirSpacing.sm + 2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _Swap(
                              duration: fx.motion(NoirMotion.medium),
                              child: _Title(state, key: ValueKey(uid)),
                            ),
                            _Swap(
                              duration: fx.motion(NoirMotion.fast),
                              child: reveal
                                  ? _IslandTimes(
                                      _scrub,
                                      key: const ValueKey('times'),
                                    )
                                  : _Subtitle(state, key: ValueKey(uid)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _lineBox,
            child: RepaintBoundary(
              child: _IslandProgress(
                reveal: reveal,
                scrub: _scrub,
                onScrubbing: (v) => setState(() => _scrubbing = v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cross-fade that keeps the outgoing child left-aligned.
class _Swap extends StatelessWidget {
  const _Swap({required this.duration, required this.child});

  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      child: child,
    );
  }
}

/// Position and duration, falling back to the engine and the track before
/// the streams report.
(Duration, Duration) _progressOf(WidgetRef ref) {
  final engine = ref.watch(playbackEngineProvider);
  final track = ref.watch(playbackProvider.select((s) => s.current?.track));
  final position = ref.watch(positionProvider).value ?? engine.currentPosition;
  final duration =
      ref.watch(durationProvider).value ??
      engine.currentDuration ??
      track?.duration ??
      Duration.zero;
  return (position, duration);
}

/// Elapsed and remaining time, in place of the artist while hovered.
class _IslandTimes extends ConsumerWidget {
  const _IslandTimes(this.scrub, {super.key});

  final ValueListenable<double?> scrub;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (position, duration) = _progressOf(ref);
    final t = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontFeatures: tabularFigures,
      color: context.noir.textSecondary,
    );
    return ValueListenableBuilder<double?>(
      valueListenable: scrub,
      builder: (context, fraction, _) {
        var shown = fraction == null ? position : duration * fraction;
        if (shown > duration) shown = duration;
        return Row(
          children: [
            Text(formatClock(shown), style: t),
            const Spacer(),
            Text('-${formatClock(duration - shown)}', style: t),
          ],
        );
      },
    );
  }
}

/// Hairline progress, thicker while [reveal]. Click to seek; drag to scrub
/// (the seek lands on release). Only this and [_IslandTimes] rebuild on
/// position ticks.
class _IslandProgress extends ConsumerWidget {
  const _IslandProgress({
    required this.reveal,
    required this.scrub,
    required this.onScrubbing,
  });

  final bool reveal;
  final ValueNotifier<double?> scrub;
  final ValueChanged<bool> onScrubbing;

  static const _step = Duration(seconds: 5);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    final (position, duration) = _progressOf(ref);
    final canSeek =
        ref.watch(playbackProvider.select((s) => s.capabilities.canSeek)) &&
        duration > Duration.zero;
    final progress = duration > Duration.zero
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    Duration within(Duration d) => d < Duration.zero
        ? Duration.zero
        : d > duration
        ? duration
        : d;
    void seek(Duration to) =>
        unawaited(ref.read(playbackProvider.notifier).seek(within(to)));
    String clock(Duration d) => formatClock(within(d));
    void stopScrubbing() {
      scrub.value = null;
      onScrubbing(false);
    }

    return LayoutBuilder(
      builder: (context, box) {
        double at(Offset p) => (p.dx / box.maxWidth).clamp(0.0, 1.0);
        return Semantics(
          slider: true,
          label: 'Playback position',
          value: '${clock(position)} of ${clock(duration)}',
          increasedValue: '${clock(position + _step)} of ${clock(duration)}',
          decreasedValue: '${clock(position - _step)} of ${clock(duration)}',
          onIncrease: canSeek ? () => seek(position + _step) : null,
          onDecrease: canSeek ? () => seek(position - _step) : null,
          child: MouseRegion(
            cursor: canSeek ? SystemMouseCursors.click : MouseCursor.defer,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: canSeek
                  ? (d) => seek(duration * at(d.localPosition))
                  : null,
              onHorizontalDragStart: canSeek
                  ? (d) {
                      onScrubbing(true);
                      scrub.value = at(d.localPosition);
                    }
                  : null,
              onHorizontalDragUpdate: canSeek
                  ? (d) => scrub.value = at(d.localPosition)
                  : null,
              onHorizontalDragEnd: canSeek
                  ? (_) {
                      final f = scrub.value;
                      stopScrubbing();
                      if (f != null) seek(duration * f);
                    }
                  : null,
              onHorizontalDragCancel: canSeek ? stopScrubbing : null,
              child: Center(
                child: ValueListenableBuilder<double?>(
                  valueListenable: scrub,
                  builder: (context, fraction, _) => AnimatedContainer(
                    key: PlayerIsland.progressKey,
                    duration: fx.motion(NoirMotion.fast),
                    curve: NoirMotion.standard,
                    width: double.infinity,
                    height: reveal ? 4 : 2,
                    decoration: BoxDecoration(
                      color: c.textPrimary.withValues(alpha: 0.16),
                      borderRadius: NoirRadii.pillAll,
                    ),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: fraction ?? progress,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: c.textPrimary.withValues(
                            alpha: reveal ? 0.95 : 0.75,
                          ),
                          borderRadius: NoirRadii.pillAll,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
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
