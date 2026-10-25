import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// The container transform between the player island and Now Playing: the
/// page grows out of the island's capsule — rect and corners morphing to
/// the full window — and shrinks back into it on close, whichever way it
/// closes (chevron, Esc, swipe, back button). Opening, the page's artwork
/// backdrop cross-fades in over the island, which fades out, and Now
/// Playing's content fades in over it. Closing, the content fades first,
/// the opaque shape shrinks onto the island, and only there cross-fades
/// into the island's glass.
/// Without an island on screen (phones, nothing playing) the page fades and
/// rises from below instead.
abstract final class NowPlayingTransition {
  static const openDuration = Duration(milliseconds: 500);
  static const closeDuration = Duration(milliseconds: 480);

  /// The clip that carries the morphing shape, for tests.
  static const clipKey = ValueKey('now-playing-morph');

  static Object? _owner;
  static Rect? Function()? _anchor;

  /// How far Now Playing covers the island: 0 closed, 1 open. The island
  /// hides behind it as this rises.
  static final ValueNotifier<double> coverage = ValueNotifier(0);

  /// The morph's easing over the route [animation]: emphasized on the way
  /// out of the island. On the way back a symmetric ease, so the page
  /// visibly shrinks instead of snapping small at the start, which lands
  /// on the island's rect once route progress is down to [islandFade]; the
  /// shape then stays there while it cross-fades into the island.
  static CurvedAnimation curve(Animation<double> animation) => CurvedAnimation(
    parent: animation,
    curve: NoirMotion.emphasized,
    reverseCurve: const _ShrinkThenLand(),
  );

  /// The island fades out over route progress 0 → [islandFade] while the
  /// page opens and back in over the same span while it closes (see
  /// PlayerIsland). Closing, that is exactly when the shape, already the
  /// island's size, fades out over it.
  static const islandFade = 0.3;

  /// Route progress above which, closing, the content is still fading out:
  /// before the shape has visibly moved.
  static const _contentGone = 0.86;

  /// Opening, the content fades in once the shape has grown a little (eased
  /// morph progress 0.2–0.75); closing, it fades out first, before the
  /// shape has visibly moved. Values are over the route's raw progress.
  static CurvedAnimation contentCurve(Animation<double> route) =>
      CurvedAnimation(
        parent: route,
        curve: const _ContentIn(),
        reverseCurve: const Interval(_contentGone, 1),
      );

  /// How opaque the page's own material — the artwork backdrop — is.
  /// Opening, it cross-fades in over the island and is opaque before the
  /// content shows. Closing, it stays opaque while the shape shrinks, and
  /// once the shape has landed on the island (the last [islandFade]) it
  /// cross-fades into the island's glass.
  static CurvedAnimation backdropCurve(Animation<double> route) =>
      CurvedAnimation(
        parent: route,
        curve: const Interval(0, 0.12),
        // Fades out exactly as the island fades in.
        reverseCurve: const Interval(0, islandFade),
      );

  /// Whether the page morphs out of the island (and so fades its content
  /// and material); without an island it fades as a whole instead.
  static bool get morphs => anchorRect != null;

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

class _ContentIn extends Curve {
  const _ContentIn();

  @override
  double transformInternal(double t) =>
      const Interval(0.2, 0.75).transform(NoirMotion.emphasized.transform(t));
}

/// Closing (route progress falling from 1): the morph eases from the full
/// window down to the island over 1 → [NowPlayingTransition.islandFade]
/// and stays on it after.
class _ShrinkThenLand extends Curve {
  const _ShrinkThenLand();

  @override
  double transformInternal(double t) {
    const land = NowPlayingTransition.islandFade;
    if (t <= land) return 0;
    return Curves.easeInOutCubic.transform((t - land) / (1 - land));
  }
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

        // The page itself is the shape's material: its artwork backdrop
        // grows out of the capsule while the island fades out, and its
        // content fades in over that backdrop; closing, the backdrop is
        // painted see-through by alpha ([NowPlayingTransition.contentCurve],
        // [NowPlayingTransition.backdropCurve]). The page is never
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
