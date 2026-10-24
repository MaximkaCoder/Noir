import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/shell/navigation.dart';
import 'package:noir/app/shell/sidebar.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/noir_backdrop.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/mini_players.dart';
import 'package:noir/features/queue/presentation/queue_panel.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';

/// Focus node of the search field, so shortcuts can jump into it.
final searchFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'search');
  ref.onDispose(node.dispose);
  return node;
});

/// Responsive frame around the four branch navigators:
/// - expanded (wide desktop): sidebar + content + optional queue panel;
/// - medium: icon rail + content + bottom player bar;
/// - compact (phones): content + mini-player + bottom navigation.
class AdaptiveShell extends ConsumerWidget {
  const AdaptiveShell({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final collapsed = ref.watch(
      settingsProvider.select((s) => s.sidebarCollapsed),
    );
    final queueOpen = ref.watch(queuePanelOpenProvider);
    final artwork = ref.watch(
      playbackProvider.select((s) => s.current?.track.artworkPath),
    );
    final fx = NoirEffects.of(context);

    var windowClass = WindowClass.of(width);
    if (windowClass == WindowClass.expanded && collapsed) {
      windowClass = WindowClass.medium;
    }
    final showQueue =
        queueOpen && WindowClass.of(width) == WindowClass.expanded;

    final content = switch (windowClass) {
      WindowClass.compact => _CompactLayout(shell: shell),
      WindowClass.medium => Row(
        children: [
          NavRail(shell: shell),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _Content(shell: shell)),
                const PlayerBar(),
              ],
            ),
          ),
        ],
      ),
      WindowClass.expanded => Row(
        children: [
          Sidebar(shell: shell),
          Expanded(child: _Content(shell: shell)),
          AnimatedSize(
            duration: fx.motion(NoirMotion.medium),
            curve: NoirMotion.standard,
            child: showQueue
                ? const SizedBox(
                    width: 360,
                    child: GlassSurface(
                      borderRadius: BorderRadius.zero,
                      highlight: 0.4,
                      child: QueuePanel(),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    };

    return _ShellShortcuts(
      shell: shell,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: BackdropGroup(
          child: Stack(
            fit: StackFit.expand,
            children: [
              NoirBackdrop(artworkPath: artwork),
              content,
            ],
          ),
        ),
      ),
    );
  }
}

/// Branch content with the desktop top bar above it.
class _Content extends StatelessWidget {
  const _Content({required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TopBar(shell: shell),
        Expanded(child: shell),
      ],
    );
  }
}

class _CompactLayout extends StatelessWidget {
  const _CompactLayout({required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Narrow desktop windows still need window controls and a drag area.
        if (usesCustomWindowChrome)
          const WindowDragArea(
            child: SizedBox(
              height: 40,
              child: Row(
                children: [Spacer(), WindowControls(), SizedBox(width: 14)],
              ),
            ),
          ),
        Expanded(child: SafeArea(bottom: false, child: shell)),
        const MobileMiniPlayer(),
        BottomNav(shell: shell),
      ],
    );
  }
}

/// Desktop keyboard shortcuts. Ignored while typing in a text field because
/// the field handles those keys first.
class _ShellShortcuts extends ConsumerWidget {
  const _ShellShortcuts({required this.shell, required this.child});

  final StatefulNavigationShell shell;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.read(playbackProvider.notifier);
    void search() {
      shell.goBranch(Branch.search.index);
      ref.read(searchFocusProvider).requestFocus();
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () =>
            unawaited(playback.togglePlayPause()),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): search,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): search,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): search,
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          control: true,
        ): () =>
            unawaited(playback.next()),
        const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          control: true,
        ): () =>
            unawaited(playback.previous()),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            shell.goBranch(Branch.settings.index),
        const SingleActivator(LogicalKeyboardKey.keyP, control: true): () =>
            openNowPlaying(context),
      },
      child: FocusScope(autofocus: true, child: child),
    );
  }
}

/// Right-aligned search pill and account avatar; doubles as window drag area.
class TopBar extends ConsumerWidget {
  const TopBar({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onSearch = shell.currentIndex == Branch.search.index;
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    return WindowDragArea(
      child: SizedBox(
        height: 60,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 20, 4),
          child: Row(
            children: [
              const Spacer(),
              if (!onSearch)
                Semantics(
                  button: true,
                  label: 'Search (Ctrl+K)',
                  child: GestureDetector(
                    onTap: () {
                      shell.goBranch(Branch.search.index);
                      ref.read(searchFocusProvider).requestFocus();
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.text,
                      child: GlassSurface(
                        interactive: true,
                        borderRadius: NoirRadii.pillAll,
                        blur: 0,
                        child: SizedBox(
                          width: 280,
                          height: 38,
                          child: Row(
                            children: [
                              const SizedBox(width: 14),
                              Icon(
                                Icons.search_rounded,
                                size: 18,
                                color: c.textSecondary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Search music, artists, albums…',
                                  style: t.bodySmall,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text('Ctrl K', style: t.labelSmall),
                              const SizedBox(width: 14),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: NoirSpacing.md),
              AccountAvatar(onTap: () => shell.goBranch(Branch.settings.index)),
              if (usesCustomWindowChrome) ...[
                const SizedBox(width: NoirSpacing.lg),
                const WindowControls(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Placeholder avatar until an account is connected (Phase 5).
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({required this.onTap, this.size = 34, super.key});

  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    return Tooltip(
      message: 'Settings & account',
      child: Semantics(
        button: true,
        label: 'Settings and account',
        child: InkResponse(
          onTap: onTap,
          radius: size / 2 + 4,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.surfaceElevated,
              border: Border.all(color: c.glassBorder),
            ),
            child: Icon(
              Icons.person_outline_rounded,
              size: size * 0.55,
              color: c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
