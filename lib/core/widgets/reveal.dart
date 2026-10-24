import 'package:flutter/widgets.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// Shows or hides [child] by growing / shrinking its height while fading
/// it, instead of popping it in and out of the layout. The child is only
/// built while visible (so `autofocus` works), and the last one stays on
/// screen while it collapses.
class Reveal extends StatelessWidget {
  const Reveal({required this.visible, required this.child, super.key});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = NoirEffects.of(context).motion(NoirMotion.medium);
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: NoirMotion.standard,
      switchOutCurve: NoirMotion.exit,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: animation, child: child),
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, ?current],
      ),
      child: visible
          ? KeyedSubtree(key: const ValueKey(true), child: child)
          : const SizedBox(key: ValueKey(false), width: double.infinity),
    );
  }
}
