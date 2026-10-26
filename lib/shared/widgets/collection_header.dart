import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/buttons.dart';

/// Header for album, artist, favorites and playlist pages: artwork, title,
/// "32 songs · 2h 14m", and the play / shuffle / extra actions row.
class CollectionHeader extends StatelessWidget {
  const CollectionHeader({
    required this.artwork,
    required this.title,
    required this.subtitle,
    required this.onPlay,
    required this.onShuffle,
    this.eyebrow,
    this.onSurprise,
    this.actions = const [],
    super.key,
  });

  final Widget Function(double size) artwork;
  final String? eyebrow;
  final String title;
  final String subtitle;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  /// Surprise me (shown when set): a random start, then the tracks that
  /// mix best.
  final VoidCallback? onSurprise;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final compact =
        WindowClass.of(MediaQuery.sizeOf(context).width) == WindowClass.compact;
    final art = compact ? 132.0 : 168.0;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (eyebrow != null) ...[
          Text(eyebrow!, style: t.labelMedium),
          const SizedBox(height: 4),
        ],
        Semantics(
          header: true,
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: compact ? t.headlineSmall : t.headlineMedium,
          ),
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: t.bodySmall),
        const SizedBox(height: NoirSpacing.lg),
        Row(
          children: [
            PrimaryPlayButton(playing: false, onPressed: onPlay, size: 44),
            const SizedBox(width: NoirSpacing.sm),
            NoirIconButton(
              icon: Icons.shuffle_rounded,
              tooltip: 'Shuffle play',
              onPressed: onShuffle,
            ),
            if (onSurprise != null)
              NoirIconButton(
                icon: Icons.auto_awesome_rounded,
                tooltip: 'Surprise me',
                onPressed: onSurprise,
              ),
            ...actions,
          ],
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(
        top: NoirSpacing.lg,
        bottom: NoirSpacing.xl,
      ),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: NoirRadii.lgAll,
              boxShadow: [
                BoxShadow(
                  color: context.noir.shadow.withValues(alpha: 0.35),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: artwork(art),
          ),
          const SizedBox(width: NoirSpacing.xl),
          Expanded(child: info),
        ],
      ),
    );
  }
}
