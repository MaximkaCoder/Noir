import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/noir_backdrop.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/lyrics/application/lyrics_providers.dart';
import 'package:noir/features/lyrics/presentation/lyrics_view.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/playback_controls.dart';
import 'package:noir/features/playback/presentation/youtube_video_layer.dart';
import 'package:noir/features/playlists/presentation/add_to_playlist.dart';
import 'package:noir/features/queue/presentation/queue_panel.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/presentation/save_button.dart';
import 'package:noir/features/youtube/presentation/youtube_cover.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';
import 'package:url_launcher/url_launcher.dart';

/// NOIR's signature screen: large artwork over a blurred wash of itself,
/// title, progress, transport, and optionally time-synced lyrics. The queue
/// opens as a side sheet. Dismiss with the chevron, Esc, or a downward
/// swipe.
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  /// Below this width lyrics replace the artwork instead of getting their
  /// own column.
  static const wideBreakpoint = 760.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playbackProvider);
    final lyrics = ref.watch(lyricsVisibleProvider);
    final current = s.current;
    final fx = NoirEffects.of(context);
    void close() => Navigator.of(context).maybePop();

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _ArtworkBackdrop(source: _backdropSource(current?.track)),
              SafeArea(
                child: GestureDetector(
                  onVerticalDragEnd: (d) {
                    if ((d.primaryVelocity ?? 0) > 400) close();
                  },
                  child: Column(
                    children: [
                      _TopBar(onClose: close, state: s),
                      Expanded(
                        child: current == null
                            ? const EmptyState(
                                icon: Icons.music_off_rounded,
                                title: 'Nothing playing',
                                message:
                                    'Pick a song from your library to start.',
                              )
                            : LayoutBuilder(
                                builder: (context, box) {
                                  final wide = box.maxWidth >= wideBreakpoint;
                                  final layout = wide && lyrics
                                      ? _WideLyricsLayout(state: s, box: box)
                                      : SmoothScroll(
                                          builder: (context, scroll) => wide
                                              ? _WideLayout(
                                                  state: s,
                                                  box: box,
                                                  scroll: scroll,
                                                )
                                              : _NarrowLayout(
                                                  state: s,
                                                  box: box,
                                                  scroll: scroll,
                                                  lyrics: lyrics,
                                                ),
                                        );
                                  return AnimatedSwitcher(
                                    duration: fx.motion(NoirMotion.medium),
                                    // Full size, so scroll views (and their
                                    // scrollbars) span the whole window.
                                    layoutBuilder: (current, previous) => Stack(
                                      fit: StackFit.expand,
                                      children: [...previous, ?current],
                                    ),
                                    child: KeyedSubtree(
                                      key: ValueKey((wide, lyrics)),
                                      child: layout,
                                    ),
                                  );
                                },
                              ),
                      ),
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

  /// A small image is plenty for a heavily blurred background.
  static String? _backdropSource(Track? track) {
    if (track == null) return null;
    return track.source == MediaSource.youtube
        ? YouTubeCover.thumbnail(track.uri)
        : track.artwork;
  }
}

/// Full-bleed, heavily blurred artwork under a scrim, cross-fading between
/// tracks. The image is decoded tiny and the blurred layer is cached behind
/// a [RepaintBoundary], so it costs nothing per frame once settled.
class _ArtworkBackdrop extends StatefulWidget {
  const _ArtworkBackdrop({required this.source});

  /// Local file path or image URL.
  final String? source;

  @override
  State<_ArtworkBackdrop> createState() => _ArtworkBackdropState();
}

class _ArtworkBackdropState extends State<_ArtworkBackdrop> {
  ImageProvider? _shown;
  ({String? source, bool blur})? _requested;

  /// Gaussian blur on a 128 px decode; Performance mode skips the filter and
  /// lets bilinear upscaling of a 20 px decode do the softening.
  static const _sigma = 70.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(_ArtworkBackdrop old) {
    super.didUpdateWidget(old);
    _load();
  }

  /// Swaps the image only once the next one is decoded, so the cross-fade
  /// never passes through an empty frame.
  void _load() {
    final source = widget.source;
    final blur = NoirEffects.of(context).ambient;
    final request = (source: source, blur: blur);
    if (request == _requested) return;
    _requested = request;
    if (source == null) {
      _shown = null;
      return;
    }
    final provider = ResizeImage(
      isRemoteImage(source)
          ? NetworkImage(source)
          : FileImage(File(source)) as ImageProvider,
      width: blur ? 128 : 20,
    );
    var failed = false;
    unawaited(
      precacheImage(provider, context, onError: (_, _) => failed = true).then((
        _,
      ) {
        if (!mounted || _requested != request) return;
        setState(() => _shown = failed ? null : provider);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shown = _shown;

    Widget? art;
    if (shown != null) {
      art = Image(
        image: shown,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        excludeFromSemantics: true,
      );
      if (fx.ambient) {
        art = ImageFiltered(
          imageFilter: ImageFilter.blur(
            sigmaX: _sigma,
            sigmaY: _sigma,
            tileMode: TileMode.clamp,
          ),
          child: art,
        );
      }
    }

    // Text sits directly on this, so the scrim follows the theme: dark
    // wash under light text, light wash under dark text.
    final scrim = dark ? Colors.black : c.background;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const NoirBackdrop(),
          AnimatedSwitcher(
            duration: fx.motion(NoirMotion.slow * 3),
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: art == null
                ? const SizedBox.expand(key: ValueKey('none'))
                : RepaintBoundary(key: ValueKey(shown), child: art),
          ),
          if (art != null)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scrim.withValues(alpha: dark ? 0.42 : 0.58),
                    scrim.withValues(alpha: dark ? 0.62 : 0.74),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.onClose, required this.state});

  final VoidCallback onClose;
  final PlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = state.current?.track;
    return WindowDragArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(
          children: [
            if (reservesWindowControlsSpace) const SizedBox(width: 72),
            NoirIconButton(
              icon: Icons.keyboard_arrow_down_rounded,
              tooltip: 'Close player (Esc)',
              size: 26,
              onPressed: onClose,
            ),
            const Spacer(),
            if (track != null && track.localId != null)
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: Icon(
                  Icons.more_horiz_rounded,
                  color: context.noir.textSecondary,
                ),
                onSelected: (v) async {
                  if (v == 'playlist') {
                    await addToPlaylist(context, ref, [track]);
                  }
                  if (v == 'queue' && context.mounted) {
                    await showQueueSheet(context, ref);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'playlist',
                    child: Text('Add to playlist…'),
                  ),
                  PopupMenuItem(value: 'queue', child: Text('Show queue')),
                ],
              ),
            if (usesCustomWindowChrome) ...[
              const SizedBox(width: NoirSpacing.sm),
              const WindowControls(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Cover left, details right, transport centered below.
class _WideLayout extends ConsumerWidget {
  const _WideLayout({
    required this.state,
    required this.box,
    required this.scroll,
  });

  final PlaybackState state;
  final BoxConstraints box;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final art = (box.maxWidth * 0.32).clamp(240.0, 420.0);
    // The scroll view spans the window so its scrollbar sits at the edge;
    // the content is centered and width-limited inside it.
    return SingleChildScrollView(
      controller: scroll,
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: max(0, box.maxHeight - 32)),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _LargeArtwork(state: state, size: art),
                    const SizedBox(width: 48),
                    Expanded(child: _TrackInfo(state: state, large: true)),
                  ],
                ),
                const SizedBox(height: 36),
                const PlaybackControls(large: true),
                const SizedBox(height: 8),
                const _SecondaryControls(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Wide windows with lyrics on: a compact player column beside the lyrics.
class _WideLyricsLayout extends ConsumerWidget {
  const _WideLyricsLayout({required this.state, required this.box});

  final PlaybackState state;
  final BoxConstraints box;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidePlayer = ref.watch(
      settingsProvider.select((s) => s.hideYouTubePlayer),
    );
    final track = state.current!.track;
    final column = (box.maxWidth * 0.36).clamp(300.0, 420.0);
    final art = min(column, box.maxHeight * 0.4).clamp(160.0, 340.0);
    final side = LayoutBuilder(
      builder: (context, side) => ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: side.maxHeight),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _LargeArtwork(state: state, size: art),
                  const SizedBox(height: 24),
                  _TrackInfo(state: state, large: false),
                  const SizedBox(height: 16),
                  const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: PlaybackControls(large: true),
                  ),
                  const SizedBox(height: 8),
                  const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _SecondaryControls(),
                  ),
                  if (track.source == MediaSource.youtube && !hidePlayer) ...[
                    const SizedBox(height: 20),
                    const _YouTubePlayerTile(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 8, 48, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: column, child: side),
              const SizedBox(width: 56),
              Expanded(child: LyricsView(track: track)),
            ],
          ),
        ),
      ),
    );
  }
}

class _NarrowLayout extends ConsumerWidget {
  const _NarrowLayout({
    required this.state,
    required this.box,
    required this.scroll,
    required this.lyrics,
  });

  final PlaybackState state;
  final BoxConstraints box;
  final ScrollController scroll;

  /// Lyrics take the artwork's place.
  final bool lyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidePlayer = ref.watch(
      settingsProvider.select((s) => s.hideYouTubePlayer),
    );
    final art = (box.maxWidth - 48).clamp(160.0, box.maxHeight * 0.45);
    return SingleChildScrollView(
      controller: scroll,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Column(
        children: [
          const SizedBox(height: 8),
          if (lyrics)
            SizedBox(
              height: (box.maxHeight * 0.5).clamp(220.0, 560.0),
              child: LyricsView(track: state.current!.track, compact: true),
            )
          else
            _LargeArtwork(state: state, size: art),
          SizedBox(height: lyrics ? 16 : 28),
          _TrackInfo(state: state, large: false),
          const SizedBox(height: 20),
          const FittedBox(
            fit: BoxFit.scaleDown,
            child: PlaybackControls(large: true),
          ),
          const SizedBox(height: 8),
          const FittedBox(fit: BoxFit.scaleDown, child: _SecondaryControls()),
          if (state.current!.track.source == MediaSource.youtube &&
              !hidePlayer) ...[
            const SizedBox(height: 24),
            const _YouTubePlayerTile(),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Lyrics · volume · queue.
class _SecondaryControls extends ConsumerWidget {
  const _SecondaryControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(lyricsVisibleProvider);
    final queueOpen = ref.watch(queueSheetOpenProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NoirIconButton(
          icon: lyrics ? Icons.lyrics_rounded : Icons.lyrics_outlined,
          tooltip: lyrics ? 'Hide lyrics' : 'Show lyrics',
          active: lyrics,
          onPressed: ref.read(lyricsVisibleProvider.notifier).toggle,
        ),
        const SizedBox(width: NoirSpacing.sm),
        const VolumeControl(),
        const SizedBox(width: NoirSpacing.sm),
        NoirIconButton(
          icon: Icons.queue_music_rounded,
          tooltip: 'Queue',
          active: queueOpen,
          onPressed: () => unawaited(showQueueSheet(context, ref)),
        ),
      ],
    );
  }
}

class _LargeArtwork extends StatelessWidget {
  const _LargeArtwork({required this.state, required this.size});

  final PlaybackState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final track = state.current!.track;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NoirRadii.xlAll,
        boxShadow: [
          BoxShadow(
            color: context.noir.shadow,
            blurRadius: 60,
            offset: const Offset(0, 28),
          ),
          // Soft glow lifting the cover off the blurred wash.
          BoxShadow(
            color: Colors.white.withValues(alpha: dark ? 0.07 : 0.3),
            blurRadius: 48,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Hero(
        tag: 'now-playing-art',
        child: DecoratedBox(
          // Hairline rim, drawn over the cover's edge.
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: NoirRadii.xlAll,
            border: Border.all(
              color: Colors.white.withValues(alpha: dark ? 0.12 : 0.4),
            ),
          ),
          child: track.source == MediaSource.youtube
              ? YouTubeCover(videoId: track.uri, size: size)
              : Artwork(
                  path: track.artwork,
                  size: size,
                  radius: NoirRadii.xl,
                  semanticLabel: 'Artwork for ${track.album ?? track.title}',
                ),
        ),
      ),
    );
  }
}

class _TrackInfo extends ConsumerWidget {
  const _TrackInfo({required this.state, required this.large});

  final PlaybackState state;
  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    final track = state.current!.track;
    final failed =
        state.status == PlaybackStatus.error ||
        state.status == PlaybackStatus.unavailable;
    return Column(
      crossAxisAlignment: large
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: large ? t.displaySmall : t.headlineSmall,
              ),
            ),
            if (track.localId != null)
              NoirIconButton(
                icon: track.isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                tooltip: track.isFavorite
                    ? 'Remove from favorites (this device)'
                    : 'Add to favorites (this device)',
                active: track.isFavorite,
                onPressed: () => unawaited(
                  ref.read(playbackProvider.notifier).toggleFavorite(track),
                ),
              ),
            if (track.source == MediaSource.youtube)
              YouTubeSaveButton(track, size: 22),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          track.artistOrUnknown,
          style: t.titleMedium?.copyWith(
            color: c.textSecondary,
            fontWeight: FontWeight.w400,
          ),
        ),
        if (track.album != null) ...[
          const SizedBox(height: 4),
          Text(
            track.album!,
            style: t.bodyLarge?.copyWith(color: c.textTertiary),
          ),
        ],
        if (track.source == MediaSource.youtube) ...[
          const SizedBox(height: 10),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: c.hover,
                  borderRadius: NoirRadii.pillAll,
                  border: Border.all(color: c.glassBorder),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.smart_display_outlined,
                        size: 14,
                        color: c.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Text('Playing from YouTube', style: t.labelMedium),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => unawaited(
                  launchUrl(
                    youTubeMusicUrl(videoId: track.uri),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: c.textPrimary,
                  textStyle: t.labelMedium,
                ),
                child: const Text('Open in YouTube Music'),
              ),
            ],
          ),
        ],
        if (failed) ...[
          const SizedBox(height: 12),
          Text(
            state.message ?? "This item can't be played.",
            style: t.bodySmall?.copyWith(color: c.destructive),
          ),
        ],
        SizedBox(height: large ? 28 : 20),
        const ProgressSlider(),
        if (large &&
            track.source == MediaSource.youtube &&
            !ref.watch(
              settingsProvider.select((s) => s.hideYouTubePlayer),
            )) ...[
          const SizedBox(height: 20),
          const _YouTubePlayerTile(),
        ],
      ],
    );
  }
}

/// YouTube requires its player to stay visible (≥ 200×200, nothing on top)
/// while it plays, so NOIR keeps a compact player next to the cover. While
/// the queue sheet is open the sheet holds the player instead.
class _YouTubePlayerTile extends ConsumerWidget {
  const _YouTubePlayerTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inSheet = ref.watch(queueSheetOpenProvider);
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(
          YouTubeVideoLayer.miniSize.width.clamp(200.0, box.maxWidth),
          YouTubeVideoLayer.miniSize.height,
        );
        return Align(
          alignment: Alignment.centerLeft,
          child: inSheet
              ? SizedBox.fromSize(size: size)
              : VideoSlot(size: size),
        );
      },
    );
  }
}
