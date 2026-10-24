import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/buttons.dart';

/// Calm explanation with an optional next step. Used for empty and error
/// states so every screen says what happened and what to do.
class MessageState extends StatelessWidget {
  const MessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Smaller variant for inline sections.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: EdgeInsets.all(compact ? NoirSpacing.lg : NoirSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: compact ? 28 : 40, color: c.textTertiary),
              SizedBox(height: compact ? NoirSpacing.md : NoirSpacing.lg),
              Text(
                title,
                style: compact ? t.titleSmall : t.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: NoirSpacing.sm),
              Text(message, style: t.bodySmall, textAlign: TextAlign.center),
              if (actionLabel != null) ...[
                const SizedBox(height: NoirSpacing.xl),
                PillButton(label: actionLabel!, onPressed: onAction),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyState extends MessageState {
  const EmptyState({
    required super.title,
    required super.message,
    super.icon = Icons.album_outlined,
    super.actionLabel,
    super.onAction,
    super.compact,
    super.key,
  });
}

class ErrorState extends MessageState {
  const ErrorState({
    required super.message,
    super.title = 'Something went wrong',
    super.icon = Icons.error_outline_rounded,
    super.actionLabel,
    super.onAction,
    super.compact,
    super.key,
  });
}

/// Static skeleton rows. No shimmer: constant motion is avoided by design.
class LoadingState extends StatelessWidget {
  const LoadingState({this.rows = 6, super.key});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: c.hover, borderRadius: NoirRadii.smAll),
    );
    return Semantics(
      label: 'Loading',
      child: ExcludeSemantics(
        child: Column(
          children: [
            for (var i = 0; i < rows; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: NoirSpacing.sm),
                child: Row(
                  children: [
                    bar(44, 44),
                    const SizedBox(width: NoirSpacing.md),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        bar(160, 12),
                        const SizedBox(height: NoirSpacing.sm),
                        bar(96, 10),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Section title with an optional trailing action ("See all").
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {this.action, this.onAction, super.key});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: NoirSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: t.titleMedium),
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: context.noir.textSecondary,
                textStyle: t.labelMedium,
              ),
              child: Text(action!),
            ),
        ],
      ),
    );
  }
}
