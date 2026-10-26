import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/shell/navigation.dart';
import 'package:noir/app/shell/sidebar_hidden.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/menus.dart';
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

/// The same beside a collection's 40 px cover.
const double _coverGap = 12;
const double _coverLabelWidth =
    _expandedWidth - 2 - 24 - 7 - 40 - _coverGap - 14;

/// Desktop sidebar from the reference design. Collapses into an icon rail
/// by animating its width: icons and playlist covers stay put while labels
/// and section headers fade, so the change reads as one motion instead of a
/// swap. Settings lives behind the top bar's avatar (and Ctrl+,).
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
          child: _Collections(location: location, labels: labels, rail: t == 0),
        ),
      ],
    );
  }
}

/// Favorites, playlists and YouTube collections below the main items, each
/// with its cover. In the rail only the covers remain (names as tooltips);
/// headers and the create button fold away.
class _Collections extends ConsumerWidget {
  const _Collections({
    required this.location,
    required this.labels,
    required this.rail,
  });

  final String location;

  /// Opacity of labels and headers: 0 in the rail, 1 at full width.
  final double labels;
  final bool rail;

  /// Cover size; with [_NavItem]'s insets its center sits on the rail's.
  static const double _cover = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final playlists = ref.watch(playlistsProvider).value ?? const [];
    final ytPlaylists = ref.watch(youTubePlaylistsProvider).value ?? const [];
    final likes = ref.watch(youTubeLikesProvider).value ?? const [];
    final hidden = ref.watch(sidebarHiddenProvider);

    Widget item({
      required String label,
      required Widget cover,
      required String route,
    }) {
      if (hidden.contains(route)) return const SizedBox.shrink();
      return _NavItem(
        key: ValueKey(route),
        label: label,
        leading: cover,
        labelOpacity: labels,
        tooltip: rail,
        selected: location == route,
        onTap: () => context.go(route),
        onContextMenu: (position) async {
          final action = await showNoirMenu<String>(
            context,
            anchor: position & Size.zero,
            items: const [
              NoirMenuItem(
                'hide',
                'Hide from sidebar',
                icon: Icons.visibility_off_outlined,
              ),
            ],
          );
          if (action == 'hide') {
            ref
                .read(sidebarHiddenProvider.notifier)
                .setHidden(route, hidden: true);
            if (context.mounted) {
              showToast(
                context,
                '"$label" is still in Library. Settings → Library brings it '
                'back.',
              );
            }
          }
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Fold(
          t: labels,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 24, 16, 8),
            child: Text('Playlists', style: t.labelMedium),
          ),
        ),
        Expanded(
          child: SmoothScroll(
            builder: (context, scroll) => ListView(
              controller: scroll,
              padding: const EdgeInsets.only(
                top: NoirSpacing.sm,
                bottom: NoirSpacing.md,
              ),
              children: [
                item(
                  label: 'Favorites',
                  route: '/library/favorites',
                  cover: const Artwork(
                    path: null,
                    size: _cover,
                    icon: Icons.favorite_rounded,
                  ),
                ),
                for (final p in playlists)
                  item(
                    label: p.name,
                    route: '/library/playlist/${p.id}',
                    cover: ArtworkCollage(paths: p.artworkPaths, size: _cover),
                  ),
                _Fold(
                  t: labels,
                  child: Padding(
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
                ),
                if (ytPlaylists.isNotEmpty || likes.isNotEmpty) ...[
                  _Fold(
                    t: labels,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(26, 8, 16, 8),
                      child: Text('YouTube', style: t.labelMedium),
                    ),
                  ),
                  if (likes.isNotEmpty)
                    item(
                      label: ref.watch(youTubeLikesTitleProvider),
                      route: '/library/youtube/liked',
                      cover: Artwork(
                        path: likes.first.artworkUrl,
                        size: _cover,
                        icon: Icons.thumb_up_alt_outlined,
                      ),
                    ),
                  for (final p in ytPlaylists)
                    item(
                      label: p.title,
                      route: '/library/youtube/${p.id}',
                      cover: Artwork(path: p.thumbnailUrl, size: _cover),
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

/// Folds [child] away as [t] goes to 0: it fades and its height shrinks.
/// Laid out at full sidebar width, so it never reflows; folded away it
/// leaves focus and semantics.
class _Fold extends StatelessWidget {
  const _Fold({required this.t, required this.child});

  final double t;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hidden = t == 0;
    return ExcludeFocus(
      excluding: hidden,
      child: ExcludeSemantics(
        excluding: hidden,
        child: IgnorePointer(
          ignoring: t < 1,
          child: ClipRect(
            child: Align(
              alignment: Alignment.topLeft,
              heightFactor: t,
              child: UnconstrainedBox(
                alignment: Alignment.topLeft,
                constrainedAxis: Axis.vertical,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  // Inside the 1 px glass border on either side.
                  width: _expandedWidth - 2,
                  child: Opacity(opacity: t, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.leading,
    this.labelOpacity = 1,
    this.tooltip = false,
    this.onContextMenu,
    super.key,
  }) : assert((icon == null) != (leading == null), 'An icon or a cover');

  final String label;
  final IconData? icon;

  /// A 40 px cover in place of the icon (collections).
  final Widget? leading;
  final bool selected;
  final VoidCallback onTap;
  final double labelOpacity;

  /// Shows the label as a tooltip (icon-only rail).
  final bool tooltip;

  /// Right click or long press, at the pointer's global position.
  final ValueChanged<Offset>? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    final fx = NoirEffects.of(context);
    final color = selected ? c.textPrimary : c.textSecondary;
    final cover = leading;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Tooltip(
        message: tooltip ? label : '',
        child: Semantics(
          selected: selected,
          button: true,
          child: InkWell(
            onTap: onTap,
            onSecondaryTapUp: onContextMenu == null
                ? null
                : (d) => onContextMenu!(d.globalPosition),
            onLongPress: onContextMenu == null
                ? null
                : () {
                    final box = context.findRenderObject()! as RenderBox;
                    onContextMenu!(
                      box.localToGlobal(box.size.center(Offset.zero)),
                    );
                  },
            borderRadius: NoirRadii.mdAll,
            hoverColor: c.hover,
            hoverDuration: fx.motion(NoirMotion.fast),
            child: AnimatedContainer(
              duration: fx.motion(NoirMotion.fast),
              curve: NoirMotion.standard,
              height: cover == null ? 42 : 48,
              // With the 1 px glass border and 12 px inset, 17 puts the
              // icon's center at 40: the rail's center. Same for the
              // 40 px cover at 7.
              padding: EdgeInsets.only(left: cover == null ? 17 : 7),
              decoration: BoxDecoration(
                color: selected ? c.selected : Colors.transparent,
                borderRadius: NoirRadii.mdAll,
              ),
              child: Row(
                children: [
                  ?cover,
                  if (cover == null) ...[
                    Icon(icon, size: 20, color: color),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: 0,
                        // Beside a cover the gap is clipped too: the rail
                        // has no room for it.
                        maxWidth: cover == null
                            ? _labelWidth
                            : _coverGap + _coverLabelWidth,
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: cover == null ? 0 : _coverGap,
                          ),
                          child: Opacity(
                            opacity: labelOpacity,
                            child: AnimatedDefaultTextStyle(
                              duration: fx.motion(NoirMotion.fast),
                              style:
                                  (cover == null
                                          ? t.labelLarge
                                          : t.labelMedium)!
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
