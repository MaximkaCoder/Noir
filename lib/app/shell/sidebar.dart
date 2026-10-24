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
import 'package:noir/features/playback/presentation/mini_players.dart';
import 'package:noir/features/playlists/application/playlist_providers.dart';
import 'package:noir/features/playlists/presentation/add_to_playlist.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';

const List<Branch> _primaryBranches = [
  Branch.home,
  Branch.search,
  Branch.library,
];

/// Top strip of the sidebar/rail: window controls and drag area.
class _WindowHeader extends StatelessWidget {
  const _WindowHeader({this.trailing});

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return WindowDragArea(
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            const SizedBox(width: 14),
            if (reservesWindowControlsSpace) const SizedBox(width: 60),
            const Spacer(),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Full desktop sidebar from the reference design.
class Sidebar extends ConsumerWidget {
  const Sidebar({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final playlists = ref.watch(playlistsProvider).value ?? const [];
    final ytPlaylists = ref.watch(youTubePlaylistsProvider).value ?? const [];
    final hasLikes =
        (ref.watch(youTubeLikesProvider).value ?? const []).isNotEmpty;
    final location = GoRouterState.of(context).uri.path;

    return SizedBox(
      width: 248,
      child: GlassSurface(
        borderRadius: BorderRadius.zero,
        highlight: 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _WindowHeader(
              trailing: NoirIconButton(
                icon: Icons.keyboard_double_arrow_left_rounded,
                tooltip: 'Collapse sidebar',
                size: 18,
                onPressed: () => ref
                    .read(settingsProvider.notifier)
                    .update((s) => s.copyWith(sidebarCollapsed: true)),
              ),
            ),
            const SizedBox(height: NoirSpacing.sm),
            for (final b in _primaryBranches)
              _NavItem(
                label: b.label,
                icon: shell.currentIndex == b.index ? b.selectedIcon : b.icon,
                selected:
                    shell.currentIndex == b.index &&
                    !location.startsWith('/library/playlist') &&
                    !location.startsWith('/library/youtube') &&
                    location != '/library/favorites',
                onTap: () => _goBranch(b),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 24, 16, 8),
              child: Text('Playlists', style: t.labelMedium),
            ),
            Expanded(
              child: SmoothScroll(
                builder: (context, scroll) => ListView(
                  controller: scroll,
                  padding: EdgeInsets.zero,
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
            const Padding(
              padding: EdgeInsets.all(12),
              child: SidebarPlayerCard(),
            ),
          ],
        ),
      ),
    );
  }

  void _goBranch(Branch b) => shell.goBranch(
    b.index,
    // Re-selecting the active tab returns to its root.
    initialLocation: b.index == shell.currentIndex,
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.dense = false,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: NoirRadii.mdAll,
          hoverColor: c.hover,
          child: AnimatedContainer(
            duration: NoirEffects.of(context).motion(NoirMotion.fast),
            height: dense ? 38 : 42,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: selected ? c.selected : Colors.transparent,
              borderRadius: NoirRadii.mdAll,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: dense ? 18 : 20,
                  color: selected ? c.textPrimary : c.textSecondary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (dense ? t.labelMedium : t.labelLarge)?.copyWith(
                      color: selected ? c.textPrimary : c.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Icon-only rail for medium windows (and a collapsed sidebar).
class NavRail extends ConsumerWidget {
  const NavRail({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canExpand =
        WindowClass.of(MediaQuery.sizeOf(context).width) ==
        WindowClass.expanded;
    return SizedBox(
      width: 80,
      child: GlassSurface(
        borderRadius: BorderRadius.zero,
        highlight: 0.5,
        child: Column(
          children: [
            WindowDragArea(
              child: SizedBox(height: reservesWindowControlsSpace ? 48 : 16),
            ),
            if (canExpand)
              NoirIconButton(
                icon: Icons.keyboard_double_arrow_right_rounded,
                tooltip: 'Expand sidebar',
                size: 18,
                onPressed: () => ref
                    .read(settingsProvider.notifier)
                    .update((s) => s.copyWith(sidebarCollapsed: false)),
              ),
            const SizedBox(height: NoirSpacing.sm),
            for (final b in _primaryBranches)
              _RailItem(
                branch: b,
                selected: shell.currentIndex == b.index,
                onTap: () => shell.goBranch(
                  b.index,
                  initialLocation: b.index == shell.currentIndex,
                ),
              ),
            const Spacer(),
            _RailItem(
              branch: Branch.settings,
              selected: shell.currentIndex == Branch.settings.index,
              onTap: () => shell.goBranch(Branch.settings.index),
            ),
            const SizedBox(height: NoirSpacing.sm),
            AccountAvatar(
              size: 32,
              onTap: () => shell.goBranch(Branch.settings.index),
            ),
            const SizedBox(height: NoirSpacing.lg),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.branch,
    required this.selected,
    required this.onTap,
  });

  final Branch branch;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Tooltip(
        message: branch.label,
        child: Semantics(
          label: branch.label,
          selected: selected,
          button: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: NoirRadii.mdAll,
            child: AnimatedContainer(
              duration: NoirEffects.of(context).motion(NoirMotion.fast),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: selected ? c.selected : Colors.transparent,
                borderRadius: NoirRadii.mdAll,
                border: Border.all(
                  color: selected ? c.glassBorder : Colors.transparent,
                ),
              ),
              child: Icon(
                selected ? branch.selectedIcon : branch.icon,
                size: 20,
                color: selected ? c.textPrimary : c.textSecondary,
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
