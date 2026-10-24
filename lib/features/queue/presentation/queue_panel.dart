import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/youtube_video_layer.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/shared/widgets/track_row.dart';

/// Whether the desktop right-hand queue panel is open.
final queuePanelOpenProvider = NotifierProvider<_PanelOpen, bool>(
  _PanelOpen.new,
);

class _PanelOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void close() => state = false;
}

/// Wide windows toggle the side panel; everything else opens the screen.
void openQueue(BuildContext context, WidgetRef ref) {
  final wide =
      WindowClass.of(MediaQuery.sizeOf(context).width) == WindowClass.expanded;
  if (wide) {
    ref.read(queuePanelOpenProvider.notifier).toggle();
  } else {
    unawaited(context.push('/queue'));
  }
}

/// Whether the queue sheet ([showQueueSheet]) is open. Now Playing hands
/// its video slot to the sheet meanwhile, so the YouTube player never sits
/// on top of the sheet.
final queueSheetOpenProvider = NotifierProvider<_SheetOpen, bool>(
  _SheetOpen.new,
);

class _SheetOpen extends Notifier<bool> {
  @override
  bool build() => false;

  // A method reads better than a setter at the call site.
  // ignore: use_setters_to_change_properties
  void set({required bool open}) => state = open;
}

/// Slides the queue in from the right edge as a route on the root
/// navigator, so `maybePop` (Esc, mouse Back) closes it before anything
/// underneath. Tapping outside closes it too.
Future<void> showQueueSheet(BuildContext context, WidgetRef ref) async {
  final fx = NoirEffects.of(context);
  final open = ref.read(queueSheetOpenProvider.notifier)..set(open: true);
  try {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close queue',
      barrierColor: Colors.black.withValues(alpha: 0.3),
      transitionDuration: fx.motion(NoirMotion.slow),
      pageBuilder: (context, _, _) => const _QueueSheet(),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: NoirMotion.emphasized,
          reverseCurve: Curves.easeInCubic,
        );
        final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
        return AnimatedBuilder(
          animation: fade,
          builder: (context, child) =>
              GlassFade(opacity: fade.value, child: child!),
          child: SlideTransition(
            position: Tween(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  } finally {
    open.set(open: false);
  }
}

class _QueueSheet extends ConsumerWidget {
  const _QueueSheet();

  static const maxWidth = 400.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final width = min(MediaQuery.sizeOf(context).width, maxWidth);
    void close() => Navigator.of(context).maybePop();
    final showVideo =
        ref.watch(playbackProvider.select((s) => s.showsVideoPlayer)) &&
        !ref.watch(settingsProvider.select((s) => s.hideYouTubePlayer)) &&
        ref.watch(youTubeEngineProvider) != null;

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: Material(
            type: MaterialType.transparency,
            child: GlassSurface(
              borderRadius: width < maxWidth
                  ? BorderRadius.zero
                  : const BorderRadius.horizontal(
                      left: Radius.circular(NoirRadii.xl),
                    ),
              shadow: 1,
              highlight: 0.4,
              fillOpacity: 2.5,
              floating: true,
              // Too large for the lens shader: saturate in the blur.
              refract: false,
              child: SafeArea(
                left: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    WindowDragArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('Queue', style: t.titleMedium),
                            ),
                            NoirIconButton(
                              icon: Icons.close_rounded,
                              tooltip: 'Close queue (Esc)',
                              onPressed: close,
                            ),
                            if (usesCustomWindowChrome) ...[
                              const SizedBox(width: NoirSpacing.sm),
                              const WindowControls(),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (showVideo)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                        child: VideoSlot(
                          size: Size(
                            (width - 32).clamp(
                              200.0,
                              YouTubeVideoLayer.miniSize.width,
                            ),
                            YouTubeVideoLayer.miniSize.height,
                          ),
                        ),
                      ),
                    const Expanded(
                      child: QueueList(
                        padding: EdgeInsets.symmetric(
                          horizontal: NoirSpacing.md,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// NOIR's local queue: the current item, then reorderable upcoming items.
class QueueList extends ConsumerWidget {
  const QueueList({this.padding = EdgeInsets.zero, super.key});

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      SmoothScroll(builder: (context, scroll) => _list(context, ref, scroll));

  Widget _list(BuildContext context, WidgetRef ref, ScrollController scroll) {
    final s = ref.watch(playbackProvider);
    final ctrl = ref.read(playbackProvider.notifier);
    final t = Theme.of(context).textTheme;
    final current = s.current;
    if (current == null) {
      return const EmptyState(
        icon: Icons.queue_music_rounded,
        title: 'Nothing queued',
        message: 'Play a song or use "Add to queue" from any track menu.',
        compact: true,
      );
    }
    final start = s.index! + 1;
    final upcoming = s.upcoming;

    return CustomScrollView(
      controller: scroll,
      slivers: [
        SliverPadding(
          padding: padding.copyWith(bottom: 0),
          sliver: SliverList.list(
            children: [
              Text('Now playing', style: t.labelMedium),
              const SizedBox(height: NoirSpacing.sm),
              TrackRow(
                key: ValueKey('q-${current.uid}'),
                track: current.track,
                onPlay: () => unawaited(ctrl.togglePlayPause()),
              ),
              const SizedBox(height: NoirSpacing.lg),
              Row(
                children: [
                  Expanded(child: Text('Up next', style: t.labelMedium)),
                  if (upcoming.isNotEmpty &&
                      s.capabilities.supportsQueueMutation)
                    TextButton(
                      onPressed: () async {
                        final ok = await confirm(
                          context,
                          title: 'Clear queue?',
                          message:
                              'Removes the ${upcoming.length} upcoming songs. '
                              'Your playlists are not affected.',
                          confirmLabel: 'Clear',
                          destructive: true,
                        );
                        if (ok) ctrl.clearUpcoming();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: context.noir.textSecondary,
                        textStyle: t.labelMedium,
                      ),
                      child: const Text('Clear'),
                    ),
                ],
              ),
              if (upcoming.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: NoirSpacing.lg),
                  child: Text(
                    'The queue ends after this song.',
                    style: t.bodySmall,
                  ),
                ),
            ],
          ),
        ),
        SliverPadding(
          padding: padding.copyWith(top: 0),
          sliver: SliverReorderableList(
            itemCount: upcoming.length,
            onReorderItem: (from, to) => ctrl.move(start + from, start + to),
            itemBuilder: (context, i) {
              final item = upcoming[i];
              return Material(
                key: ValueKey('q-${item.uid}'),
                type: MaterialType.transparency,
                child: TrackRow(
                  track: item.track,
                  onPlay: () => unawaited(ctrl.jumpTo(start + i)),
                  onRemove: () => ctrl.removeAt(start + i),
                  removeLabel: 'Remove from queue',
                  trailing: s.capabilities.supportsQueueMutation
                      ? ReorderableDragStartListener(
                          index: i,
                          child: const MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: Tooltip(
                              message: 'Drag to reorder',
                              child: Icon(
                                Icons.drag_indicator_rounded,
                                size: 18,
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
              );
            },
          ),
        ),
        SliverPadding(
          padding: padding.copyWith(top: NoirSpacing.lg),
          sliver: SliverToBoxAdapter(
            child: Text(
              "This is NOIR's own queue. Changing it never edits your "
              'playlists.',
              style: t.labelSmall,
            ),
          ),
        ),
      ],
    );
  }
}

/// Right-hand panel for wide desktop windows.
class QueuePanel extends ConsumerWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
          child: Row(
            children: [
              Expanded(child: Text('Queue', style: t.titleMedium)),
              NoirIconButton(
                icon: Icons.close_rounded,
                tooltip: 'Close queue',
                onPressed: ref.read(queuePanelOpenProvider.notifier).close,
              ),
            ],
          ),
        ),
        const Expanded(
          child: QueueList(
            padding: EdgeInsets.symmetric(horizontal: NoirSpacing.md),
          ),
        ),
      ],
    );
  }
}

class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: const Text('Queue'),
      ),
      body: const SafeArea(
        top: false,
        child: QueueList(
          padding: EdgeInsets.symmetric(horizontal: NoirSpacing.lg),
        ),
      ),
    );
  }
}
