import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
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
/// - expanded (wide desktop): sidebar (collapsible to a rail) + content +
///   optional queue panel;
/// - medium: icon rail + content;
/// - compact (phones): content + mini-player + bottom navigation.
///
/// Both desktop classes share one [Sidebar] whose width animates between
/// them, and float the [PlayerIsland] over the bottom of the content.
class AdaptiveShell extends ConsumerWidget {
  const AdaptiveShell({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windowClass = WindowClass.of(MediaQuery.sizeOf(context).width);
    final wide = windowClass == WindowClass.expanded;
    final collapsed = ref.watch(
      settingsProvider.select((s) => s.sidebarCollapsed),
    );
    final queueOpen = ref.watch(queuePanelOpenProvider);
    final artwork = ref.watch(
      playbackProvider.select((s) => s.current?.track.artwork),
    );

    final content = windowClass == WindowClass.compact
        ? _CompactLayout(shell: shell)
        : Row(
            children: [
              Sidebar(
                shell: shell,
                collapsed: collapsed || !wide,
                canToggle: wide,
              ),
              Expanded(child: _DesktopContent(shell: shell)),
              _SidePanel(open: queueOpen && wide),
            ],
          );

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

/// Content with the player island floating over its bottom edge. Pages
/// scroll underneath the glass; the island's height is handed down as
/// bottom [MediaQuery] padding so last rows and scrollbars stay clear of it.
class _DesktopContent extends ConsumerStatefulWidget {
  const _DesktopContent({required this.shell});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<_DesktopContent> createState() => _DesktopContentState();
}

class _DesktopContentState extends ConsumerState<_DesktopContent> {
  double _islandHeight = 0;

  @override
  Widget build(BuildContext context) {
    final playing = ref.watch(
      playbackProvider.select((s) => s.current != null),
    );
    final mq = MediaQuery.of(context);
    final inset = playing ? _islandHeight : 0.0;
    return Stack(
      children: [
        Positioned.fill(
          child: MediaQuery(
            data: mq.copyWith(
              padding: mq.padding.copyWith(
                bottom: math.max(mq.padding.bottom, inset),
              ),
            ),
            child: _Content(shell: widget.shell),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _HeightReporter(
            onHeight: (h) {
              if (mounted && h != _islandHeight) {
                setState(() => _islandHeight = h);
              }
            },
            child: const PlayerIsland(),
          ),
        ),
      ],
    );
  }
}

/// Reports its child's height after layout, whenever it changes.
class _HeightReporter extends SingleChildRenderObjectWidget {
  const _HeightReporter({required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeightReporter(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderHeightReporter renderObject,
  ) => renderObject.onHeight = onHeight;
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h == _reported) return;
    _reported = h;
    SchedulerBinding.instance.addPostFrameCallback((_) => onHeight(h));
  }
}

/// Right-hand queue panel. Laid out at full width and revealed by
/// animating its clip, so rows never reflow while it opens.
class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.open});

  static const double _width = 360;

  final bool open;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: open ? 1 : 0),
      duration: NoirEffects.of(context).motion(NoirMotion.layout),
      curve: NoirMotion.emphasized,
      child: const GlassSurface(
        borderRadius: BorderRadius.zero,
        highlight: 0.4,
        child: QueuePanel(),
      ),
      builder: (context, t, panel) => t == 0
          ? const SizedBox.shrink()
          : SizedBox(
              width: _width * t,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: _width,
                  maxWidth: _width,
                  child: panel,
                ),
              ),
            ),
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
        // The bottom inset belongs to the navigation bar below.
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: SafeArea(bottom: false, child: shell),
          ),
        ),
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
          hoverDuration: NoirEffects.of(context).motion(NoirMotion.fast),
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
