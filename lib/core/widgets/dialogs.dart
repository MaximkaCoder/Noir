import 'dart:async';

import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';

/// Shows the widget built by `builder` in a glass dialog over a dimmed
/// backdrop.
Future<T?> showGlassDialog<T>(
  BuildContext context, {
  required Widget Function(BuildContext context) builder,
}) {
  final fx = NoirEffects.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: fx.motion(NoirMotion.medium),
    pageBuilder: (context, _, _) => SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(NoirSpacing.lg),
            child: Material(
              type: MaterialType.transparency,
              child: GlassSurface(
                borderRadius: NoirRadii.xlAll,
                shadow: 1,
                fillOpacity: fx.glass ? 2.5 : 1,
                padding: const EdgeInsets.all(NoirSpacing.xl),
                child: builder(context),
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: NoirMotion.standard,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Returns true when the user confirms.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showGlassDialog<bool>(
    context,
    builder: (context) {
      final t = Theme.of(context).textTheme;
      final c = context.noir;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.titleMedium),
          const SizedBox(height: NoirSpacing.sm),
          Text(message, style: t.bodySmall),
          const SizedBox(height: NoirSpacing.xl),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: NoirSpacing.sm),
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: destructive ? c.destructive : c.textPrimary,
                ),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Single-line text prompt (playlist names). Returns null when cancelled.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initial = '',
  String hint = '',
}) {
  return showGlassDialog<String>(
    context,
    builder: (context) => _PromptBody(
      title: title,
      confirmLabel: confirmLabel,
      initial: initial,
      hint: hint,
    ),
  );
}

class _PromptBody extends StatefulWidget {
  const _PromptBody({
    required this.title,
    required this.confirmLabel,
    required this.initial,
    required this.hint,
  });

  final String title;
  final String confirmLabel;
  final String initial;
  final String hint;

  @override
  State<_PromptBody> createState() => _PromptBodyState();
}

class _PromptBodyState extends State<_PromptBody> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isNotEmpty) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.noir;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.title, style: t.titleMedium),
        const SizedBox(height: NoirSpacing.lg),
        TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 120,
          onSubmitted: (_) => _submit(),
          style: t.bodyMedium,
          decoration: InputDecoration(
            hintText: widget.hint,
            counterText: '',
            filled: true,
            fillColor: c.hover,
            border: const OutlineInputBorder(
              borderRadius: NoirRadii.mdAll,
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: NoirSpacing.xl),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(foregroundColor: c.textSecondary),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: NoirSpacing.sm),
            PillButton(
              label: widget.confirmLabel,
              filled: true,
              onPressed: _submit,
            ),
          ],
        ),
      ],
    );
  }
}

OverlayEntry? _toast;

/// Short confirmation at the bottom of the window. Fades and scales in, sits
/// above the floating player (via the caller's bottom padding), and replaces
/// any toast still showing. Never takes pointer input.
void showToast(BuildContext context, String message) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  if (_toast?.mounted ?? false) _toast!.remove();
  final bottom = MediaQuery.paddingOf(context).bottom + NoirSpacing.lg;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Toast(
      message: message,
      bottom: bottom,
      onDone: () {
        if (identical(_toast, entry)) _toast = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  _toast = entry;
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  const _Toast({
    required this.message,
    required this.bottom,
    required this.onDone,
  });

  final String message;
  final double bottom;
  final VoidCallback onDone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  static const _visible = Duration(seconds: 3);

  // One controller drives in, hold and out, so nothing outlives the widget
  // (no timers left behind when the app is torn down).
  late final AnimationController _life = AnimationController(vsync: this);
  late Animation<double> _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_life.isAnimating || _life.isCompleted) return;
    final fx = NoirEffects.of(context);
    final fade = fx.motion(NoirMotion.medium).inMilliseconds;
    final total = fade * 2 + _visible.inMilliseconds;
    final edge = fade / total;
    _shown = TweenSequence<double>([
      if (edge > 0)
        TweenSequenceItem(
          tween: Tween<double>(
            begin: 0,
            end: 1,
          ).chain(CurveTween(curve: NoirMotion.standard)),
          weight: edge,
        ),
      TweenSequenceItem(tween: ConstantTween<double>(1), weight: 1 - edge * 2),
      if (edge > 0)
        TweenSequenceItem(
          tween: Tween<double>(
            begin: 1,
            end: 0,
          ).chain(CurveTween(curve: NoirMotion.exit)),
          weight: edge,
        ),
    ]).animate(_life);
    _life.duration = Duration(milliseconds: total);
    unawaited(
      _life.forward().whenComplete(() {
        if (mounted) widget.onDone();
      }),
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    return Positioned(
      left: NoirSpacing.lg,
      right: NoirSpacing.lg,
      bottom: widget.bottom,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: _shown,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(_shown),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Semantics(
                  liveRegion: true,
                  child: GlassSurface(
                    borderRadius: NoirRadii.mdAll,
                    shadow: 0.8,
                    fillOpacity: fx.glass ? 3 : 1,
                    padding: const EdgeInsets.symmetric(
                      horizontal: NoirSpacing.lg,
                      vertical: NoirSpacing.md,
                    ),
                    child: Text(
                      widget.message,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: c.textPrimary),
                    ),
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
