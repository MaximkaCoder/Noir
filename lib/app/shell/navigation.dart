import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// Shell branches, in `StatefulShellRoute` order.
enum Branch {
  home('Home', Icons.home_outlined, Icons.home_rounded),
  search('Search', Icons.search_rounded, Icons.search_rounded),
  library('Library', Icons.library_music_outlined, Icons.library_music_rounded),
  settings('Settings', Icons.settings_outlined, Icons.settings_rounded);

  Branch(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Opacity and offset of one page during a fade-through at [t] (0–1): the
/// outgoing page fades out first, then the incoming one fades in while
/// rising [NoirMotion.shift] px. Shared by branch switches and pushed pages.
({double opacity, double dy}) fadeThrough(double t, {required bool incoming}) {
  if (!incoming) {
    return (
      opacity: 1 - const Interval(0, 0.4, curve: NoirMotion.exit).transform(t),
      dy: 0,
    );
  }
  final v = const Interval(0.3, 1, curve: NoirMotion.standard).transform(t);
  return (opacity: v, dy: (1 - v) * NoirMotion.shift);
}

/// Branch navigators stacked like `IndexedStack` — every visited branch
/// keeps its state — with a short fade-through when the index changes.
class BranchSwitcher extends StatefulWidget {
  const BranchSwitcher({
    required this.index,
    required this.children,
    super.key,
  });

  final int index;
  final List<Widget> children;

  @override
  State<BranchSwitcher> createState() => _BranchSwitcherState();
}

class _BranchSwitcherState extends State<BranchSwitcher>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, value: 1);
  int? _previous;

  @override
  void didUpdateWidget(BranchSwitcher old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    final duration = NoirEffects.of(context).motion(NoirMotion.layout);
    if (duration == Duration.zero) {
      _previous = null;
      _controller.value = 1;
      return;
    }
    _previous = old.index;
    _controller
      ..duration = duration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final leaving = t < 1 ? _previous : null;
        return Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              _branch(i, t, leaving),
          ],
        );
      },
    );
  }

  /// Same wrapper structure for every branch and frame, so no navigator is
  /// ever re-parented.
  Widget _branch(int i, double t, int? leaving) {
    final active = i == widget.index;
    final visible = active || i == leaving;
    final (:opacity, :dy) = active
        ? fadeThrough(t, incoming: true)
        : fadeThrough(t, incoming: false);
    return Offstage(
      offstage: !visible,
      child: TickerMode(
        enabled: active,
        child: IgnorePointer(
          ignoring: !active,
          child: Opacity(
            opacity: visible ? opacity : 0,
            child: Transform.translate(
              offset: Offset(0, dy),
              child: widget.children[i],
            ),
          ),
        ),
      ),
    );
  }
}
