import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/glass_surface.dart';

/// Borderless icon button with tooltip, hover feedback and a visible focus
/// ring. Every icon-only action in NOIR goes through this.
class NoirIconButton extends StatelessWidget {
  const NoirIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 20,
    this.active = false,
    this.color,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  /// Highlighted state (e.g. shuffle on).
  final bool active;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    // Active / inactive color changes fade instead of snapping.
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(
        end: color ?? (active ? c.textPrimary : c.textSecondary),
      ),
      duration: NoirEffects.of(context).motion(NoirMotion.fast),
      builder: (context, animated, _) => IconButton(
        icon: Icon(icon, size: size),
        tooltip: tooltip,
        onPressed: onPressed,
        color: animated,
        disabledColor: c.textTertiary.withValues(alpha: 0.5),
        hoverColor: c.hover,
        focusColor: c.selected,
        style: IconButton.styleFrom(
          minimumSize: const Size.square(36),
          padding: const EdgeInsets.all(NoirSpacing.sm),
        ),
      ),
    );
  }
}

/// The white circular play/pause button from the reference design.
class PrimaryPlayButton extends StatelessWidget {
  const PrimaryPlayButton({
    required this.playing,
    required this.onPressed,
    this.size = 48,
    this.playTooltip = 'Play',
    super.key,
  });

  final bool playing;
  final VoidCallback? onPressed;
  final double size;
  final String playTooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    return Tooltip(
      message: playing ? 'Pause' : playTooltip,
      child: Semantics(
        button: true,
        label: playing ? 'Pause' : playTooltip,
        child: _Pressable(
          onPressed: onPressed,
          scale: fx.animations,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.primaryActionFill,
              boxShadow: [
                BoxShadow(
                  color: c.shadow.withValues(alpha: c.shadow.a * 0.6),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: AnimatedSwitcher(
              duration: fx.motion(NoirMotion.fast),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(playing),
                size: size * 0.5,
                color: c.primaryActionText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass pill used for secondary actions ("Create playlist", "Add folder").
class PillButton extends StatelessWidget {
  const PillButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.filled = false,
    super.key,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// White primary style instead of glass.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fg = filled ? c.primaryActionText : c.textPrimary;
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NoirSpacing.lg,
        vertical: NoirSpacing.sm + 2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: NoirSpacing.sm),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: _Pressable(
        onPressed: onPressed,
        scale: NoirEffects.of(context).animations,
        child: filled
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: c.primaryActionFill,
                  borderRadius: NoirRadii.pillAll,
                ),
                child: content,
              )
            : GlassSurface(
                borderRadius: NoirRadii.pillAll,
                interactive: true,
                blur: 0,
                child: content,
              ),
      ),
    );
  }
}

/// Rounded filter chip row item ("Playlists", "Artists", …).
class PillChip extends StatelessWidget {
  const PillChip({
    required this.label,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: _Pressable(
        onPressed: onSelected,
        scale: false,
        child: AnimatedContainer(
          duration: fx.motion(NoirMotion.medium),
          curve: NoirMotion.standard,
          padding: const EdgeInsets.symmetric(
            horizontal: NoirSpacing.lg,
            vertical: NoirSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: selected ? c.selected : Colors.transparent,
            borderRadius: NoirRadii.pillAll,
            border: Border.all(
              color: selected ? c.glassBorder : Colors.transparent,
            ),
          ),
          child: AnimatedDefaultTextStyle(
            duration: fx.motion(NoirMotion.medium),
            curve: NoirMotion.standard,
            style: Theme.of(context).textTheme.labelLarge!
                .copyWith(color: selected ? c.textPrimary : c.textSecondary),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}

/// Keyboard-activatable press target with a subtle scale on press.
class _Pressable extends StatefulWidget {
  const _Pressable({
    required this.child,
    required this.onPressed,
    required this.scale,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool scale;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        child: AnimatedScale(
          scale: widget.scale && _down ? 0.96 : 1,
          duration: NoirMotion.fast,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: NoirRadii.pillAll,
              border: _focused
                  ? Border.all(color: context.noir.textPrimary, width: 1.5)
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
