import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/shelf_row.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/discover/application/for_you.dart';
import 'package:noir/features/discover/presentation/load_more.dart';
import 'package:noir/features/discover/presentation/ytm_items.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/widgets/media_tiles.dart';

/// Reloads the Discover feed when it is stale (older than
/// [HomeFeedController.maxAge]) or always with [force]. A failure keeps the
/// shown feed; only [context] (a user action) gets a toast.
Future<void> refreshDiscover(
  WidgetRef ref, {
  bool force = false,
  BuildContext? context,
}) async {
  if (ref.read(homeFeedProvider).isLoading) return;
  try {
    await ref.read(homeFeedProvider.notifier).refresh(force: force);
  } on InnerTubeException catch (e) {
    if (context != null && context.mounted) showToast(context, e.message);
  }
}

/// Home's "Discover" part: YouTube Music's anonymous home feed (mood chips,
/// then shelves), loading further shelves as the page nears its end.
/// A sliver; it hides itself when the feed is empty.
class DiscoverSection extends ConsumerStatefulWidget {
  const DiscoverSection({required this.tileWidth, super.key});

  final double tileWidth;

  @override
  ConsumerState<DiscoverSection> createState() => _DiscoverSectionState();
}

class _DiscoverSectionState extends ConsumerState<DiscoverSection> {
  late final AppLifecycleListener _lifecycle;
  GoRouter? _router;
  bool _atHome = true;

  /// Chip the user just picked while its feed loads (null: plain feed).
  ({String? params})? _pendingChip;

  /// Shelves that already faded in.
  final _revealed = <String>{};

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => refreshDiscover(ref));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (router == _router) return;
    _router?.routerDelegate.removeListener(_onRoute);
    _router = router?..routerDelegate.addListener(_onRoute);
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_onRoute);
    _lifecycle.dispose();
    super.dispose();
  }

  /// Coming back to Home refreshes a stale feed.
  void _onRoute() {
    final atHome = _router?.routerDelegate.currentConfiguration.uri.path == '/';
    if (atHome && !_atHome) unawaited(refreshDiscover(ref));
    _atHome = atHome;
  }

  Future<void> _selectChip(String? params) async {
    setState(() => _pendingChip = (params: params));
    try {
      await ref.read(homeFeedProvider.notifier).selectChip(params);
    } on InnerTubeException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _pendingChip = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(homeFeedProvider);
    final value = feed.value;
    if (value != null &&
        value.shelves.isEmpty &&
        value.chips.isEmpty &&
        value.chipParams == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final tile = widget.tileWidth;
    final header = SliverToBoxAdapter(
      child: _Header(
        onRefresh: value == null
            ? null
            : () => refreshDiscover(ref, force: true, context: context),
      ),
    );

    if (value == null) {
      return SliverMainAxisGroup(
        slivers: [
          header,
          SliverToBoxAdapter(
            child: feed.hasError && !feed.isLoading
                ? ErrorState(
                    compact: true,
                    title: "Discover couldn't load",
                    message: switch (feed.error) {
                      InnerTubeException(:final message) => message,
                      _ => 'YouTube Music is unavailable right now.',
                    },
                    actionLabel: 'Try again',
                    onAction: () => ref.invalidate(homeFeedProvider),
                  )
                : Column(
                    children: [
                      _ShelfSkeleton(tile: tile),
                      _ShelfSkeleton(tile: tile),
                    ],
                  ),
          ),
        ],
      );
    }

    final selected = _pendingChip == null
        ? value.chipParams
        : _pendingChip!.params;
    final fx = NoirEffects.of(context);
    final shelves = value.shelves;
    return SliverMainAxisGroup(
      slivers: [
        header,
        if (value.chips.isNotEmpty)
          SliverToBoxAdapter(
            child: _ChipRow(
              chips: value.chips,
              selected: selected,
              onSelected: (params) => unawaited(_selectChip(params)),
            ),
          ),
        if (shelves.isEmpty)
          const SliverToBoxAdapter(
            child: EmptyState(
              compact: true,
              icon: Icons.explore_outlined,
              title: 'Nothing here right now',
              message: 'Try another mood, or come back later.',
            ),
          ),
        SliverOpacity(
          // Dimmed while a newly picked mood loads.
          opacity: _pendingChip == null ? 1 : 0.5,
          sliver: SliverList.builder(
            itemCount: shelves.length + (value.hasMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == shelves.length) {
                return LoadMoreTrigger(
                  key: ValueKey('more-${shelves.length}'),
                  onLoadMore: ref.read(homeFeedProvider.notifier).loadMore,
                  placeholder: _ShelfSkeleton(tile: tile),
                );
              }
              final key = 'shelf-$i-${shelves[i].title}';
              final row = _ShelfRow(shelf: shelves[i], tile: tile);
              // Fade in on arrival only, not when scrolled back into view.
              return _revealed.add(key)
                  ? _FadeIn(
                      key: ValueKey(key),
                      duration: fx.motion(NoirMotion.slow),
                      child: row,
                    )
                  : KeyedSubtree(key: ValueKey(key), child: row);
            },
          ),
        ),
      ],
    );
  }
}

/// Home's "For you": recommendations seeded by the user's own plays,
/// likes and playlists ([forYouProvider]). A sliver; hidden until there is
/// something to show (no taste yet, or offline).
class ForYouSection extends ConsumerStatefulWidget {
  const ForYouSection({required this.tileWidth, super.key});

  final double tileWidth;

  @override
  ConsumerState<ForYouSection> createState() => _ForYouSectionState();
}

class _ForYouSectionState extends ConsumerState<ForYouSection> {
  late final AppLifecycleListener _lifecycle;
  bool _reshuffling = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(ref.read(forYouProvider.notifier).refresh()),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _reshuffle() async {
    setState(() => _reshuffling = true);
    try {
      await ref.read(forYouProvider.notifier).refresh(force: true);
    } finally {
      if (mounted) setState(() => _reshuffling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shelves = ref.watch(forYouProvider).value?.shelves ?? const [];
    if (shelves.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: _Header(
            title: 'For you',
            subtitle: 'From what you play and like',
            refreshTooltip: 'New picks',
            onRefresh: _reshuffling ? null : () => unawaited(_reshuffle()),
          ),
        ),
        SliverOpacity(
          opacity: _reshuffling ? 0.5 : 1,
          sliver: SliverList.list(
            children: [
              for (final (i, shelf) in shelves.indexed)
                _ShelfRow(
                  key: ValueKey('for-you-$i-${shelf.title}'),
                  shelf: shelf,
                  tile: widget.tileWidth,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.onRefresh,
    this.title = 'Discover',
    this.subtitle = 'From YouTube Music',
    this.refreshTooltip = 'Refresh Discover',
  });

  final VoidCallback? onRefresh;
  final String title;
  final String subtitle;
  final String refreshTooltip;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      // The chips' [ShelfRow.lift] completes the usual gap.
      padding: const EdgeInsets.only(
        top: 44,
        bottom: NoirSpacing.md - ShelfRow.lift,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: t.titleLarge),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: t.labelSmall?.copyWith(
                    color: context.noir.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (onRefresh != null)
            NoirIconButton(
              icon: Icons.refresh_rounded,
              tooltip: refreshTooltip,
              size: 18,
              onPressed: onRefresh,
            ),
        ],
      ),
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.chips,
    required this.selected,
    required this.onSelected,
  });

  final List<YtmChip> chips;
  final String? selected;

  /// Null returns to the plain feed.
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return ShelfRow(
      height: MediaQuery.textScalerOf(context).scale(22) + 22,
      spacing: NoirSpacing.xs,
      arrowSize: 32,
      children: [
        for (final chip in chips)
          Center(
            child: PillChip(
              key: ValueKey(chip.params),
              label: chip.title,
              selected: chip.params == selected,
              // Picking the selected mood again goes back to everything.
              onSelected: () =>
                  onSelected(chip.params == selected ? null : chip.params),
            ),
          ),
      ],
    );
  }
}

class _ShelfRow extends StatelessWidget {
  const _ShelfRow({required this.shelf, required this.tile, super.key});

  final YtmShelf shelf;
  final double tile;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: TileRow(
        tileWidth: tile,
        title: shelf.title,
        eyebrow: shelf.strapline,
        children: [
          for (final (i, item) in shelf.items.indexed)
            YtmTile(
              key: ValueKey('$i-${item.title}'),
              item: item,
              siblings: shelf.items,
              width: tile,
            ),
        ],
      ),
    );
  }
}

/// Static placeholder of a shelf (no shimmer: constant motion is avoided).
class _ShelfSkeleton extends StatelessWidget {
  const _ShelfSkeleton({required this.tile});

  final double tile;

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
        child: Padding(
          padding: const EdgeInsets.only(top: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(160, 16),
              const SizedBox(height: NoirSpacing.lg),
              SizedBox(
                height: tile + 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: 8,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: NoirSpacing.lg),
                  itemBuilder: (_, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      bar(tile, tile),
                      const SizedBox(height: NoirSpacing.sm + 2),
                      bar(tile * 0.7, 12),
                      const SizedBox(height: NoirSpacing.xs),
                      bar(tile * 0.45, 10),
                    ],
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

/// Fades its child in once, when first built.
class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.duration, required this.child, super.key});

  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (duration == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: NoirMotion.standard,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * NoirMotion.shift),
          child: child,
        ),
      ),
    );
  }
}
