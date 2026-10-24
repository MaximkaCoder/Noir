import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// How a [LiquidGlass] surface renders, from the effects settings. The
/// Glass slider ([EffectsConfig.glassLevel]) drives all four together:
/// clearer glass has less tint and frost, more vivid color and a stronger
/// lens at the rim.
@immutable
class LiquidGlassStyle {
  const LiquidGlassStyle({
    required this.tint,
    required this.blurSigma,
    required this.saturation,
    required this.refraction,
  });

  /// Balanced: blur, saturation and edge refraction, all from the Glass
  /// level. Performance mode keeps a light blur only. With Liquid Glass off
  /// nothing shows through.
  factory LiquidGlassStyle.of(EffectsConfig fx) {
    final g = fx.glassLevel;
    if (!fx.glass) {
      return const LiquidGlassStyle(
        tint: 1,
        blurSigma: 0,
        saturation: 1,
        refraction: 0,
      );
    }
    final full = fx.highlights;
    return LiquidGlassStyle(
      tint: lerpDouble(0.62, 0.08, g)!,
      blurSigma: full ? lerpDouble(12, 3, g)! : lerpDouble(8, 3, g)!,
      saturation: full ? lerpDouble(1.05, 2, g)! : 1,
      refraction: full ? g : 0,
    );
  }

  /// Opacity of the surface color over what shows through.
  final double tint;

  /// Backdrop blur (logical px).
  final double blurSigma;

  /// Saturation of what shows through (1 = unchanged).
  final double saturation;

  /// Strength of the lens along the rim, 0–1; 1 displaces the backdrop by
  /// half the capsule's height at the very edge.
  final double refraction;

  @override
  bool operator ==(Object other) =>
      other is LiquidGlassStyle &&
      other.tint == tint &&
      other.blurSigma == blurSigma &&
      other.saturation == saturation &&
      other.refraction == refraction;

  @override
  int get hashCode => Object.hash(tint, blurSigma, saturation, refraction);

  @override
  String toString() =>
      'LiquidGlassStyle(tint: $tint, blur: $blurSigma, '
      'saturation: $saturation, refraction: $refraction)';
}

/// A floating Liquid Glass capsule (stadium shape), after Apple's
/// iOS 26 / macOS Tahoe material as SimpMusic draws it with Kyant's
/// backdrop library, in NOIR's monochrome palette:
///
/// - the backdrop, lightly blurred and saturated, shows clearly through a
///   thin tint ([LiquidGlassStyle]);
/// - near the rim it is refracted like through a thick lens: a fragment
///   shader where the renderer supports backdrop shaders (Impeller, the
///   default on Windows), otherwise a soft bright band painted inside the
///   rim;
/// - an optional wash of [tintImage] (decoded a few pixels wide and
///   stretched, so it costs nothing and blurs for free);
/// - a top sheen and a specular rim — bright along the top edge, fading
///   down the sides, with a faint catch light at the bottom;
/// - a soft, wide shadow.
///
/// Respects [NoirEffects]: with Liquid Glass off it is an opaque capsule of
/// the same geometry (no backdrop filter); Performance mode keeps a light
/// blur but drops saturation, refraction, tint and highlights.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    required this.child,
    this.padding,
    this.tintImage,
    this.refract = true,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// Whether the lens shader may refract the backdrop. Turn it off while an
  /// ancestor fades the glass: a translucent ancestor renders it into a
  /// separate layer whose origin the shader cannot know, so the painted
  /// band stands in until the fade ends.
  final bool refract;

  /// Tints the glass with a faint, desaturated stretch of this image (for
  /// example the current artwork).
  final ImageProvider? tintImage;

  @override
  Widget build(BuildContext context) {
    final fx = NoirEffects.of(context);
    final style = LiquidGlassStyle.of(fx);
    final useLens = fx.glass && style.refraction > 0;
    if (useLens) _LensProgram.load();
    return ValueListenableBuilder<FragmentProgram?>(
      valueListenable: _LensProgram.program,
      builder: (context, program, _) => _build(
        context,
        fx,
        style,
        useLens ? program : null,
      ),
    );
  }

  Widget _build(
    BuildContext context,
    EffectsConfig fx,
    LiquidGlassStyle style,
    FragmentProgram? lens,
  ) {
    final c = context.noir;
    final dark = Theme.of(context).brightness == Brightness.dark;

    // Content scrolls underneath, so dark glass dims rather than milks:
    // bright covers behind it stay readable without turning the glass grey.
    final fill = !fx.glass
        ? c.surfaceSolid
        : Color.alphaBlend(
            c.glassFill,
            (dark ? Colors.black : Colors.white).withValues(alpha: style.tint),
          );
    final tint = tintImage;
    final g = fx.glassLevel;

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
                    alpha: (dark ? 0.16 : 0.12) * (1 - g * 0.5),
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
                      Colors.white.withValues(alpha: dark ? 0.08 : 0.35),
                      Colors.white.withValues(alpha: 0),
                      Colors.white.withValues(alpha: 0),
                      Colors.white.withValues(alpha: dark ? 0.04 : 0.16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Padding(
          padding: padding ?? EdgeInsets.zero,
          child: child,
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _RimPainter(
                hairline: c.glassBorder,
                specular: fx.highlights,
                // The shader refracts the real backdrop; without it a
                // painted band stands in for the lens.
                lens: (lens == null || !refract) && fx.highlights
                    ? 0.4 + g * 0.6
                    : 0,
                dark: dark,
              ),
            ),
          ),
        ),
      ],
    );

    if (fx.glass && style.blurSigma > 0) {
      // Blur first, then the lens refracts (and saturates) what the blur
      // drew: sibling layers, not ImageFilter.compose (which renders nothing
      // with a shader on Windows) nor nested (the inner layer's coordinates
      // shift). Without the lens the blur saturates. The tree keeps its
      // shape either way, so toggling the lens never remounts the content.
      final blur = ImageFilter.blur(
        sigmaX: style.blurSigma,
        sigmaY: style.blurSigma,
      );
      final refracting = lens != null && refract;
      body = Stack(
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: refracting || style.saturation == 1
                  ? blur
                  : ImageFilter.compose(
                      outer: ColorFilter.matrix(
                        _saturationMatrix(style.saturation),
                      ),
                      inner: blur,
                    ),
              child: const SizedBox.expand(),
            ),
          ),
          _LensBackdrop(
            program: refracting ? lens : null,
            style: style,
            child: body,
          ),
        ],
      );
    }
    body = ClipRRect(borderRadius: NoirRadii.pillAll, child: body);

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: NoirRadii.pillAll,
          boxShadow: [
            // Wide, soft ambient shadow: the capsule floats.
            BoxShadow(
              color: c.shadow.withValues(alpha: c.shadow.a * 0.8),
              blurRadius: 44,
              spreadRadius: -4,
              offset: const Offset(0, 16),
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
      ),
    );
  }
}

/// The lens shader, loaded once where backdrop shader filters work.
abstract final class _LensProgram {
  static final program = ValueNotifier<FragmentProgram?>(null);
  static bool _requested = false;

  static void load() {
    if (_requested || !ImageFilter.isShaderFilterSupported) return;
    _requested = true;
    unawaited(
      FragmentProgram.fromAsset('shaders/liquid_glass.frag').then(
        (p) => program.value = p,
        // No lens then: the painted band stands in.
        onError: (Object _) {},
      ),
    );
  }
}

/// Refraction + saturation of the (already blurred) backdrop through
/// `shaders/liquid_glass.frag`. The shader works in window pixels, so the
/// surface's on-screen rect is passed in at paint time — and repainted
/// when an ancestor moves it without repainting (a slide, a scroll).
class _LensBackdrop extends SingleChildRenderObjectWidget {
  const _LensBackdrop({
    required this.program,
    required this.style,
    required super.child,
  });

  /// Null paints the child as is.
  final FragmentProgram? program;
  final LiquidGlassStyle style;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLensBackdrop(
    program,
    style,
    View.of(context).devicePixelRatio,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLensBackdrop renderObject,
  ) {
    renderObject
      ..program = program
      ..style = style
      ..devicePixelRatio = View.of(context).devicePixelRatio;
  }
}

class _RenderLensBackdrop extends RenderProxyBox {
  _RenderLensBackdrop(this._program, this._style, this._devicePixelRatio);

  FragmentShader? _shader;

  FragmentProgram? get program => _program;
  FragmentProgram? _program;
  set program(FragmentProgram? value) {
    if (value == _program) return;
    _program = value;
    _shader?.dispose();
    _shader = null;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  LiquidGlassStyle get style => _style;
  LiquidGlassStyle _style;
  set style(LiquidGlassStyle value) {
    if (value == _style) return;
    _style = value;
    markNeedsPaint();
  }

  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  Rect? _painted;
  bool _watching = false;

  @override
  BackdropFilterLayer? get layer => super.layer as BackdropFilterLayer?;

  @override
  bool get alwaysNeedsCompositing => child != null && _program != null;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    if (!_watching) {
      _watching = true;
      SchedulerBinding.instance.addPostFrameCallback(_watch);
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  void _watch(Duration _) {
    if (!attached) {
      _watching = false;
      return;
    }
    if (_program != null &&
        _painted != null &&
        hasSize &&
        _globalRect() != _painted) {
      markNeedsPaint();
    }
    SchedulerBinding.instance.addPostFrameCallback(_watch);
  }

  Rect _globalRect() =>
      MatrixUtils.transformRect(getTransformTo(null), Offset.zero & size);

  @override
  void paint(PaintingContext context, Offset offset) {
    final program = _program;
    if (program == null) {
      layer = null;
      _painted = null;
      super.paint(context, offset);
      return;
    }
    if (child == null) {
      layer = null;
      return;
    }
    final rect = _globalRect();
    _painted = rect;
    final px = rect.topLeft * _devicePixelRatio & rect.size * _devicePixelRatio;
    final side = px.shortestSide;
    final shader = (_shader ??= program.fragmentShader())
      ..setFloat(2, px.left)
      ..setFloat(3, px.top)
      ..setFloat(4, px.width)
      ..setFloat(5, px.height)
      ..setFloat(6, side / 2)
      // SimpMusic's lens: a band a quarter of the height deep, displacing
      // up to half the height at the rim.
      ..setFloat(7, side / 4)
      ..setFloat(8, side / 2 * _style.refraction)
      ..setFloat(9, _style.saturation);
    (layer ??= BackdropFilterLayer()).filter = ImageFilter.shader(shader);
    context.pushLayer(layer!, super.paint, offset);
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
/// a hairline for definition; with highlights on, a specular stroke that is
/// brightest along the top edge, and — where the shader cannot refract the
/// backdrop — a soft bright band just inside the rim, [lens] strong.
class _RimPainter extends CustomPainter {
  const _RimPainter({
    required this.hairline,
    required this.specular,
    required this.lens,
    required this.dark,
  });

  final Color hairline;
  final bool specular;
  final double lens;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.shortestSide / 2),
    );
    if (lens > 0) {
      canvas.drawRRect(
        shape.deflate(4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..color = Colors.white.withValues(alpha: (dark ? 0.05 : 0.22) * lens)
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
