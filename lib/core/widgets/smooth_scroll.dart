import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// Scroll controller whose mouse-wheel steps glide instead of jumping.
///
/// Each wheel notch animates toward a target; notches arriving mid-glide
/// extend the same target, so fast spinning stays continuous. Touch, trackpad
/// and scrollbar dragging are untouched (they don't go through
/// [ScrollPosition.pointerScroll]).
class SmoothScrollController extends ScrollController {
  SmoothScrollController({this.smooth = true, super.debugLabel});

  /// False when the user turned animations off: wheel scrolling jumps.
  bool smooth;

  static const duration = Duration(milliseconds: 260);
  static const curve = Curves.easeOutCubic;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SmoothScrollPosition(
    controller: this,
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required this.controller,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final SmoothScrollController controller;
  double? _target;

  @override
  void pointerScroll(double delta) {
    if (!controller.smooth || delta == 0) {
      _target = null;
      super.pointerScroll(delta);
      return;
    }
    final from = _target ?? pixels;
    final target = (from + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) return;
    _target = target;
    unawaited(
      animateTo(
        target,
        duration: SmoothScrollController.duration,
        curve: SmoothScrollController.curve,
      ).whenComplete(() {
        if (_target == target) _target = null;
      }),
    );
  }

  @override
  void jumpTo(double value) {
    _target = null;
    super.jumpTo(value);
  }
}

/// Provides a [SmoothScrollController] (following the Animations setting) to
/// [builder], and disposes it.
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({required this.builder, super.key});

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  final _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _controller.smooth = NoirEffects.of(context).animations;
    return widget.builder(context, _controller);
  }
}
