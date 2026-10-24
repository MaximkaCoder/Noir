import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/shell/adaptive_shell.dart';
import 'package:noir/app/shell/navigation.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';
import 'package:noir/features/playlists/application/playlist_providers.dart';
import 'package:noir/features/playlists/presentation/add_to_playlist.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';

const List<Branch> _primaryBranches = [
  Branch.home,
  Branch.search,
  Branch.library,
];

const double _expandedWidth = 248;
const double _collapsedWidth = 80;

/// Room for a nav label at full width: sidebar minus item insets and icon.
const double _labelWidth = _expandedWidth - 2 - 24 - 17 - 20 - 14 - 14;

/// Desktop sidebar from the reference design. Collapses into an icon rail
/// by animating its width: icons stay put while labels and the playlist
/// section fade, so the change reads as one motion instead of a swap.
class Sidebar extends StatelessWidget {
  const Sidebar({
    required this.shell,
    required this.collapsed,
    this.canToggle = true,
    super.key,
  });

  final StatefulNavigationShell shell;
  final bool collapsed;

  /// Medium windows are always a rail; only wide ones offer the toggle.
  final bool canToggle;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: collapsed ? 0 : 1),
      duration: NoirEffects.of(context).motion(NoirMotion.layout),
      curve: NoirMotion.emphasized,
      builder: (context, t, _) => SizedBox(
        width: lerpDouble(_collapsedWidth, _expandedWidth, t),
        child: GlassSurface(
          borderRadius: BorderRadius.zero,
          highlight: 0.5,
          child: _SidebarBody(
            shell: shell,
            t: t,
            collapsed: collapsed,
            canToggle: canToggle,
          ),
        ),
      ),
    );
  }
}

class _SidebarBody extends ConsumerWidget {
  const _SidebarBody({
    required this.shell,
    required this.t,
    required this.collapsed,
    required this.canToggle,
  });

  final StatefulNavigationShell shell;

  /// 0 = rail, 1 = full sidebar.
  final double t;
  final bool collapsed;
  final bool canToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.path;
    // Labels appear late when expanding and leave early when collapsing,
    // so they never show cramped.
    final labels = const Interval(0.4, 1, curve: Curves.easeOut).transform(t);
    final rail = 1 - const Interval(0, 0.5).transform(t);

    final toggle = canToggle
        ? Padding(
            padding: const EdgeInsets.only(left: 21),
            child: Transform.rotate(
              angle: (1 - t) * math.pi,
              child: NoirIconButton(
                icon: Icons.keyboard_double_arrow_left_rounded,
                tooltip: collapsed ? 'Expand sidebar' : 'Collapse sidebar',
                size: 18,
                onPressed: () => ref
                    .read(settingsProvider.notifier)
                    .update((s) => s.copyWith(sidebarCollapsed: !collapsed)),
              ),
            ),
          )
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Window drag area; macOS keeps its traffic lights top-left.
        WindowDragArea(
          child: SizedBox(
            height: 48,
            child: reservesWindowControlsSpace
                ? null
                : Row(children: [?toggle]),
          ),
        ),
        if (reservesWindowControlsSpace && toggle != null)
          Row(children: [toggle]),
        const SizedBox(height: NoirSpacing.sm),
        for (final b in _primaryBranches)
          _NavItem(
            label: b.label,
            icon: shell.currentIndex == b.index ? b.selectedIcon : b.icon,
            labelOpacity: labels,
            tooltip: t == 0,
            selected:
                shell.currentIndex == b.index &&
                !location.startsWith('/library/playlist') &&
                !location.startsWith('/library/youtube') &&
                location != '/library/favorites',
            onTap: () => shell.goBranch(
              b.index,
              // Re-selecting the active tab returns to its root.
              initialLocation: b.index == shell.currentIndex,
            ),
          ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _Fade(
                opacity: labels,
                // Laid out at full width and clipped, so rows never reflow
                // while the sidebar resizes.
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    // Inside the 1 px glass border on either side.
                    minWidth: _expandedWidth - 2,
                    maxWidth: _expandedWidth - 2,
                    child: _Collections(location: location),
                  ),
                ),
              ),
              _Fade(
                opacity: rail,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Spacer(),
                    _NavItem(
                      label: Branch.settings.label,
                      icon: shell.currentIndex == Branch.settings.index
                          ? Branch.settings.selectedIcon
                          : Branch.settings.icon,
                      labelOpacity: 0,
                      tooltip: true,
                      selected: shell.currentIndex == Branch.settings.index,
                      onTap: () => shell.goBranch(Branch.settings.index),
                    ),
                    const SizedBox(height: NoirSpacing.sm),
                    Row(
                      children: [
                        const SizedBox(width: 23),
                        AccountAvatar(
                          size: 32,
                          onTap: () => shell.goBranch(Branch.settings.index),
                        ),
                      ],
                    ),
                    const SizedBox(height: NoirSpacing.lg),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Fades [child]; fully transparent content leaves layout, focus and
/// semantics but keeps its state (e.g. the playlist scroll position).
class _Fade extends StatelessWidget {
  const _Fade({required this.opacity, required this.child});

  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hidden = opacity == 0;
    return ExcludeFocus(
      excluding: hidden,
      child: Offstage(
        offstage: hidden,
        child: IgnorePointer(
          ignoring: opacity < 1,
          child: Opacity(opacity: opacity, child: child),
        ),
      ),
    );
  }
}

/// Favorites, playlists and YouTube collections below the main items.
class _Collections extends ConsumerWidget {
  const _Collections({required this.location});

  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final playlists = ref.watch(playlistsProvider).value ?? const [];
    final ytPlaylists = ref.watch(youTubePlaylistsProvider).value ?? const [];
    final hasLikes =
        (ref.watch(youTubeLikesProvider).value ?? const []).isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 24, 16, 8),
          child: Text('Playlists', style: t.labelMedium),
        ),
        Expanded(
          child: SmoothScroll(
            builder: (context, scroll) => ListView(
              controller: scroll,
              padding: const EdgeInsets.only(bottom: NoirSpacing.md),
              children: [
                _NavItem(
                  label: 'Favorites',
                  icon: Icons.favorite_border_rounded,
                  dense: true,
                  selected: location == '/library/favorites',
                  onTap: () => context.go('/library/favorites'),
                ),
                for (final p in playlists)
                  _NavItem(
                    label: p.name,
                    icon: Icons.music_note_outlined,
                    dense: true,
                    selected: location == '/library/playlist/${p.id}',
                    onTap: () => context.go('/library/playlist/${p.id}'),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: PillButton(
                      label: 'Create Playlist',
                      icon: Icons.add_rounded,
                      onPressed: () async {
                        final id = await createPlaylist(context, ref);
                        if (id != null && context.mounted) {
                          context.go('/library/playlist/$id');
                        }
                      },
                    ),
                  ),
                ),
                if (ytPlaylists.isNotEmpty || hasLikes) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(26, 8, 16, 8),
                    child: Text('YouTube', style: t.labelMedium),
                  ),
                  if (hasLikes)
                    _NavItem(
                      label: 'Liked videos',
                      icon: Icons.thumb_up_alt_outlined,
                      dense: true,
                      selected: location == '/library/youtube/liked',
                      onTap: () => context.go('/library/youtube/liked'),
                    ),
                  for (final p in ytPlaylists)
                    _NavItem(
                      label: p.title,
                      icon: Icons.smart_display_outlined,
                      dense: true,
                      selected: location == '/library/youtube/${p.id}',
                      onTap: () => context.go('/library/youtube/${p.id}'),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.dense = false,
    this.labelOpacity = 1,
    this.tooltip = false,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;
  final double labelOpacity;

  /// Shows the label as a tooltip (icon-only rail).
  final bool tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    final fx = NoirEffects.of(context);
    final color = selected ? c.textPrimary : c.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Tooltip(
        message: tooltip ? label : '',
        child: Semantics(
          selected: selected,
          button: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: NoirRadii.mdAll,
            hoverColor: c.hover,
            hoverDuration: fx.motion(NoirMotion.fast),
            child: AnimatedContainer(
              duration: fx.motion(NoirMotion.fast),
              curve: NoirMotion.standard,
              height: dense ? 38 : 42,
              // With the 1 px glass border and 12 px inset, 17 puts the
              // icon's center at 40: the rail's center.
              padding: const EdgeInsets.only(left: 17),
              decoration: BoxDecoration(
                color: selected ? c.selected : Colors.transparent,
                borderRadius: NoirRadii.mdAll,
              ),
              child: Row(
                children: [
                  Icon(icon, size: dense ? 18 : 20, color: color),
                  const SizedBox(width: 14),
                  Expanded(
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: 0,
                        maxWidth: _labelWidth,
                        child: Opacity(
                          opacity: labelOpacity,
                          child: AnimatedDefaultTextStyle(
                            duration: fx.motion(NoirMotion.fast),
                            style: (dense ? t.labelMedium : t.labelLarge)!
                                .copyWith(color: color),
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
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

/// Glass bottom navigation for phones.
class BottomNav extends StatelessWidget {
  const BottomNav({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    return GlassSurface(
      borderRadius: BorderRadius.zero,
      highlight: 0,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 40 + MediaQuery.textScalerOf(context).scale(24),
          child: Row(
            children: [
              for (final b in Branch.values)
                Expanded(
                  child: Semantics(
                    selected: shell.currentIndex == b.index,
                    button: true,
                    label: b.label,
                    child: InkResponse(
                      onTap: () => shell.goBranch(
                        b.index,
                        initialLocation: b.index == shell.currentIndex,
                      ),
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              shell.currentIndex == b.index
                                  ? b.selectedIcon
                                  : b.icon,
                              size: 24,
                              color: shell.currentIndex == b.index
                                  ? c.textPrimary
                                  : c.textTertiary,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              b.label,
                              style: t.labelSmall?.copyWith(
                                color: shell.currentIndex == b.index
                                    ? c.textPrimary
                                    : c.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
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
