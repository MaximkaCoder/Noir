import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// A floating Liquid Glass capsule (stadium shape), after Apple's
/// iOS 26 / macOS Tahoe material, in NOIR's monochrome palette:
///
/// - one backdrop blur with a saturation boost, under a faint tint;
/// - an optional wash of [tintImage] (decoded a few pixels wide and
///   stretched, so it costs nothing and blurs for free);
/// - an inner glow and a specular rim — bright along the top edge, fading
///   down the sides, with a faint catch light at the bottom;
/// - a soft, wide shadow; hovering lifts the capsule a touch.
///
/// Respects [NoirEffects]: with Liquid Glass off it is an opaque capsule of
/// the same geometry (no backdrop filter); Performance mode keeps a lighter
/// blur but drops the tint, rim and lens band; with animations off it never
/// lifts.
class LiquidGlass extends StatefulWidget {
  const LiquidGlass({
    required this.child,
    this.padding,
    this.tintImage,
    this.liftOnHover = true,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// Tints the glass with a faint, desaturated stretch of this image (for
  /// example the current artwork).
  final ImageProvider? tintImage;

  /// Scales up 1% and deepens the shadow while the pointer is over it.
  final bool liftOnHover;

  /// Saturation boost applied to what shows through the glass.
  static const double saturation = 1.5;

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  bool _hovered = false;

  static final _saturate = ColorFilter.matrix(
    _saturationMatrix(LiquidGlass.saturation),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lifted = _hovered && widget.liftOnHover && fx.animations;
    final duration = fx.motion(NoirMotion.medium);

    // Content scrolls underneath, so dark glass also dims a little: bright
    // covers behind it stay readable without turning the glass grey.
    final fill = !fx.glass
        ? c.surfaceSolid
        : dark
        ? Color.alphaBlend(
            c.glassFill.withValues(alpha: c.glassFill.a * 1.4),
            Colors.black.withValues(alpha: 0.22),
          )
        : c.glassFill;
    final tint = widget.tintImage;

    Widget body = Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: fill)),
        if (fx.ambient && tint != null)
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: AnimatedSwitcher(
                  duration: fx.motion(NoirMotion.slow),
                  child: _Tint(
                    key: ValueKey(tint),
                    image: tint,
                    alpha: dark ? 0.16 : 0.12,
                  ),
                ),
              ),
            ),
          ),
        if (fx.highlights)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, 0.45, 0.75, 1],
                    colors: [
                      Colors.white.withValues(alpha: dark ? 0.07 : 0.4),
                      Colors.white.withValues(alpha: 0),
                      Colors.white.withValues(alpha: 0),
                      Colors.white.withValues(alpha: dark ? 0.035 : 0.18),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Padding(
          padding: widget.padding ?? EdgeInsets.zero,
          child: widget.child,
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _RimPainter(
                hairline: c.glassBorder,
                specular: fx.highlights,
                lens: fx.highlights,
                dark: dark,
              ),
            ),
          ),
        ),
      ],
    );

    final sigma = fx.blurSigma;
    if (fx.glass && sigma > 0) {
      final blur = ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
      body = BackdropFilter.grouped(
        filter: fx.highlights
            ? ImageFilter.compose(outer: _saturate, inner: blur)
            : blur,
        child: body,
      );
    }
    body = ClipRRect(borderRadius: NoirRadii.pillAll, child: body);

    body = AnimatedContainer(
      duration: duration,
      curve: NoirMotion.standard,
      decoration: BoxDecoration(
        borderRadius: NoirRadii.pillAll,
        boxShadow: [
          // Wide, soft ambient shadow: the capsule floats.
          BoxShadow(
            color: c.shadow.withValues(alpha: c.shadow.a * (lifted ? 1 : 0.8)),
            blurRadius: lifted ? 60 : 44,
            spreadRadius: -4,
            offset: Offset(0, lifted ? 22 : 16),
          ),
          // Tight contact shadow that defines the lower edge.
          BoxShadow(
            color: c.shadow.withValues(alpha: c.shadow.a * 0.35),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: body,
    );
    body = AnimatedScale(
      scale: lifted ? 1.01 : 1,
      duration: duration,
      curve: NoirMotion.standard,
      child: body,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: RepaintBoundary(child: body),
    );
  }
}

/// [image] decoded 8 px wide and stretched over the capsule: a smooth
/// wash of its tones, desaturated so NOIR stays monochrome-led.
class _Tint extends StatelessWidget {
  const _Tint({required this.image, required this.alpha, super.key});

  final ImageProvider image;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(_saturationMatrix(0.45, alpha: alpha)),
      child: Image(
        image: ResizeImage(image, width: 8),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}

/// Edge lighting, drawn above the content (it never reaches the edges):
/// a hairline for definition; with highlights on, a soft bright band just
/// inside the rim — light bending through a thick lens — and a specular
/// stroke that is brightest along the top edge.
class _RimPainter extends CustomPainter {
  const _RimPainter({
    required this.hairline,
    required this.specular,
    required this.lens,
    required this.dark,
  });

  final Color hairline;
  final bool specular;
  final bool lens;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.shortestSide / 2),
    );
    if (lens) {
      canvas.drawRRect(
        shape.deflate(4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..color = Colors.white.withValues(alpha: dark ? 0.045 : 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
    canvas.drawRRect(
      shape.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = hairline,
    );
    if (specular) {
      canvas.drawRRect(
        shape.deflate(0.75),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.3, 0.7, 1],
            colors: [
              Colors.white.withValues(alpha: dark ? 0.5 : 0.95),
              Colors.white.withValues(alpha: dark ? 0.14 : 0.45),
              Colors.white.withValues(alpha: dark ? 0.03 : 0.1),
              Colors.white.withValues(alpha: dark ? 0.14 : 0.5),
            ],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_RimPainter old) =>
      old.hairline != hairline ||
      old.specular != specular ||
      old.lens != lens ||
      old.dark != dark;
}

/// Color matrix scaling saturation by [s] (1 = unchanged) and alpha by
/// [alpha], with Rec. 709 luma weights.
List<double> _saturationMatrix(double s, {double alpha = 1}) {
  const r = 0.2126;
  const g = 0.7152;
  const b = 0.0722;
  final k = 1 - s;
  return [
    k * r + s, k * g, k * b, 0, 0, //
    k * r, k * g + s, k * b, 0, 0,
    k * r, k * g, k * b + s, 0, 0,
    0, 0, 0, alpha, 0,
  ];
}
