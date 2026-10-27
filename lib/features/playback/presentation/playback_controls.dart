import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/mix_mode_button.dart';
import 'package:noir/shared/models/playback.dart';

/// Shuffle · previous · play/pause · next · repeat · transitions. Controls the active
/// engine cannot honor are not rendered at all.
class PlaybackControls extends ConsumerWidget {
  const PlaybackControls({
    this.large = false,
    this.showModes = true,
    super.key,
  });

  final bool large;

  /// Shuffle, repeat and transitions.
  final bool showModes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playbackProvider);
    final ctrl = ref.read(playbackProvider.notifier);
    final caps = s.capabilities;
    final hasItem = s.current != null;
    final icon = large ? 28.0 : 22.0;
    final gap = SizedBox(width: large ? NoirSpacing.xl : NoirSpacing.sm);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showModes && caps.canShuffle) ...[
          NoirIconButton(
            icon: Icons.shuffle_rounded,
            tooltip: s.shuffle ? 'Shuffle on' : 'Shuffle off',
            active: s.shuffle,
            size: icon - 4,
            onPressed: hasItem ? ctrl.toggleShuffle : null,
          ),
          gap,
        ],
        if (caps.canSkip) ...[
          NoirIconButton(
            icon: Icons.skip_previous_rounded,
            tooltip: 'Previous',
            size: icon,
            color: context.noir.textPrimary,
            onPressed: hasItem ? () => unawaited(ctrl.previous()) : null,
          ),
          gap,
        ],
        PrimaryPlayButton(
          playing: s.isPlaying,
          size: large ? 64 : 40,
          onPressed: hasItem ? () => unawaited(ctrl.togglePlayPause()) : null,
        ),
        if (caps.canSkip) ...[
          gap,
          NoirIconButton(
            icon: Icons.skip_next_rounded,
            tooltip: 'Next',
            size: icon,
            color: context.noir.textPrimary,
            onPressed: s.hasNext ? () => unawaited(ctrl.next()) : null,
          ),
        ],
        if (showModes && caps.canRepeat) ...[
          gap,
          NoirIconButton(
            icon: s.repeat == RepeatMode.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            tooltip: switch (s.repeat) {
              RepeatMode.off => 'Repeat off',
              RepeatMode.all => 'Repeat all',
              RepeatMode.one => 'Repeat one',
            },
            active: s.repeat != RepeatMode.off,
            size: icon - 4,
            onPressed: hasItem ? ctrl.cycleRepeat : null,
          ),
        ],
        if (showModes) ...[gap, MixModeButton(size: icon - 4)],
      ],
    );
  }
}

/// Seekable progress with elapsed / remaining time. Only this widget
/// rebuilds on position ticks.
class ProgressSlider extends ConsumerStatefulWidget {
  const ProgressSlider({
    this.showLabels = true,
    this.inlineLabels = false,
    super.key,
  });

  final bool showLabels;

  /// Times beside a thin bar whose thumb appears on hover (player island)
  /// instead of below it.
  final bool inlineLabels;

  @override
  ConsumerState<ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends ConsumerState<ProgressSlider>
    with SingleTickerProviderStateMixin {
  double? _dragMs;
  bool _hovered = false;

  /// Glides the thumb and times back to the start when another queue item
  /// starts, instead of jumping; then they follow the position again.
  late final AnimationController _rewind = AnimationController(
    vsync: this,
    value: 1,
  )..addListener(() => setState(() {}));
  double _rewindFromMs = 0;

  /// The position last drawn.
  double _shownMs = 0;

  static const _rewindTime = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    ref.listenManual(playbackProvider.select((s) => s.current?.uid), (
      previous,
      next,
    ) {
      if (previous == null || next == null || previous == next) return;
      final duration = NoirEffects.of(context).motion(_rewindTime);
      if (duration == Duration.zero || _shownMs == 0 || _dragMs != null) {
        return;
      }
      _rewindFromMs = _shownMs;
      _rewind
        ..duration = duration
        ..forward(from: 0);
    });
  }

  @override
  void dispose() {
    _rewind.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(playbackEngineProvider);
    final track = ref.watch(playbackProvider.select((s) => s.current?.track));
    final canSeek = ref.watch(
      playbackProvider.select((s) => s.capabilities.canSeek),
    );
    final position =
        ref.watch(positionProvider).value ?? engine.currentPosition;
    final duration =
        ref.watch(durationProvider).value ??
        engine.currentDuration ??
        track?.duration ??
        Duration.zero;

    final maxMs = duration.inMilliseconds.toDouble();
    final liveMs = _dragMs ?? position.inMilliseconds.toDouble();
    final valueMs =
        (_rewind.isAnimating
                ? lerpDouble(
                    _rewindFromMs,
                    liveMs,
                    NoirMotion.standard.transform(_rewind.value),
                  )!
                : liveMs)
            .clamp(0.0, maxMs > 0 ? maxMs : 0.0);
    _shownMs = valueMs;
    final t = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontFeatures: tabularFigures,
      color: context.noir.textSecondary,
    );
    final shown = Duration(milliseconds: valueMs.round());

    final slider = Semantics(
      label: 'Playback position',
      value: '${formatClock(shown)} of ${formatClock(duration)}',
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          thumbShape: RoundSliderThumbShape(
            enabledThumbRadius: _dragMs != null
                ? 7
                : !widget.inlineLabels
                ? 5
                : _hovered
                ? 6
                : 0,
            disabledThumbRadius: widget.inlineLabels ? 0 : null,
          ),
        ),
        child: Slider(
          value: valueMs,
          max: maxMs > 0 ? maxMs : 1,
          onChanged: canSeek && maxMs > 0
              ? (v) => setState(() {
                  // Seeking is never animated.
                  _rewind.value = 1;
                  _dragMs = v;
                })
              : null,
          onChangeEnd: canSeek && maxMs > 0
              ? (v) {
                  unawaited(
                    ref
                        .read(playbackProvider.notifier)
                        .seek(Duration(milliseconds: v.round())),
                  );
                  setState(() => _dragMs = null);
                }
              : null,
        ),
      ),
    );
    if (widget.inlineLabels) {
      return MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Row(
          children: [
            if (widget.showLabels)
              Text(formatClock(shown), style: t, textAlign: TextAlign.end),
            Expanded(child: slider),
            if (widget.showLabels)
              Text('-${formatClock(duration - shown)}', style: t),
          ],
        ),
      );
    }
    if (!widget.showLabels) return slider;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        slider,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NoirSpacing.lg),
          child: Row(
            children: [
              Text(formatClock(shown), style: t),
              const Spacer(),
              Text('-${formatClock(duration - shown)}', style: t),
            ],
          ),
        ),
      ],
    );
  }
}

/// Thin, non-interactive progress line for compact players.
class ProgressLine extends ConsumerWidget {
  const ProgressLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(playbackEngineProvider);
    final position =
        ref.watch(positionProvider).value ?? engine.currentPosition;
    final duration =
        ref.watch(durationProvider).value ?? engine.currentDuration;
    final value = duration == null || duration == Duration.zero
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    return ExcludeSemantics(
      child: LinearProgressIndicator(
        value: value,
        minHeight: 2,
        borderRadius: NoirRadii.pillAll,
      ),
    );
  }
}

/// Mute toggle and volume slider. Scrolling the mouse wheel over it glides
/// the volume up or down a [wheelStep] per notch; the page underneath does
/// not scroll meanwhile.
class VolumeControl extends ConsumerStatefulWidget {
  const VolumeControl({this.showSlider = true, super.key});

  /// Without the slider only the mute toggle remains (narrow layouts).
  final bool showSlider;

  static const double wheelStep = 0.05;

  @override
  ConsumerState<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends ConsumerState<VolumeControl>
    with SingleTickerProviderStateMixin {
  late final _glide = AnimationController(vsync: this)..addListener(_onGlide);
  double _from = 0;

  /// Where the wheel is heading; further notches add to it mid-glide.
  double _to = 0;

  @override
  void dispose() {
    _glide.dispose();
    super.dispose();
  }

  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    // Claims the event, so no scrollable underneath also takes it.
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final up = (event as PointerScrollEvent).scrollDelta.dy < 0;
      final volume = ref.read(playbackProvider).volume;
      final base = _glide.isAnimating ? _to : volume;
      final step = up ? VolumeControl.wheelStep : -VolumeControl.wheelStep;
      _glideTo((base + step).clamp(0.0, 1.0));
    });
  }

  void _glideTo(double target) {
    _to = target;
    final duration = NoirEffects.of(context).motion(NoirMotion.fast);
    if (duration == Duration.zero) {
      unawaited(ref.read(playbackProvider.notifier).setVolume(target));
      return;
    }
    _from = ref.read(playbackProvider).volume;
    _glide
      ..duration = duration
      ..forward(from: 0);
  }

  void _onGlide() {
    final t = NoirMotion.standard.transform(_glide.value);
    unawaited(
      ref.read(playbackProvider.notifier).setVolume(lerpDouble(_from, _to, t)!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(playbackProvider.select((s) => s.capabilities));
    if (!caps.canControlVolume) return const SizedBox.shrink();
    final volume = ref.watch(playbackProvider.select((s) => s.volume));
    final ctrl = ref.read(playbackProvider.notifier);
    return Listener(
      // The whole control, gaps included, takes the wheel.
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _onWheel,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          NoirIconButton(
            icon: volume == 0
                ? Icons.volume_off_rounded
                : volume < 0.5
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
            tooltip: volume == 0 ? 'Unmute' : 'Mute',
            size: 18,
            onPressed: () {
              _glide.stop();
              unawaited(ctrl.setVolume(volume == 0 ? 0.8 : 0));
            },
          ),
          if (widget.showSlider)
            SizedBox(
              width: 96,
              child: Semantics(
                label: 'Volume',
                child: Slider(
                  value: volume,
                  onChanged: (v) {
                    _glide.stop();
                    unawaited(ctrl.setVolume(v));
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
