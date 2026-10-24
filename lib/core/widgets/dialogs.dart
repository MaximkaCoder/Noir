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

void showToast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        width: 360,
        duration: const Duration(seconds: 3),
      ),
    );
}
