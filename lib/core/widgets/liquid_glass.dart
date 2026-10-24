import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// How a Liquid Glass surface renders, from the effects settings. The
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
  ///
  /// [density] above 1 lays a scrim over the glass for text-heavy surfaces
  /// (menus, dialogs): each step adds another 12% of the surface color, so
  /// text stays legible even on the clearest setting.
  factory LiquidGlassStyle.of(EffectsConfig fx, {double density = 1}) {
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
    final tint = lerpDouble(0.62, 0.08, g)!;
    return LiquidGlassStyle(
      tint: density == 1
          ? tint
          : (1 - (1 - tint) * math.pow(0.88, density - 1)).clamp(0.0, 1.0),
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
/// backdrop library, in NOIR's monochrome palette — the player island.
/// See [LiquidGlassMaterial] for the material itself; this adds the
/// capsule's soft, wide floating shadow.
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

  /// See [LiquidGlassMaterial.refract].
  final bool refract;

  /// See [LiquidGlassMaterial.tintImage].
  final ImageProvider? tintImage;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    return LiquidGlassMaterial(
      padding: padding,
      tintImage: tintImage,
      refract: refract,
      shadows: [
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
      child: child,
    );
  }
}

/// NOIR's Liquid Glass material, shared by the player island
/// ([LiquidGlass]) and every other glass surface (`GlassSurface`), so the
/// Glass slider changes all of them alike:
///
/// - the backdrop, lightly blurred and saturated, shows clearly through a
///   thin tint ([LiquidGlassStyle]);
/// - near the rim it is refracted like through a thick lens: a fragment
///   shader where the renderer supports backdrop shaders (Impeller, the
///   default on Windows) and [refract] allows it, otherwise a soft bright
///   band painted inside the rim;
/// - an optional wash of [tintImage] (decoded a few pixels wide and
///   stretched, so it costs nothing and blurs for free);
/// - a top sheen and a specular rim — bright along the top edge, fading
///   down the sides, with a faint catch light at the bottom.
///
/// Respects [NoirEffects]: with Liquid Glass off it is an opaque surface of
/// the same geometry (no backdrop filter); Performance mode keeps a light
/// blur but drops saturation, refraction and highlights.
///
/// Cost: the blur is one backdrop pass and the lens shader one more, so
/// the shader is kept to small surfaces ([maxLensExtent]), and surfaces on
/// NOIR's smooth canvas skip both ([backdrop]).
class LiquidGlassMaterial extends StatelessWidget {
  const LiquidGlassMaterial({
    required this.child,
    this.borderRadius = NoirRadii.pillAll,
    this.padding,
    this.shadows = const [],
    this.density = 1,
    this.borderOpacity = 1,
    this.highlight = 1,
    this.wash,
    this.blur,
    this.tintImage,
    this.refract = true,
    this.backdrop = true,
    this.maxLensExtent,
    this.maxLensDepth,
    super.key,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final List<BoxShadow> shadows;

  /// Scrim for text-heavy surfaces; see [LiquidGlassStyle.of].
  final double density;

  /// Multipliers over the hairline border and over the sheen and specular
  /// rim (0–1+).
  final double borderOpacity;
  final double highlight;

  /// Color laid over the glass (hover / selected); changes animate. Null
  /// for none.
  final Color? wash;

  /// Overrides the Glass level's blur sigma.
  final double? blur;

  /// Tints the glass with a faint, desaturated stretch of this image (for
  /// example the current artwork).
  final ImageProvider? tintImage;

  /// Whether the lens shader may refract the backdrop. Turn it off while an
  /// ancestor fades the glass: a translucent ancestor renders it into a
  /// separate layer whose origin the shader cannot know, so the painted
  /// band stands in until the fade ends.
  final bool refract;

  /// Whether the surface blurs and refracts what is behind it, for glass
  /// that floats over content. Without, it paints the same glass — tint,
  /// sheen, rim and lens band — for surfaces that sit on NOIR's canvas
  /// (`NoirBackdrop`), which is already smooth and grey: a backdrop pass
  /// there would cost a full-window copy per frame and show nothing.
  final bool backdrop;

  /// Above this size (longer side, logical px) the painted band stands in
  /// for the lens shader. Null: any size.
  final double? maxLensExtent;

  /// Caps the lens band's depth (logical px); by default a quarter of the
  /// shorter side, as on a capsule.
  final double? maxLensDepth;

  /// Whether the [LiquidGlassMaterial] built as [material] refracts its
  /// backdrop with the lens shader where the renderer supports it — whether
  /// or not it does here (tests run without shader support).
  @visibleForTesting
  static bool debugRefracts(Element material) {
    _RenderLiquidLens? lens;
    void visit(Element e) {
      if (lens != null) return;
      final r = e.renderObject;
      if (r is _RenderLiquidLens) {
        lens = r;
        return;
      }
      e.visitChildElements(visit);
    }

    visit(material);
    return lens?.refracts ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final fx = NoirEffects.of(context);
    final style = LiquidGlassStyle.of(fx, density: density);
    final refracts = fx.glass && backdrop && style.refraction > 0 && refract;
    if (refracts) _LensProgram.load();
    return ValueListenableBuilder<FragmentProgram?>(
      valueListenable: _LensProgram.program,
      builder: (context, program, _) =>
          _build(context, fx, style, refracts, refracts ? program : null),
    );
  }

  Widget _build(
    BuildContext context,
    EffectsConfig fx,
    LiquidGlassStyle style,
    bool refracts,
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
    final wash = this.wash;
    final g = fx.glassLevel;
    final sheen = fx.highlights ? highlight : 0.0;
    final sigma = fx.glass && backdrop ? blur ?? style.blurSigma : 0.0;
    // Backdrop filters need the clip for their bounds, the tint image for
    // its corners. Otherwise every layer is drawn in the shape itself: a
    // clip per surface per frame is not free.
    final clip = sigma > 0 || lens != null || (fx.ambient && tint != null);

    // Passthrough: the content gets the surface's own constraints (a menu's
    // minimum width, a panel's full height), as in a plain box.
    Widget body = Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: clip
              ? ColoredBox(color: fill)
              : DecoratedBox(
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: borderRadius,
                  ),
                ),
        ),
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
        if (wash != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: fx.motion(NoirMotion.fast),
                curve: NoirMotion.standard,
                decoration: BoxDecoration(
                  color: wash,
                  borderRadius: borderRadius,
                ),
              ),
            ),
          ),
        if (sheen > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: borderRadius,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, 0.45, 0.75, 1],
                    colors: [
                      Colors.white.withValues(
                        alpha: (dark ? 0.08 : 0.35) * sheen,
                      ),
                      Colors.white.withValues(alpha: 0),
                      Colors.white.withValues(alpha: 0),
                      Colors.white.withValues(
                        alpha: (dark ? 0.04 : 0.16) * sheen,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Padding(padding: padding ?? EdgeInsets.zero, child: child),
      ],
    );

    body = _LiquidLens(
      program: lens,
      spec: _LensSpec(
        refract: refracts,
        style: style,
        // The shader saturates when there is one (cheaper than a color
        // filter on the blur); else the blur layer.
        saturate: lens != null,
        borderRadius: borderRadius,
        maxExtent: maxLensExtent,
        maxDepth: maxLensDepth,
        hairline: c.glassBorder.withValues(
          alpha: (c.glassBorder.a * borderOpacity).clamp(0.0, 1.0),
        ),
        specular: sheen,
        // Where the shader cannot refract the backdrop, a painted band
        // stands in for the lens. Not on the canvas: over its flat grey a
        // lens would show nothing, and the band costs a few draws a frame.
        band: fx.highlights && backdrop ? 0.4 + g * 0.6 : 0,
        dark: dark,
      ),
      child: body,
    );

    if (sigma > 0) {
      // Blur (and saturate) first, then the lens refracts what the blur
      // drew: sibling layers, not ImageFilter.compose (which renders
      // nothing with a shader on Windows) nor nested (the inner layer's
      // coordinates shift). The tree keeps its shape either way, so
      // toggling the lens never remounts the content.
      final blur = ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
      final filter = lens != null || style.saturation == 1
          ? blur
          : ImageFilter.compose(
              outer: ColorFilter.matrix(_saturationMatrix(style.saturation)),
              inner: blur,
            );
      body = Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: filter,
              child: const SizedBox.expand(),
            ),
          ),
          body,
        ],
      );
    }
    if (clip) body = ClipRRect(borderRadius: borderRadius, child: body);
    if (shadows.isNotEmpty) {
      body = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: shadows,
        ),
        child: body,
      );
    }
    return RepaintBoundary(child: body);
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

/// Everything about a surface's lens and rim except the shader program.
@immutable
class _LensSpec {
  const _LensSpec({
    required this.refract,
    required this.style,
    required this.saturate,
    required this.borderRadius,
    required this.maxExtent,
    required this.maxDepth,
    required this.hairline,
    required this.specular,
    required this.band,
    required this.dark,
  });

  /// Whether the shader may refract (settings and caller allowing).
  final bool refract;
  final LiquidGlassStyle style;

  /// Whether the shader saturates too (the blur layer did not).
  final bool saturate;
  final BorderRadius borderRadius;
  final double? maxExtent;
  final double? maxDepth;

  final Color hairline;

  /// Strength of the specular rim, 0 for none.
  final double specular;

  /// Strength of the painted lens band where the shader does not refract.
  final double band;
  final bool dark;

  @override
  bool operator ==(Object other) =>
      other is _LensSpec &&
      other.refract == refract &&
      other.style == style &&
      other.saturate == saturate &&
      other.borderRadius == borderRadius &&
      other.maxExtent == maxExtent &&
      other.maxDepth == maxDepth &&
      other.hairline == hairline &&
      other.specular == specular &&
      other.band == band &&
      other.dark == dark;

  @override
  int get hashCode => Object.hash(
    refract,
    style,
    saturate,
    borderRadius,
    maxExtent,
    maxDepth,
    hairline,
    specular,
    band,
    dark,
  );
}

/// Refraction (and saturation) of the (already blurred) backdrop through
/// `shaders/liquid_glass.frag`, plus the rim drawn over the content.
class _LiquidLens extends SingleChildRenderObjectWidget {
  const _LiquidLens({
    required this.program,
    required this.spec,
    required super.child,
  });

  /// Null: the painted band stands in.
  final FragmentProgram? program;
  final _LensSpec spec;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLiquidLens(program, spec, View.of(context).devicePixelRatio);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLiquidLens renderObject,
  ) {
    renderObject
      ..program = program
      ..spec = spec
      ..devicePixelRatio = View.of(context).devicePixelRatio;
  }
}

class _RenderLiquidLens extends RenderProxyBox {
  _RenderLiquidLens(this._program, this._spec, this._devicePixelRatio);

  FragmentShader? _shader;

  /// The last filter and the on-screen rect it was made for.
  ImageFilter? _filter;
  Rect? _filterRect;

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

  _LensSpec get spec => _spec;
  _LensSpec _spec;
  set spec(_LensSpec value) {
    if (value == _spec) return;
    if (value.refract != _spec.refract) markNeedsCompositingBitsUpdate();
    _spec = value;
    markNeedsPaint();
  }

  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  /// Whether this surface refracts with the shader where it is supported:
  /// allowed, and small enough.
  bool get refracts {
    final max = _spec.maxExtent;
    return _spec.refract && hasSize && (max == null || size.longestSide <= max);
  }

  bool get _shading => _program != null && refracts;

  @override
  bool get alwaysNeedsCompositing =>
      child != null && _program != null && _spec.refract;

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }
    _filter = null;
    if (_shading) {
      final lens = (layer as _LensLayer?) ?? _LensLayer(this);
      layer = lens;
      context.pushLayer(lens, _paintSurface, offset);
    } else {
      layer = null;
      _paintSurface(context, offset);
    }
  }

  void _paintSurface(PaintingContext context, Offset offset) {
    context.paintChild(child!, offset);
    _paintRim(context.canvas, offset & size);
  }

  /// The shader as a backdrop filter for where the surface is on screen
  /// right now. The shader works in window pixels; asked for at compositing,
  /// after layout, so it follows a scroll or a slide in the same frame
  /// even though nothing repaints.
  ImageFilter _lensFilter() {
    final program = _program;
    if (!attached || !hasSize || program == null) {
      return _filter ?? ImageFilter.blur();
    }
    final rect = MatrixUtils.transformRect(
      getTransformTo(null),
      Offset.zero & size,
    );
    final cached = _filter;
    if (cached != null && rect == _filterRect) return cached;
    _filterRect = rect;

    final dpr = _devicePixelRatio;
    final px = rect.topLeft * dpr & rect.size * dpr;
    // Logical px of this box to window px, transforms included.
    final scale = size.width == 0 ? dpr : px.width / size.width;
    final side = px.shortestSide;
    final r = _spec.borderRadius;
    final corner = [
      r.topLeft.x,
      r.topRight.x,
      r.bottomLeft.x,
      r.bottomRight.x,
    ].reduce(math.max);
    final maxDepth = _spec.maxDepth;
    // SimpMusic's lens: a band a quarter of the height deep, displacing up
    // to half the height at the rim.
    var depth = side / 4;
    if (maxDepth != null) depth = math.min(depth, maxDepth * scale);
    final style = _spec.style;
    final shader = (_shader ??= program.fragmentShader())
      ..setFloat(2, px.left)
      ..setFloat(3, px.top)
      ..setFloat(4, px.width)
      ..setFloat(5, px.height)
      ..setFloat(6, math.min(corner * scale, side / 2))
      ..setFloat(7, depth)
      ..setFloat(8, depth * 2 * style.refraction)
      ..setFloat(9, _spec.saturate ? style.saturation : 1);
    return _filter = ImageFilter.shader(shader);
  }

  /// Edge lighting, drawn above the content (it never reaches the edges):
  /// a hairline for definition, which with highlights on turns specular —
  /// brightest along the top edge — and, on floating glass where the
  /// shader does not refract the backdrop, a soft bright band just inside
  /// the rim.
  void _paintRim(Canvas canvas, Rect rect) {
    final s = _spec;
    final dark = s.dark;
    final shape = s.borderRadius.toRRect(rect).scaleRadii();
    final band = _shading ? 0.0 : s.band;
    if (band > 0) {
      // A soft band peaking a few px inside the rim, from plain strokes: a
      // blurred mask would cost an offscreen blur per surface per frame.
      final alpha = (dark ? 0.05 : 0.22) * band;
      for (final (inset, weight) in _bandProfile) {
        canvas.drawRRect(
          shape.deflate(inset),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..color = Colors.white.withValues(alpha: alpha * weight),
        );
      }
    }
    final k = s.specular;
    if (k <= 0) {
      canvas.drawRRect(
        shape.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = s.hairline,
      );
      return;
    }
    // Hairline and specular in one stroke (each stroke is tessellated
    // every frame).
    Color rim(double alpha) =>
        Color.alphaBlend(Colors.white.withValues(alpha: alpha * k), s.hairline);
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
            rim(dark ? 0.5 : 0.95),
            rim(dark ? 0.14 : 0.45),
            rim(dark ? 0.03 : 0.1),
            rim(dark ? 0.14 : 0.5),
          ],
        ).createShader(rect),
    );
  }
}

/// Insets (px) and relative strengths of the strokes that make up the
/// painted lens band: about an 8 px band blurred by 5.
const _bandProfile = [
  (1.25, 0.45),
  (3.5, 0.7),
  (5.75, 0.6),
  (8.0, 0.35),
  (10.25, 0.15),
];

/// The lens as a backdrop filter layer that sets the shader's on-screen
/// rect each time the scene is built.
class _LensLayer extends ContainerLayer {
  _LensLayer(this._lens);

  final _RenderLiquidLens _lens;

  @override
  bool get alwaysNeedsAddToScene => true;

  @override
  void addToScene(SceneBuilder builder) {
    engineLayer = builder.pushBackdropFilter(
      _lens._lensFilter(),
      oldLayer: engineLayer as BackdropFilterEngineLayer?,
    );
    addChildrenToScene(builder);
    builder.pop();
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
