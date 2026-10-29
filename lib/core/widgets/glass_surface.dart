import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/platform/form_factor.dart';
import 'package:noir/core/widgets/liquid_glass.dart';

/// NOIR's material: the same Liquid Glass as the player island
/// ([LiquidGlassMaterial]) in any shape, driven by the same Glass slider.
/// With Liquid Glass off: an opaque surface with the exact same geometry,
/// so layout never changes.
///
/// [floating] surfaces (menus, dialogs, toasts, arrows over a shelf) blur
/// and refract the content under them, through the lens shader when they
/// are small. The rest sit on NOIR's smooth canvas and paint the same glass
/// without a backdrop pass.
///
/// Use sparingly — navigation, player, panels, dialogs, menus — never per
/// list row.
class GlassSurface extends StatefulWidget {
  const GlassSurface({
    required this.child,
    this.borderRadius = NoirRadii.lgAll,
    this.blur,
    this.fillOpacity = 1,
    this.borderOpacity = 1,
    this.highlight = 1,
    this.shadow = 0,
    this.interactive = false,
    this.selected = false,
    this.padding,
    this.floating = false,
    this.refract = true,
    super.key,
  });

  /// Above this size (longer side, logical px) a painted band stands in
  /// for the lens shader.
  static const double maxLensExtent = 480;

  final Widget child;
  final BorderRadius borderRadius;

  /// Overrides the Glass level's blur sigma ([floating] surfaces).
  final double? blur;

  /// Tint density: above 1 lays a scrim over the glass for text-heavy
  /// surfaces (see [LiquidGlassStyle.of]).
  final double fillOpacity;

  /// Multipliers over the hairline border and over the sheen and specular
  /// rim (0–1+).
  final double borderOpacity;
  final double highlight;

  /// 0 = flat, 1 = floating panel.
  final double shadow;

  /// Brightens on hover (pointer devices).
  final bool interactive;
  final bool selected;
  final EdgeInsetsGeometry? padding;

  /// Floats over content, which it blurs and refracts; see
  /// [LiquidGlassMaterial.backdrop].
  final bool floating;

  /// Whether the lens shader may refract the backdrop of a [floating]
  /// surface (small ones only; see [maxLensExtent]). [GlassFade] switches
  /// it off while it fades.
  final bool refract;

  @override
  State<GlassSurface> createState() => _GlassSurfaceState();
}

class _GlassSurfaceState extends State<GlassSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final active = widget.selected || (widget.interactive && _hovered);
    // Phones skip the lens shader: it samples the backdrop again every
    // frame a menu or popover animates, which a phone's GPU felt.
    final refract =
        widget.refract && GlassFade.settled(context) && !FormFactor.touch;

    Widget content = LiquidGlassMaterial(
      borderRadius: widget.borderRadius,
      // Inside the 1 px rim, as with a bordered box: layouts stay put.
      padding: (widget.padding ?? EdgeInsets.zero).add(const EdgeInsets.all(1)),
      blur: widget.blur,
      density: widget.fillOpacity,
      borderOpacity: widget.borderOpacity,
      highlight: widget.highlight,
      wash: widget.interactive || widget.selected
          ? (active
                ? (widget.selected ? c.selected : c.hover)
                : c.hover.withValues(alpha: 0))
          : null,
      shadows: [
        if (widget.shadow > 0)
          BoxShadow(
            color: c.shadow.withValues(alpha: c.shadow.a * widget.shadow),
            blurRadius: 40 * widget.shadow,
            offset: Offset(0, 16 * widget.shadow),
          ),
      ],
      backdrop: widget.floating,
      refract: refract,
      maxLensExtent: GlassSurface.maxLensExtent,
      maxLensDepth: 18,
      child: widget.child,
    );

    if (widget.interactive) {
      content = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: content,
      );
    }
    return content;
  }
}

/// Fades glass surfaces below it with a plain [Opacity], which leaves no
/// layer behind once opaque (a `FadeTransition` / `AnimatedOpacity` keeps
/// one, and inside it the lens shader cannot see the backdrop). While the
/// fade runs, [GlassSurface]s below swap the lens shader for the painted
/// band.
class GlassFade extends StatelessWidget {
  const GlassFade({required this.opacity, required this.child, super.key});

  final double opacity;
  final Widget child;

  /// False while a [GlassFade] above [context] is translucent.
  static bool settled(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GlassFadeScope>()?.settled ??
      true;

  @override
  Widget build(BuildContext context) {
    return _GlassFadeScope(
      settled: opacity >= 1,
      child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: child),
    );
  }
}

class _GlassFadeScope extends InheritedWidget {
  const _GlassFadeScope({required this.settled, required super.child});

  final bool settled;

  @override
  bool updateShouldNotify(_GlassFadeScope oldWidget) =>
      settled != oldWidget.settled;
}
