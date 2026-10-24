import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// NOIR's material. With Liquid Glass on: backdrop blur, translucent fill,
/// hairline border and a soft specular highlight. With it off: an opaque
/// surface with the exact same geometry, so layout never changes.
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
    super.key,
  });

  final Widget child;
  final BorderRadius borderRadius;

  /// Overrides the effect-level blur sigma.
  final double? blur;

  /// Multipliers over the palette's glass tokens (0–1+).
  final double fillOpacity;
  final double borderOpacity;
  final double highlight;

  /// 0 = flat, 1 = floating panel.
  final double shadow;

  /// Brightens on hover (pointer devices).
  final bool interactive;
  final bool selected;
  final EdgeInsetsGeometry? padding;

  @override
  State<GlassSurface> createState() => _GlassSurfaceState();
}

class _GlassSurfaceState extends State<GlassSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    final active = widget.selected || (widget.interactive && _hovered);

    final baseFill = fx.glass ? c.glassFill : c.surfaceSolid;
    final fill = Color.alphaBlend(
      active ? (widget.selected ? c.selected : c.hover) : Colors.transparent,
      baseFill.withValues(alpha: baseFill.a * widget.fillOpacity),
    );
    final border = c.glassBorder.withValues(
      alpha: (c.glassBorder.a * widget.borderOpacity).clamp(0, 1),
    );

    Widget content = AnimatedContainer(
      duration: fx.motion(NoirMotion.fast),
      curve: NoirMotion.standard,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: widget.borderRadius,
        border: Border.all(color: border),
      ),
      foregroundDecoration: fx.highlights && widget.highlight > 0
          ? BoxDecoration(
              borderRadius: widget.borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: const Alignment(0.2, 0.6),
                colors: [
                  c.glassHighlight.withValues(
                    alpha: c.glassHighlight.a * widget.highlight,
                  ),
                  c.glassHighlight.withValues(alpha: 0),
                ],
              ),
            )
          : null,
      child: widget.child,
    );

    final sigma = widget.blur ?? fx.blurSigma;
    if (fx.glass && sigma > 0) {
      content = ClipRRect(
        borderRadius: widget.borderRadius,
        child: BackdropFilter.grouped(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: content,
        ),
      );
    }

    if (widget.shadow > 0) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
          boxShadow: [
            BoxShadow(
              color: c.shadow.withValues(alpha: c.shadow.a * widget.shadow),
              blurRadius: 40 * widget.shadow,
              offset: Offset(0, 16 * widget.shadow),
            ),
          ],
        ),
        child: content,
      );
    }

    if (widget.interactive) {
      content = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: content,
      );
    }
    return RepaintBoundary(child: content);
  }
}
