import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';

/// Horizontally scrolling shelf (tiles, chips) with an optional title.
///
/// - Edges fade out on the side where more content waits.
/// - On hover (pointer devices) round glass arrows fade in and page by about
///   the visible width; each hides at its end.
/// - Touch / trackpad drag, horizontal wheels and Shift+wheel scroll it,
///   gliding like the page does; a plain vertical wheel keeps scrolling the
///   page. No scrollbar.
class ShelfRow extends StatefulWidget {
  const ShelfRow({
    required this.children,
    required this.height,
    this.spacing = NoirSpacing.lg,
    this.itemExtent,
    this.arrowCenter,
    this.arrowSize = 36,
    this.title,
    this.eyebrow,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final List<Widget> children;

  /// Height of the items.
  final double height;
  final double spacing;

  /// Width of one item plus [spacing], when items share a width: arrows
  /// then page by whole items so a tile is never left cut at the start.
  final double? itemExtent;

  /// Arrow center from the items' top (e.g. the middle of the artwork);
  /// the middle of [height] by default.
  final double? arrowCenter;
  final double arrowSize;

  final String? title;

  /// Small all-caps line above [title].
  final String? eyebrow;

  /// "See all" next to the title.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Room above the items so hover lift / scale isn't clipped.
  static const double lift = 6;

  /// Width of the edge fades.
  static const double fade = 48;

  @override
  State<ShelfRow> createState() => _ShelfRowState();
}

class _ShelfRowState extends State<ShelfRow> {
  final _controller = SmoothScrollController();

  /// Content hidden before / after the viewport (logical px).
  final _edges = ValueNotifier<(double, double)>((0, 0));
  bool _hovered = false;

  @override
  void dispose() {
    _controller.dispose();
    _edges.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0) _sync(n.metrics);
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification n) {
    if (n.depth == 0) _sync(n.metrics);
    return false;
  }

  void _sync(ScrollMetrics m) {
    if (!m.hasContentDimensions || !m.hasPixels) return;
    _edges.value = (m.extentBefore, m.extentAfter);
  }

  void _page(int direction) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    final viewport = p.viewportDimension;
    var target = p.pixels + direction * viewport * 0.85;
    if (widget.itemExtent case final extent? when extent > 0) {
      // Whole items per page, landing on an item's start.
      final perPage = math.max(
        1,
        ((viewport + widget.spacing) / extent).floor(),
      );
      final first = (p.pixels / extent).round();
      target = (first + direction * perPage) * extent;
    }
    target = target.clamp(p.minScrollExtent, p.maxScrollExtent);
    final duration = NoirEffects.of(context).motion(NoirMotion.slow * 1.5);
    if (duration == Duration.zero) {
      _controller.jumpTo(target);
    } else {
      _controller.animateTo(
        target,
        duration: duration,
        curve: NoirMotion.emphasized,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final fx = NoirEffects.of(context);
    _controller.smooth = fx.animations;
    final height = widget.height + ShelfRow.lift;
    final arrowTop =
        ShelfRow.lift +
        (widget.arrowCenter ?? widget.height / 2) -
        widget.arrowSize / 2;

    final list = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: _onMetrics,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(top: ShelfRow.lift),
            itemCount: widget.children.length,
            separatorBuilder: (_, _) => SizedBox(width: widget.spacing),
            itemBuilder: (_, i) => widget.children[i],
          ),
        ),
      ),
    );

    final row = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        height: height,
        child: ValueListenableBuilder<(double, double)>(
          valueListenable: _edges,
          child: list,
          builder: (context, edges, list) {
            final (before, after) = edges;
            return Stack(
              children: [
                Positioned.fill(
                  child: ShelfEdgeFade(
                    start: (before / ShelfRow.fade).clamp(0, 1),
                    end: (after / ShelfRow.fade).clamp(0, 1),
                    child: list!,
                  ),
                ),
                Positioned(
                  left: NoirSpacing.sm,
                  top: arrowTop,
                  child: _Arrow(
                    icon: Icons.chevron_left_rounded,
                    tooltip: 'Scroll left',
                    size: widget.arrowSize,
                    visible: _hovered && before > 1,
                    onPressed: () => _page(-1),
                  ),
                ),
                Positioned(
                  right: NoirSpacing.sm,
                  top: arrowTop,
                  child: _Arrow(
                    icon: Icons.chevron_right_rounded,
                    tooltip: 'Scroll right',
                    size: widget.arrowSize,
                    visible: _hovered && after > 1,
                    onPressed: () => _page(1),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );

    final title = widget.title;
    if (title == null) return row;
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.eyebrow case final eyebrow?)
          Text(
            eyebrow.toUpperCase(),
            style: t.labelSmall?.copyWith(
              color: context.noir.textTertiary,
              letterSpacing: 0.8,
            ),
          ),
        Padding(
          // With [ShelfRow.lift] this matches [SectionHeader]'s gap.
          padding: const EdgeInsets.only(
            bottom: NoirSpacing.md - ShelfRow.lift,
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title, style: t.titleMedium),
                ),
              ),
              if (widget.actionLabel case final label?)
                TextButton(
                  onPressed: widget.onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: context.noir.textSecondary,
                    textStyle: t.labelMedium,
                  ),
                  child: Text(label),
                ),
            ],
          ),
        ),
        row,
      ],
    );
  }
}

/// Fades [child] out over [ShelfRow.fade] at either side; [start] / [end]
/// (0–1) set how strongly.
class ShelfEdgeFade extends StatelessWidget {
  const ShelfEdgeFade({
    required this.start,
    required this.end,
    required this.child,
    super.key,
  });

  final double start;
  final double end;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final f = rect.width <= 0
            ? 0.0
            : math.min(ShelfRow.fade / rect.width, 0.5);
        return LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 1 - start),
            Colors.white,
            Colors.white,
            Colors.white.withValues(alpha: 1 - end),
          ],
          stops: [0, f, 1 - f, 1],
        ).createShader(rect);
      },
      child: child,
    );
  }
}

/// Round glass paging button; fades in and out, untouchable while hidden.
class _Arrow extends StatelessWidget {
  const _Arrow({
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.visible,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final double size;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final fx = NoirEffects.of(context);
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeFocus(
        excluding: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: fx.motion(NoirMotion.medium),
          curve: NoirMotion.standard,
          child: AnimatedScale(
            scale: visible || !fx.animations ? 1 : 0.9,
            duration: fx.motion(NoirMotion.medium),
            curve: NoirMotion.standard,
            child: SizedBox.square(
              dimension: size,
              child: GlassSurface(
                borderRadius: NoirRadii.pillAll,
                shadow: 0.4,
                child: Center(
                  child: NoirIconButton(
                    icon: icon,
                    tooltip: tooltip,
                    size: size * 0.55,
                    color: context.noir.textPrimary,
                    onPressed: onPressed,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
