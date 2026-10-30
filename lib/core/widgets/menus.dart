import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/platform/form_factor.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/liquid_press.dart';

/// One action in a [showNoirMenu] menu.
@immutable
class NoirMenuItem<T> {
  const NoirMenuItem(this.value, this.label, {this.icon, this.checked = false});

  final T value;
  final String label;
  final IconData? icon;

  /// Shows a check mark (current sort order, etc.).
  final bool checked;
}

/// NOIR's context menu: a small elevated panel next to [anchor] (global
/// coordinates; a zero-size rect for a pointer position) that fades and
/// scales in; on a phone, a [showNoirSheet]. Returns the chosen value, or
/// null when dismissed.
Future<T?> showNoirMenu<T>(
  BuildContext context, {
  required Rect anchor,
  required List<NoirMenuItem<T>> items,
}) {
  if (FormFactor.touch) {
    return showNoirSheet<T>(
      context,
      label: 'Close menu',
      child: _MenuPanel<T>(items: items, sheet: true),
    );
  }
  final fx = NoirEffects.of(context);
  return Navigator.of(context, rootNavigator: true).push(
    _MenuRoute<T>(
      anchor: anchor,
      panel: _MenuPanel<T>(items: items),
      duration: fx.motion(NoirMotion.medium),
      reverseDuration: fx.motion(NoirMotion.fast),
    ),
  );
}

/// A panel of any [child] shown next to [anchor] the way [showNoirMenu]
/// shows a menu, on the same glass. Pop the route to close it.
Future<void> showNoirPopover(
  BuildContext context, {
  required Rect anchor,
  required Widget child,
}) {
  final fx = NoirEffects.of(context);
  return Navigator.of(context, rootNavigator: true).push(
    _MenuRoute<void>(
      anchor: anchor,
      panel: GlassSurface(
        borderRadius: NoirRadii.mdAll,
        floating: true,
        shadow: 0.6,
        fillOpacity: 4,
        child: Material(type: MaterialType.transparency, child: child),
      ),
      duration: fx.motion(NoirMotion.medium),
      reverseDuration: fx.motion(NoirMotion.fast),
    ),
  );
}

/// A phone's menu: an opaque sheet up from the bottom, timed like the queue
/// sheet (a popover fading in over glass stuttered there). [label] names
/// the barrier that closes it. Pop the route to close it.
Future<T?> showNoirSheet<T>(
  BuildContext context, {
  required Widget child,
  required String label,
}) {
  final fx = NoirEffects.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: label,
    barrierColor: Colors.black.withValues(alpha: 0.3),
    transitionDuration: fx.motion(NoirMotion.slow),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Material(
          color: context.noir.background,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(NoirRadii.xl),
          ),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(top: NoirSpacing.sm),
              child: child,
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
        CurvedAnimation(
          parent: animation,
          curve: NoirMotion.emphasized,
          reverseCurve: Curves.easeInCubic,
        ),
      ),
      child: child,
    ),
  );
}

/// Icon button that opens a [showNoirMenu] below itself.
class NoirMenuButton<T> extends StatelessWidget {
  const NoirMenuButton({
    required this.icon,
    required this.tooltip,
    required this.items,
    required this.onSelected,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final List<NoirMenuItem<T>> Function() items;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return NoirIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: () async {
        final box = context.findRenderObject()! as RenderBox;
        final anchor = box.localToGlobal(Offset.zero) & box.size;
        final value = await showNoirMenu<T>(
          context,
          anchor: anchor,
          items: items(),
        );
        if (value != null) onSelected(value);
      },
    );
  }
}

class _MenuRoute<T> extends PopupRoute<T> {
  _MenuRoute({
    required this.anchor,
    required this.panel,
    required this.duration,
    required this.reverseDuration,
  });

  final Rect anchor;
  final Widget panel;
  final Duration duration;
  final Duration reverseDuration;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Dismiss menu';

  @override
  Duration get transitionDuration => duration;

  @override
  Duration get reverseTransitionDuration => reverseDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: NoirMotion.standard,
      reverseCurve: NoirMotion.exit,
    );
    return CustomSingleChildLayout(
      delegate: _MenuLayout(anchor),
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, child) =>
            GlassFade(opacity: curved.value, child: child!),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
          child: panel,
        ),
      ),
    );
  }
}

/// Below the anchor when it fits, otherwise above; left-aligned with it,
/// or right-aligned near the right edge. Always 8 px inside the window.
class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.anchor);

  final Rect anchor;
  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: 180,
        maxWidth: 300,
        maxHeight: math.max(0, constraints.maxHeight - _margin * 2),
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = anchor.left;
    if (x + child.width > size.width - _margin) x = anchor.right - child.width;
    var y = anchor.bottom;
    if (y + child.height > size.height - _margin) y = anchor.top - child.height;
    return Offset(
      x.clamp(_margin, math.max(_margin, size.width - child.width - _margin)),
      y.clamp(_margin, math.max(_margin, size.height - child.height - _margin)),
    );
  }

  @override
  bool shouldRelayout(_MenuLayout old) => anchor != old.anchor;
}

class _MenuPanel<T> extends StatelessWidget {
  const _MenuPanel({required this.items, this.sheet = false});

  final List<NoirMenuItem<T>> items;

  /// In a [showNoirSheet]: full width, opaque, rows sized for fingers.
  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    final fx = NoirEffects.of(context);
    final Widget list = SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: NoirSpacing.xs),
      child: _width(
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, item) in items.indexed)
              LiquidPress(
                pressedScale: 0.98,
                bubbleScale: 1,
                child: InkWell(
                  autofocus: i == 0 && !sheet,
                  onTap: () => Navigator.of(context).pop(item.value),
                  hoverColor: c.hover,
                  focusColor: c.selected,
                  hoverDuration: fx.motion(NoirMotion.fast),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: sheet ? 52 : 40),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NoirSpacing.lg,
                        vertical: NoirSpacing.sm,
                      ),
                      child: Row(
                        children: [
                          if (item.icon != null) ...[
                            Icon(item.icon, size: 18),
                            const SizedBox(width: NoirSpacing.md),
                          ],
                          Expanded(
                            child: Text(item.label, style: t.bodyMedium),
                          ),
                          if (item.checked) ...[
                            const SizedBox(width: NoirSpacing.md),
                            Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: c.textPrimary,
                              semanticLabel: 'Selected',
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Menu',
      child: sheet
          ? list
          // Liquid Glass with a scrim, so items stay legible on clear glass.
          : GlassSurface(
              borderRadius: NoirRadii.mdAll,
              floating: true,
              shadow: 0.6,
              fillOpacity: 4,
              child: Material(type: MaterialType.transparency, child: list),
            ),
    );
  }

  /// As wide as the widest item; a sheet's full width.
  Widget _width(Widget column) =>
      sheet ? column : IntrinsicWidth(child: column);
}
