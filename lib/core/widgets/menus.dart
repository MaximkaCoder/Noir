import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/buttons.dart';

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
/// scales in. Returns the chosen value, or null when dismissed.
Future<T?> showNoirMenu<T>(
  BuildContext context, {
  required Rect anchor,
  required List<NoirMenuItem<T>> items,
}) {
  final fx = NoirEffects.of(context);
  return Navigator.of(context, rootNavigator: true).push(
    _MenuRoute<T>(
      anchor: anchor,
      items: items,
      duration: fx.motion(NoirMotion.medium),
      reverseDuration: fx.motion(NoirMotion.fast),
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
    required this.items,
    required this.duration,
    required this.reverseDuration,
  });

  final Rect anchor;
  final List<NoirMenuItem<T>> items;
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
      child: FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
          child: _MenuPanel<T>(items: items),
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
  const _MenuPanel({required this.items});

  final List<NoirMenuItem<T>> items;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    final fx = NoirEffects.of(context);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Menu',
      child: Material(
        color: c.surfaceElevated,
        elevation: 12,
        shadowColor: c.shadow,
        shape: RoundedRectangleBorder(
          borderRadius: NoirRadii.mdAll,
          side: BorderSide(color: c.glassBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: NoirSpacing.xs),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, item) in items.indexed)
                  InkWell(
                    autofocus: i == 0,
                    onTap: () => Navigator.of(context).pop(item.value),
                    hoverColor: c.hover,
                    focusColor: c.selected,
                    hoverDuration: fx.motion(NoirMotion.fast),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 40),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
