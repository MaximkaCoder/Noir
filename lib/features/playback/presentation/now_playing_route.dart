import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// The container transform between the player island and Now Playing: the
/// page grows out of the island's capsule — rect and corners morphing to
/// the full window — and shrinks back into it on close, whichever way it
/// closes (chevron, Esc, swipe, back button). The island fades out early as
/// the page's own artwork backdrop takes its place, and Now Playing's
/// content fades in over it. Without an island on screen (phones, nothing
/// playing) the page fades and rises from below instead.
abstract final class NowPlayingTransition {
  static const openDuration = Duration(milliseconds: 500);
  static const closeDuration = Duration(milliseconds: 400);

  /// The clip that carries the morphing shape, for tests.
  static const clipKey = ValueKey('now-playing-morph');

  static Object? _owner;
  static Rect? Function()? _anchor;

  /// How far Now Playing covers the island: 0 closed, 1 open. The island
  /// hides behind it as this rises.
  static final ValueNotifier<double> coverage = ValueNotifier(0);

  /// The morph's easing over the route [animation], both ways.
  static CurvedAnimation curve(Animation<double> animation) => CurvedAnimation(
    parent: animation,
    curve: NoirMotion.emphasized,
    reverseCurve: NoirMotion.emphasized.flipped,
  );

  /// How visible Now Playing's content (everything over its backdrop) is at
  /// the morph's eased progress [t]: it fades in once the shape has grown a
  /// little, and out again early on close. Without an island the whole page
  /// fades instead, so the content is fully shown.
  static double contentOpacity(double t) => anchorRect == null
      ? 1
      : const Interval(0.2, 0.75).transform(t.clamp(0.0, 1.0));

  /// Registers the island: [rect] gives its on-screen capsule, or null
  /// while it is hidden.
  static void attachAnchor(Object owner, Rect? Function() rect) {
    _owner = owner;
    _anchor = rect;
    // A fresh island never starts hidden behind a page that is gone.
    if (coverage.value != 0) coverage.value = 0;
  }

  static void detachAnchor(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    _anchor = null;
  }

  /// Where Now Playing grows from and shrinks back to; read live, so a
  /// window resized while the page is open still closes into the island.
  static Rect? get anchorRect => _anchor?.call();
}

/// The '/now-playing' page: transparent, so the shell stays visible around
/// the morphing shape.
Page<void> nowPlayingPage(
  BuildContext context,
  GoRouterState state,
  Widget child,
) {
  final fx = NoirEffects.of(context);
  return CustomTransitionPage<void>(
    key: state.pageKey,
    opaque: false,
    transitionDuration: fx.motion(NowPlayingTransition.openDuration),
    reverseTransitionDuration: fx.motion(NowPlayingTransition.closeDuration),
    child: child,
    transitionsBuilder: (context, animation, _, child) =>
        _Morph(animation: animation, child: child),
  );
}

/// Clips Now Playing to the morphing [shape].
class NowPlayingClipper extends CustomClipper<RRect> {
  const NowPlayingClipper(this.shape);

  /// In the page's coordinates.
  final RRect shape;

  @override
  RRect getClip(Size size) => shape;

  @override
  bool shouldReclip(NowPlayingClipper oldClipper) => oldClipper.shape != shape;
}

class _Morph extends StatefulWidget {
  const _Morph({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<_Morph> createState() => _MorphState();
}

class _MorphState extends State<_Morph> {
  late CurvedAnimation _curve;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(_Morph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _unlisten(oldWidget.animation);
      _listen();
    }
  }

  @override
  void dispose() {
    _unlisten(widget.animation);
    super.dispose();
  }

  void _listen() {
    _curve = NowPlayingTransition.curve(widget.animation);
    widget.animation
      ..addListener(_sync)
      ..addStatusListener(_status);
    // Runs inside the first build: publish after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  void _unlisten(Animation<double> animation) {
    animation
      ..removeListener(_sync)
      ..removeStatusListener(_status);
    _curve.dispose();
  }

  void _sync() => NowPlayingTransition.coverage.value = widget.animation.value;

  void _status(AnimationStatus status) {
    if (status.isDismissed) NowPlayingTransition.coverage.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) {
        final t = _curve.value.clamp(0.0, 1.0);
        final size = MediaQuery.sizeOf(context);
        final full = Offset.zero & size;
        final from = NowPlayingTransition.anchorRect;
        final done = t >= 1;

        if (from == null) {
          // No island: a subtle fade and rise from below. The layer stays
          // window-sized, so it costs one reused offscreen.
          return ClipRRect(
            key: NowPlayingTransition.clipKey,
            clipper: NowPlayingClipper(
              RRect.fromRectAndRadius(full, Radius.zero),
            ),
            clipBehavior: Clip.none,
            child: Opacity(
              opacity: const Interval(0, 0.7).transform(t),
              child: Transform.translate(
                offset: Offset(0, (1 - t) * size.height * 0.04),
                child: child,
              ),
            ),
          );
        }

        // The page itself is the shape's material: its opaque artwork
        // backdrop grows out of the capsule while the island fades out,
        // and its content fades in over that backdrop
        // ([NowPlayingTransition.contentOpacity]). The page is never
        // scaled, blurred or faded as a whole: a scale that changes every
        // frame made the raster thread re-render the whole page each frame
        // (offscreen textures reallocated per frame, frames of 50–190 ms
        // with Impeller on Windows), and a full-window backdrop blur and
        // opacity layer only added to it.
        final shape = RRect.fromRectAndRadius(
          Rect.lerp(from, full, t)!,
          Radius.circular(lerpDouble(from.shortestSide / 2, 0, t)!),
        );
        return ClipRRect(
          key: NowPlayingTransition.clipKey,
          clipper: NowPlayingClipper(shape),
          clipBehavior: done ? Clip.none : Clip.antiAlias,
          child: child,
        );
      },
    );
  }
}
