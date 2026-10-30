import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/platform/form_factor.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/menus.dart';
import 'package:noir/core/widgets/reveal.dart';
import 'package:noir/features/playback/application/transition_status.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';

/// The transition modes this build can play: Smart and Disco need their
/// planners.
List<TransitionMode> _available(WidgetRef ref) => [
  TransitionMode.off,
  TransitionMode.crossfade,
  if (ref.watch(transitionPlannerProvider) != null) TransitionMode.smart,
  if (ref.watch(discoPlannerProvider) != null) TransitionMode.disco,
];

/// The stored mode, or the next simpler one when its planner is missing
/// (that is how it plays).
TransitionMode _effective(WidgetRef ref) {
  final available = _available(ref);
  return switch (ref.watch(settingsProvider.select((s) => s.transitionMode))) {
    TransitionMode.disco when !available.contains(TransitionMode.disco) =>
      available.contains(TransitionMode.smart)
          ? TransitionMode.smart
          : TransitionMode.crossfade,
    TransitionMode.smart when !available.contains(TransitionMode.smart) =>
      TransitionMode.crossfade,
    final m => m,
  };
}

String _name(TransitionMode mode) => switch (mode) {
  TransitionMode.off => 'Off',
  TransitionMode.crossfade => 'Crossfade',
  TransitionMode.smart => 'Smart',
  TransitionMode.disco => 'Disco',
};

/// Player button for how one track hands over to the next; opens a panel
/// with every mode and the crossfade length.
class MixModeButton extends ConsumerWidget {
  const MixModeButton({this.size = 20, super.key});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = _effective(ref);
    return NoirIconButton(
      glyph: MixModeIcon(mode, size: size),
      tooltip: 'Transitions: ${_name(mode)}',
      active: mode != TransitionMode.off,
      size: size,
      onPressed: () {
        if (FormFactor.touch) {
          unawaited(
            showNoirSheet<void>(
              context,
              label: 'Close transitions',
              child: const _MixPanel(width: double.infinity),
            ),
          );
          return;
        }
        final box = context.findRenderObject()! as RenderBox;
        unawaited(
          showNoirPopover(
            context,
            // A small gap between the button and the panel.
            anchor: (box.localToGlobal(Offset.zero) & box.size).inflate(6),
            child: const _MixPanel(),
          ),
        );
      },
    );
  }
}

class _MixPanel extends ConsumerWidget {
  const _MixPanel({this.width = 300});

  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    final mode = _effective(ref);
    final seconds = ref.watch(
      settingsProvider.select((s) => s.crossfadeSeconds),
    );
    final ctrl = ref.read(settingsProvider.notifier);
    String detail(TransitionMode m) => switch (m) {
      TransitionMode.off => 'Each song plays to its end',
      TransitionMode.crossfade => 'Fades over $seconds s',
      TransitionMode.smart => 'Chooses when and how to blend',
      TransitionMode.disco => 'A few minutes each, like a DJ set',
    };

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Transitions',
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: NoirSpacing.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NoirSpacing.lg,
                  NoirSpacing.sm,
                  NoirSpacing.lg,
                  NoirSpacing.xs,
                ),
                child: ExcludeSemantics(
                  child: Text(
                    'TRANSITIONS',
                    style: t.labelSmall?.copyWith(
                      color: c.textTertiary,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              for (final m in _available(ref))
                Semantics(
                  selected: m == mode,
                  inMutuallyExclusiveGroup: true,
                  child: InkWell(
                    onTap: () {
                      ctrl.update((s) => s.copyWith(transitionMode: m));
                      // Crossfade stays open for its length.
                      if (m != TransitionMode.crossfade) {
                        Navigator.of(context).pop();
                      }
                    },
                    hoverColor: c.hover,
                    focusColor: c.selected,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NoirSpacing.lg,
                        vertical: NoirSpacing.sm,
                      ),
                      child: Row(
                        children: [
                          IconTheme.merge(
                            data: IconThemeData(
                              color: m == mode
                                  ? c.textPrimary
                                  : c.textSecondary,
                            ),
                            child: MixModeIcon(m),
                          ),
                          const SizedBox(width: NoirSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_name(m), style: t.bodyMedium),
                                Text(
                                  detail(m),
                                  style: t.bodySmall?.copyWith(
                                    color: c.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (m == mode) ...[
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
              Reveal(
                visible: mode == TransitionMode.crossfade,
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: NoirSpacing.lg,
                    right: NoirSpacing.lg,
                  ),
                  child: Row(
                    children: [
                      Text('Length', style: t.bodySmall),
                      Expanded(
                        child: Slider(
                          value: seconds.toDouble(),
                          min: 1,
                          max: 12,
                          divisions: 11,
                          label: '$seconds s',
                          semanticFormatterCallback: (_) => '$seconds s',
                          onChanged: (v) => ctrl.update(
                            (s) => s.copyWith(crossfadeSeconds: v.round()),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 32,
                        child: Text(
                          '$seconds s',
                          style: t.bodySmall,
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Line icon for a [TransitionMode], in the surrounding [IconTheme] color.
class MixModeIcon extends StatelessWidget {
  const MixModeIcon(this.mode, {this.size = 20, super.key});

  final TransitionMode mode;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _MixModePainter(
      mode,
      IconTheme.of(context).color ?? context.noir.textPrimary,
    ),
  );
}

class _MixModePainter extends CustomPainter {
  _MixModePainter(this.mode, this.color);

  final TransitionMode mode;
  final Color color;

  /// Drawn on a 24 × 24 grid.
  static Path _path(TransitionMode mode) => switch (mode) {
    // One track ends, the next starts.
    TransitionMode.off =>
      Path()
        ..moveTo(3, 12)
        ..lineTo(9, 12)
        ..moveTo(9, 8)
        ..lineTo(9, 16)
        ..moveTo(15, 8)
        ..lineTo(15, 16)
        ..moveTo(15, 12)
        ..lineTo(21, 12),
    // Two crossing fades.
    TransitionMode.crossfade =>
      Path()
        ..moveTo(3, 7)
        ..cubicTo(10, 7, 14, 17, 21, 17)
        ..moveTo(3, 17)
        ..cubicTo(10, 17, 14, 7, 21, 7),
    // Crossing fades with a spark.
    TransitionMode.smart =>
      Path()
        ..moveTo(2, 9)
        ..cubicTo(8, 9, 11, 18, 17, 18)
        ..moveTo(2, 18)
        ..cubicTo(8, 18, 11, 9, 17, 9)
        ..moveTo(20, 2)
        ..lineTo(20, 7)
        ..moveTo(17.5, 4.5)
        ..lineTo(22.5, 4.5),
    // A disco ball.
    TransitionMode.disco =>
      Path()
        ..addOval(Rect.fromCircle(center: const Offset(12, 14), radius: 7))
        ..moveTo(5, 14)
        ..lineTo(19, 14)
        ..moveTo(12, 7)
        ..cubicTo(9, 10, 9, 18, 12, 21)
        ..moveTo(12, 7)
        ..cubicTo(15, 10, 15, 18, 12, 21)
        ..moveTo(12, 2)
        ..lineTo(12, 7),
  };

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..scale(size.width / 24)
      ..drawPath(
        _path(mode),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
  }

  @override
  bool shouldRepaint(_MixModePainter old) =>
      old.mode != mode || old.color != color;
}
