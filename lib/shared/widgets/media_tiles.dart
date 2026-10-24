import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/shelf_row.dart';

/// Square artwork with title and subtitle, as in "Recently played".
class MediaTile extends StatefulWidget {
  const MediaTile({
    required this.title,
    required this.subtitle,
    required this.artwork,
    required this.onTap,
    this.width = 150,
    this.onContextMenu,
    super.key,
  });

  final String title;
  final String subtitle;

  /// Built at [width]; usually an [Artwork] or [ArtworkCollage].
  final Widget Function(double size) artwork;
  final VoidCallback onTap;
  final double width;

  /// Right-click / long-press, with the pointer position.
  final ValueChanged<Offset>? onContextMenu;

  @override
  State<MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<MediaTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fx = NoirEffects.of(context);
    return Semantics(
      button: true,
      label: '${widget.title}, ${widget.subtitle}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapUp: widget.onContextMenu == null
              ? null
              : (d) => widget.onContextMenu!(d.globalPosition),
          onLongPressStart: widget.onContextMenu == null
              ? null
              : (d) => widget.onContextMenu!(d.globalPosition),
          child: SizedBox(
            width: widget.width,
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSlide(
                    offset: Offset(0, _hovered && fx.animations ? -0.02 : 0),
                    duration: fx.motion(NoirMotion.medium),
                    curve: NoirMotion.standard,
                    child: AnimatedScale(
                      scale: _hovered && fx.animations ? 1.02 : 1,
                      duration: fx.motion(NoirMotion.medium),
                      curve: NoirMotion.standard,
                      child: widget.artwork(widget.width),
                    ),
                  ),
                  const SizedBox(height: NoirSpacing.sm + 2),
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.labelLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.labelSmall?.copyWith(
                      color: context.noir.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [ShelfRow] of [MediaTile]s [tileWidth] wide, optionally titled.
class TileRow extends StatelessWidget {
  const TileRow({
    required this.children,
    this.tileWidth = 150,
    this.title,
    this.eyebrow,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final List<Widget> children;
  final double tileWidth;
  final String? title;
  final String? eyebrow;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return ShelfRow(
      // Title + subtitle grow with the user's text size.
      height: tileWidth + 16 + MediaQuery.textScalerOf(context).scale(38),
      itemExtent: tileWidth + NoirSpacing.lg,
      arrowCenter: tileWidth / 2,
      title: title,
      eyebrow: eyebrow,
      actionLabel: actionLabel,
      onAction: onAction,
      children: children,
    );
  }
}

/// Row for library lists: thumbnail, name, detail, chevron.
class CollectionRow extends StatelessWidget {
  const CollectionRow({
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.onTap,
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget leading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.noir;
    return InkWell(
      onTap: onTap,
      borderRadius: NoirRadii.mdAll,
      hoverColor: c.hover,
      hoverDuration: NoirEffects.of(context).motion(NoirMotion.fast),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NoirSpacing.sm,
          vertical: NoirSpacing.sm - 2,
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: NoirSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, style: t.bodySmall),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// Round artist thumbnail.
Widget artistAvatar(String? path, double size) => Artwork(
  path: path,
  size: size,
  radius: size / 2,
  icon: Icons.person_rounded,
);
