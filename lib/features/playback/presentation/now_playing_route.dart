import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// The container transform between the player island and Now Playing: the
/// page grows out of the island's capsule — rect and corners morphing to
/// the full window — and shrinks back into it on close, whichever way it
/// closes (chevron, Esc, swipe, back button). The island fades out early as
/// a glass surface takes its place, and Now Playing fades and scales in
/// over it. Without an island on screen (phones, nothing playing) the page
/// fades and scales up from the bottom center instead.
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
    _curve = CurvedAnimation(
      parent: widget.animation,
      curve: NoirMotion.emphasized,
      reverseCurve: NoirMotion.emphasized.flipped,
    );
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
    final fx = NoirEffects.of(context);
    final c = context.noir;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) {
        final t = _curve.value.clamp(0.0, 1.0);
        final size = MediaQuery.sizeOf(context);
        final full = Offset.zero & size;
        final from = NowPlayingTransition.anchorRect;
        final done = t >= 1;

        final RRect shape;
        final double surface;
        final double content;
        final double scale;
        final Alignment origin;
        if (from == null) {
          // No island: a subtle fade and scale from the bottom center.
          shape = RRect.fromRectAndRadius(full, Radius.zero);
          surface = 0;
          content = const Interval(0, 0.7).transform(t);
          scale = lerpDouble(0.94, 1, t)!;
          origin = Alignment.bottomCenter;
        } else {
          shape = RRect.fromRectAndRadius(
            Rect.lerp(from, full, t)!,
            Radius.circular(lerpDouble(from.shortestSide / 2, 0, t)!),
          );
          // Glass takes the island's place while the island fades out…
          surface = const Interval(0, 0.3).transform(t);
          // …then Now Playing fades and scales in over it.
          content = const Interval(0.2, 0.75).transform(t);
          scale = lerpDouble(0.9, 1, t)!;
          origin = Alignment(
            from.center.dx / size.width * 2 - 1,
            from.center.dy / size.height * 2 - 1,
          );
        }

        final fill = !fx.glass
            ? c.surfaceSolid
            : Color.alphaBlend(
                c.glassFill,
                (dark ? Colors.black : Colors.white).withValues(alpha: 0.35),
              );
        final sigma = fx.glass ? lerpDouble(4, 24, t)! : 0.0;
        return ClipRRect(
          key: NowPlayingTransition.clipKey,
          clipper: NowPlayingClipper(shape),
          clipBehavior: done ? Clip.none : Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The surface the shape is made of; gone once open, so the
              // page does not keep a full-window blur alive.
              IgnorePointer(
                child: BackdropFilter(
                  enabled: !done && surface > 0 && sigma > 0,
                  filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                  child: ColoredBox(
                    color: done
                        ? Colors.transparent
                        : fill.withValues(alpha: fill.a * surface),
                  ),
                ),
              ),
              Opacity(
                opacity: content,
                child: Transform.scale(
                  scale: scale,
                  alignment: origin,
                  child: child,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
