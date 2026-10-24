import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:webview_windows/webview_windows.dart';

/// Where Now Playing wants the video (global coordinates), or null.
final videoSlotProvider = NotifierProvider<_VideoSlot, Rect?>(_VideoSlot.new);

class _VideoSlot extends Notifier<Rect?> {
  @override
  Rect? build() => null;

  // A method reads better than a setter at the call sites in VideoSlot.
  // ignore: use_setters_to_change_properties
  void set(Rect? rect) => state = rect;
}

/// The single YouTube player of the app, drawn above the navigator.
///
/// YouTube's policies require the player to stay visible while it plays
/// (viewport ≥ 200×200, nothing drawn over it, no background playback). So:
/// - in Now Playing it fills the slot reported by [VideoSlot];
/// - elsewhere it floats as a 356×200 mini player with controls *beside* it;
/// - when the window is minimized or hidden, playback pauses.
class YouTubeVideoLayer extends ConsumerStatefulWidget {
  const YouTubeVideoLayer({super.key});

  static const miniSize = Size(356, 200);

  @override
  ConsumerState<YouTubeVideoLayer> createState() => _YouTubeVideoLayerState();
}

class _YouTubeVideoLayerState extends ConsumerState<YouTubeVideoLayer> {
  late final AppLifecycleListener _lifecycle;

  void _pauseIfPlaying() {
    if (ref.read(settingsProvider).hideYouTubePlayer) return;
    final s = ref.read(playbackProvider);
    if (s.showsVideoPlayer && s.isPlaying) {
      unawaited(ref.read(playbackProvider.notifier).pause());
    }
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: _pauseIfPlaying,
      onPause: _pauseIfPlaying,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(youTubeEngineProvider);
    final isYouTube = ref.watch(
      playbackProvider.select((s) => s.showsVideoPlayer),
    );
    if (engine == null) return const SizedBox.shrink();

    final hidden = ref.watch(
      settingsProvider.select((s) => s.hideYouTubePlayer),
    );
    final slot = ref.watch(videoSlotProvider);
    final size = MediaQuery.sizeOf(context);
    final mini = slot == null && !hidden;
    // Experimental hidden mode: the player keeps running in a 2 px,
    // fully transparent box so only its audio is perceived.
    final rect = hidden
        ? const Rect.fromLTWH(0, 0, 2, 2)
        : slot ?? _miniRect(size);
    final fx = NoirEffects.of(context);

    return Stack(
      children: [
        AnimatedPositioned.fromRect(
          rect: isYouTube ? rect : Rect.fromLTWH(size.width, 0, 2, 2),
          duration: fx.motion(NoirMotion.medium),
          curve: NoirMotion.standard,
          child: Offstage(
            offstage: !isYouTube,
            child: Opacity(
              opacity: hidden ? 0 : 1,
              child: ValueListenableBuilder(
                valueListenable: engine.ready,
                builder: (context, ready, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(mini ? 12 : 16),
                  child: ColoredBox(
                    color: Colors.black,
                    child: ready
                        ? Webview(engine.controller)
                        : const Center(
                            child: SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (isYouTube && mini)
          Positioned(
            left: rect.left,
            width: rect.width,
            top: rect.top - 44,
            child: const _MiniBar(),
          ),
      ],
    );
  }

  /// Bottom-right, clear of the bottom player bars of each layout.
  static Rect _miniRect(Size screen) {
    const s = YouTubeVideoLayer.miniSize;
    final bottomInset = switch (WindowClass.of(screen.width)) {
      WindowClass.expanded => 24.0,
      WindowClass.medium => 104.0,
      WindowClass.compact => 168.0,
    };
    final width = s.width.clamp(200.0, screen.width - 32);
    return Rect.fromLTWH(
      screen.width - width - 16,
      screen.height - s.height - bottomInset,
      width,
      s.height,
    );
  }
}

/// Controls for the floating player, placed above it — never over it.
class _MiniBar extends ConsumerWidget {
  const _MiniBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playbackProvider);
    final ctrl = ref.read(playbackProvider.notifier);
    final t = Theme.of(context).textTheme;
    return GlassSurface(
      borderRadius: NoirRadii.mdAll,
      fillOpacity: 2.5,
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: SizedBox(
        height: 38,
        child: Row(
          children: [
            Expanded(
              child: Text(
                s.current?.track.title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.labelMedium?.copyWith(color: context.noir.textPrimary),
              ),
            ),
            NoirIconButton(
              icon: s.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              tooltip: s.isPlaying ? 'Pause' : 'Play',
              size: 18,
              onPressed: () => unawaited(ctrl.togglePlayPause()),
            ),
            NoirIconButton(
              icon: Icons.open_in_full_rounded,
              tooltip: 'Open player',
              size: 16,
              onPressed: () =>
                  unawaited(ref.read(routerProvider).push('/now-playing')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reserves space in Now Playing and tells the layer where to draw the video.
class VideoSlot extends ConsumerStatefulWidget {
  const VideoSlot({required this.size, super.key});

  final Size size;

  @override
  ConsumerState<VideoSlot> createState() => _VideoSlotState();
}

class _VideoSlotState extends ConsumerState<VideoSlot> {
  late final _slot = ref.read(videoSlotProvider.notifier);
  ScrollPosition? _scroll;
  int _trackingFrames = 0;

  @override
  void initState() {
    super.initState();
    // Follow the page's entrance transition for ~0.5 s.
    _trackingFrames = 30;
    SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
  }

  void _onFrame(Duration _) {
    if (!mounted) return;
    _report();
    if (--_trackingFrames > 0) {
      SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scroll?.removeListener(_report);
    _scroll = Scrollable.maybeOf(context)?.position;
    _scroll?.addListener(_report);
  }

  void _report() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (ref.read(videoSlotProvider) != rect) _slot.set(rect);
  }

  @override
  void dispose() {
    _scroll?.removeListener(_report);
    // Deferred: providers can't change while the tree is being torn down.
    SchedulerBinding.instance.addPostFrameCallback((_) => _slot.set(null));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    SchedulerBinding.instance.addPostFrameCallback((_) => _report());
    return SizedBox.fromSize(size: widget.size);
  }
}
