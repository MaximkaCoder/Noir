import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// Apple Liquid Glass press response for a small control (an icon button):
/// on pointer down a glassy lens bubble — translucent, with a bright rim —
/// springs in around it, swelling to [bubbleScale] and leaning a little
/// toward the pointer while held, and the control squishes to
/// [pressedScale]; on release it springs back with a slight overshoot and a
/// specular flash sweeps across the bubble.
///
/// Observe-only: the wrapped control still gets its own taps. With
/// animations off it switches instantly; in Performance mode (no
/// highlights) only the squish remains.
class LiquidPress extends StatefulWidget {
  const LiquidPress({
    required this.child,
    this.enabled = true,
    this.pressedScale = 0.9,
    this.bubbleScale = 1.12,
    super.key,
  });

  final Widget child;

  /// Disabled controls do not respond.
  final bool enabled;

  /// Scale of [child] while pressed.
  final double pressedScale;

  /// Size of the bubble relative to [child] while pressed.
  final double bubbleScale;

  /// The scaled [child], for tests.
  static const contentKey = ValueKey('liquid-press-content');

  /// The bubble, for tests.
  static const bubbleKey = ValueKey('liquid-press-bubble');

  @override
  State<LiquidPress> createState() => _LiquidPressState();
}

class _LiquidPressState extends State<LiquidPress>
    with TickerProviderStateMixin {
  /// Quick and nearly critically damped: the squish lands at once.
  static final _in = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 900,
    ratio: 0.9,
  );

  /// Softer and underdamped: overshoots a little past rest (about 16% of the
  /// squish) and settles in ~400 ms.
  static final _out = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 400,
    ratio: 0.5,
  );

  /// 0 at rest, 1 pressed; dips below 0 as the release overshoots.
  late final _press = AnimationController.unbounded(vsync: this);
  late final _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  /// Pointer offset from the center while held, for the bubble's lean.
  final _lean = ValueNotifier<Offset>(Offset.zero);
  int? _pointer;

  @override
  void dispose() {
    _press.dispose();
    _flash.dispose();
    _lean.dispose();
    super.dispose();
  }

  void _springTo(double target, SpringDescription spring) {
    if (!NoirEffects.of(context).animations) {
      _press.value = target;
      return;
    }
    _press.animateWith(
      SpringSimulation(spring, _press.value, target, _press.velocity),
    );
  }

  Offset _offsetFromCenter(Offset local) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Offset.zero;
    return local - box.size.center(Offset.zero);
  }

  void _down(PointerDownEvent e) {
    if (!widget.enabled || _pointer != null) return;
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryButton) {
      return;
    }
    _pointer = e.pointer;
    _lean.value = _offsetFromCenter(e.localPosition);
    _springTo(1, _in);
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _lean.value = _offsetFromCenter(e.localPosition);
  }

  void _up(PointerEvent e, {required bool tapped}) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _springTo(0, _out);
    final fx = NoirEffects.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final inside =
        box != null && box.hasSize && box.size.contains(e.localPosition);
    if (tapped && inside && fx.animations && fx.highlights) {
      _flash.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fx = NoirEffects.of(context);
    final bubble = fx.highlights;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (e) => _up(e, tapped: true),
      onPointerCancel: (e) => _up(e, tapped: false),
      child: AnimatedBuilder(
        animation: Listenable.merge([_press, _flash, _lean]),
        child: widget.child,
        builder: (context, child) {
          final p = _press.value;
          final shown = p.clamp(0.0, 1.0);
          final flash = _flash.isAnimating ? _flash.value : null;
          final visible = bubble && (shown > 0.001 || flash != null);
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (visible)
                Positioned.fill(
                  child: IgnorePointer(
                    child: _Bubble(
                      key: LiquidPress.bubbleKey,
                      press: shown,
                      flash: flash,
                      lean: _lean.value,
                      scale: widget.bubbleScale,
                      dark: dark,
                    ),
                  ),
                ),
              Transform.scale(
                key: LiquidPress.contentKey,
                scale: 1 - (1 - widget.pressedScale) * p,
                child: child,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The lens bubble: grows in from 70% to [scale] with [press], leans
/// toward the pointer (stretching slightly along the lean), and carries
/// the release [flash] (0–1 while it sweeps).
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.press,
    required this.flash,
    required this.lean,
    required this.scale,
    required this.dark,
    super.key,
  });

  final double press;
  final double? flash;
  final Offset lean;
  final double scale;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    // Leans at most 4 px; stretches up to 6% along the lean.
    final distance = lean.distance;
    final reach = math.min(distance * 0.15, 4).toDouble();
    final dir = distance == 0 ? Offset.zero : lean / distance;
    final stretch = reach / 4 * 0.06 * press;
    // The flash keeps the bubble up while the press springs away.
    final fade = 1 - (flash ?? 1);
    final grow = 0.7 + (scale - 0.7) * math.max(press, fade * 0.8);
    final opacity = math.max(press, fade * 0.6);
    return Transform.translate(
      offset: dir * reach * press,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(
          grow * (1 + stretch * dir.dx.abs()),
          grow * (1 + stretch * dir.dy.abs()),
          1,
        ),
        child: CustomPaint(
          painter: _BubblePainter(
            opacity: opacity.clamp(0.0, 1.0),
            flash: flash,
            light: lean,
            dark: dark,
          ),
        ),
      ),
    );
  }
}

class _BubblePainter extends CustomPainter {
  const _BubblePainter({
    required this.opacity,
    required this.flash,
    required this.light,
    required this.dark,
  });

  final double opacity;
  final double? flash;
  final Offset light;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.shortestSide / 2),
    );
    final o = opacity;

    // Body: a faint glass fill, brighter where the finger presses.
    final center = size.center(Offset.zero);
    final focus = Alignment(
      (light.dx / (size.width / 2)).clamp(-1.0, 1.0) * 0.6,
      (light.dy / (size.height / 2)).clamp(-1.0, 1.0) * 0.6,
    );
    canvas
      ..drawRRect(
        shape,
        Paint()
          ..shader = RadialGradient(
            center: focus,
            radius: 0.9,
            colors: [
              Colors.white.withValues(alpha: (dark ? 0.16 : 0.42) * o),
              Colors.white.withValues(alpha: (dark ? 0.06 : 0.2) * o),
            ],
          ).createShader(rect),
      )
      // Lens edge: light gathers just inside the rim.
      ..drawRRect(
        shape.deflate(2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = Colors.white.withValues(alpha: (dark ? 0.07 : 0.2) * o)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      )
      // Bright specular rim, strongest at the top.
      ..drawRRect(
        shape.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.75 * o),
              Colors.white.withValues(alpha: 0.12 * o),
              Colors.white.withValues(alpha: 0.4 * o),
            ],
          ).createShader(rect),
      );

    final f = flash;
    if (f != null) {
      // A diagonal specular band sweeping from top-left to bottom-right.
      canvas
        ..save()
        ..clipRRect(shape);
      final travel = size.width + size.height;
      final x = -size.height + travel * f;
      final band = Rect.fromLTWH(
        x - size.height / 2,
        0,
        size.height,
        size.height,
      );
      canvas
        ..translate(center.dx, center.dy)
        ..rotate(-math.pi / 8)
        ..translate(-center.dx, -center.dy)
        ..drawRect(
          band.inflate(size.height),
          Paint()
            ..shader = LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0),
                Colors.white.withValues(alpha: 0.55 * (1 - f)),
                Colors.white.withValues(alpha: 0),
              ],
            ).createShader(band),
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.opacity != opacity ||
      old.flash != flash ||
      old.light != light ||
      old.dark != dark;
}

/// Turns on [LiquidPress] for the NOIR buttons below it that support it
/// (`NoirIconButton`, `PrimaryPlayButton`) — opt-in, so buttons elsewhere
/// keep their usual feedback.
class LiquidPressScope extends InheritedWidget {
  const LiquidPressScope({required super.child, super.key});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiquidPressScope>() != null;

  @override
  bool updateShouldNotify(LiquidPressScope oldWidget) => false;
}
