import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'dart:ui' as ui show Image;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/noir_backdrop.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/artwork/application/artwork_providers.dart';
import 'package:noir/features/artwork/domain/art_urls.dart';
import 'package:noir/features/discover/presentation/ytm_artist_screen.dart';
import 'package:noir/features/library/application/library_providers.dart';
import 'package:noir/features/lyrics/application/lyrics_providers.dart';
import 'package:noir/features/lyrics/presentation/lyrics_view.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/playback_controls.dart';
import 'package:noir/features/playback/presentation/youtube_video_layer.dart';
import 'package:noir/features/playlists/presentation/add_to_playlist.dart';
import 'package:noir/features/queue/presentation/queue_panel.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/youtube/presentation/save_button.dart';
import 'package:noir/features/youtube/presentation/youtube_cover.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

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
              _ArtworkBackdrop(source: _backdropSource(ref, current?.track)),
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

  /// A small image is plenty for a heavily blurred background. YouTube
  /// tracks use the square album art once it's known: their video
  /// thumbnails often carry black side bars that would tint the edges.
  static String? _backdropSource(WidgetRef ref, Track? track) {
    if (track == null) return null;
    if (track.source != MediaSource.youtube) return track.artwork;
    final own = track.artworkUrl;
    if (own != null && isGoogleArt(own)) return resizeGoogleArt(own, 226);
    return ref.watch(resolvedArtProvider(track.uri))?.squareUrl(226) ??
        YouTubeCover.thumbnail(track.uri);
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
  Widget? _shown;
  String? _requested;
  bool _started = false;

  /// The artwork is blurred once into a [_blurSize] px bitmap, which is then
  /// upscaled with bicubic filtering. A large-sigma blur at screen size is
  /// downsampled internally and shows blocks; blurring small and scaling up
  /// smoothly doesn't. It is a one-off per track, so Performance mode gets
  /// it too.
  static const _blurSize = 48;
  static const _sigma = 4.0;

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
    if (_started && source == _requested) return;
    _started = true;
    _requested = source;
    if (source == null) {
      _shown = null;
      return;
    }
    final provider = ResizeImage(
      isRemoteImage(source)
          ? NetworkImage(source)
          : FileImage(File(source)) as ImageProvider,
      width: 160,
    );
    unawaited(
      _blurred(provider).then((image) {
        if (!mounted || _requested != source) return;
        setState(
          () => _shown = image == null
              ? null
              : Image(
                  key: ValueKey(source),
                  image: image,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.high,
                  excludeFromSemantics: true,
                ),
        );
      }),
    );
  }

  /// Decodes [provider] and bakes the blur into a tiny bitmap. Null when
  /// the image can't be loaded.
  Future<ImageProvider?> _blurred(ImageProvider provider) async {
    final done = Completer<ImageInfo?>();
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        if (!done.isCompleted) done.complete(info);
      },
      onError: (_, _) {
        if (!done.isCompleted) done.complete(null);
      },
    );
    stream.addListener(listener);
    final info = await done.future;
    stream.removeListener(listener);
    if (info == null) return null;
    try {
      final src = info.image;
      final h = max(1, (_blurSize * src.height / src.width).round());
      // Draw a little past the edges so the blur doesn't darken them.
      const pad = 12.0;
      final recorder = PictureRecorder();
      Canvas(recorder).drawImageRect(
        src,
        Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
        Rect.fromLTWH(-pad, -pad, _blurSize + 2 * pad, h + 2 * pad),
        Paint()
          ..filterQuality = FilterQuality.medium
          ..imageFilter = ImageFilter.blur(
            sigmaX: _sigma,
            sigmaY: _sigma,
            tileMode: TileMode.clamp,
          ),
      );
      final baked = await recorder.endRecording().toImage(_blurSize, h);
      return _BitmapImage(baked);
    } finally {
      info.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shown = _shown;

    final art = shown;

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
                : RepaintBoundary(key: art.key, child: art),
          ),
          if (art != null)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scrim.withValues(alpha: dark ? 0.55 : 0.62),
                    scrim.withValues(alpha: dark ? 0.72 : 0.78),
                  ],
                ),
              ),
            ),
          // Fine grain breaks up 8-bit banding in the smooth gradients.
          if (art != null) const _Grain(),
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
    final links = track?.source == MediaSource.youtube
        ? ref.watch(ytmTrackLinksProvider(track!.uri))
        : null;
    final artists = track == null
        ? const <_Destination>[]
        : _artistsOf(track, links);
    final album = track == null ? null : _albumOf(track, links);
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
            if (track != null)
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
                  if (v == 'album' && context.mounted) {
                    await album?.open(context, ref);
                  }
                  if (v.startsWith('artist ') && context.mounted) {
                    await artists[int.parse(v.substring(7))].open(context, ref);
                  }
                },
                itemBuilder: (_) => [
                  if (track.localId != null)
                    const PopupMenuItem(
                      value: 'playlist',
                      child: Text('Add to playlist…'),
                    ),
                  const PopupMenuItem(
                    value: 'queue',
                    child: Text('Show queue'),
                  ),
                  for (final (i, a) in artists.indexed)
                    PopupMenuItem(
                      value: 'artist $i',
                      child: Text(
                        artists.length == 1
                            ? 'Go to artist'
                            : 'Go to ${a.label}',
                      ),
                    ),
                  if (album != null)
                    const PopupMenuItem(
                      value: 'album',
                      child: Text('Go to album'),
                    ),
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
                  if (state.showsVideoPlayer && !hidePlayer) ...[
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
              Expanded(child: _Lyrics(track: track)),
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
              child: _Lyrics(track: state.current!.track, compact: true),
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
          if (state.showsVideoPlayer && !hidePlayer) ...[
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
        Tooltip(
          message: lyrics ? 'Hide lyrics' : 'Show lyrics',
          child: PillButton(
            label: 'Lyrics',
            icon: Icons.format_quote_rounded,
            filled: lyrics,
            onPressed: ref.read(lyricsVisibleProvider.notifier).toggle,
          ),
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
          child: _CoverSwitcher(track: track, size: size),
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
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
        _ArtistLine(
          track: track,
          style: t.titleMedium?.copyWith(
            color: c.textSecondary,
            fontWeight: FontWeight.w400,
          ),
        ),
        _AlbumLine(
          track: track,
          style: t.bodyLarge?.copyWith(color: c.textTertiary),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: large
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _TrackChange(trackId: track.id, child: details),
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
            state.showsVideoPlayer &&
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

// ------------------------------------------------------- track changes --

/// Cross-fades [child] when [trackId] changes: the new details rise a few
/// pixels into place while the old ones fade out above them. The height
/// follows smoothly, so nothing below jumps.
class _TrackChange extends StatelessWidget {
  const _TrackChange({required this.trackId, required this.child});

  final String trackId;
  final Widget child;

  static const _rise = 7.0;

  @override
  Widget build(BuildContext context) {
    final duration = NoirEffects.of(context).motion(NoirMotion.slow);
    final key = ValueKey(trackId);
    return AnimatedSize(
      duration: duration,
      curve: NoirMotion.standard,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: NoirMotion.standard,
        switchOutCurve: NoirMotion.exit,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, animation) {
          final incoming = child.key == key;
          return FadeTransition(
            opacity: animation,
            child: AnimatedBuilder(
              animation: animation,
              child: child,
              builder: (context, child) {
                final away = 1 - animation.value;
                return Transform.translate(
                  offset: Offset(0, incoming ? away * _rise : -away * _rise),
                  child: child,
                );
              },
            ),
          );
        },
        child: KeyedSubtree(key: key, child: child),
      ),
    );
  }
}

/// The cover, cross-fading (with a slight zoom) to the next track's once
/// that one is decoded, so the fade never passes through an empty frame.
/// Keyed by track only: a YouTube cover keeps its own thumbnail → album
/// art fade inside.
class _CoverSwitcher extends ConsumerStatefulWidget {
  const _CoverSwitcher({required this.track, required this.size});

  final Track track;
  final double size;

  @override
  ConsumerState<_CoverSwitcher> createState() => _CoverSwitcherState();
}

class _CoverSwitcherState extends ConsumerState<_CoverSwitcher> {
  late Track _shown = widget.track;

  /// The track whose cover is being decoded before it is shown.
  String? _pending;

  /// Longest wait for a cover before switching anyway (slow network).
  static const _maxWait = Duration(seconds: 2);

  @override
  void didUpdateWidget(_CoverSwitcher old) {
    super.didUpdateWidget(old);
    final next = widget.track;
    if (next.id == _shown.id) {
      // Same song (e.g. favorite toggled), or back before the other loaded.
      _shown = next;
      _pending = null;
      return;
    }
    if (next.id == _pending) return;
    final image = _imageFor(next);
    if (image == null) {
      _shown = next;
      _pending = null;
      return;
    }
    _pending = next.id;
    unawaited(
      precacheImage(
        image,
        context,
        onError: (_, _) {},
      ).timeout(_maxWait, onTimeout: () {}).then((_) {
        if (!mounted || _pending != next.id) return;
        setState(() {
          _shown = widget.track.id == next.id ? widget.track : next;
          _pending = null;
        });
      }),
    );
  }

  /// The image the cover of [track] will paint, requested exactly as
  /// [Artwork] and [YouTubeCover] request it, so once it is precached the
  /// new cover's first frame is complete. Null when there is nothing to
  /// wait for.
  ImageProvider? _imageFor(Track track) {
    final size = widget.size;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = size * dpr;
    if (track.source == MediaSource.youtube) {
      return _youTubeImage(track.uri, size, dpr);
    }
    final source = track.artwork;
    if (source == null) return null;
    if (youtubeThumbnailVideoId(source) case final videoId?) {
      return _youTubeImage(videoId, size, dpr);
    }
    if (isRemoteImage(source)) {
      return isGoogleArt(source)
          ? ResizeImage(
              NetworkImage(resizeGoogleArt(source, px)),
              width: artBucket(px),
            )
          : NetworkImage(source);
    }
    return ResizeImage(FileImage(File(source)), width: px.ceil());
  }

  ImageProvider _youTubeImage(String videoId, double size, double dpr) {
    final px = size * dpr;
    final art = ref.read(artworkResolverProvider).peek(videoId);
    if (art?.squareUrl(px) case final url?) {
      return ResizeImage(NetworkImage(url), width: artBucket(px));
    }
    final frame = youtubeFrame(px);
    final width = frame.width * (size / frame.square);
    return ResizeImage(
      NetworkImage(youtubeFrameUrl(videoId, frame)),
      width: min(frame.width, (width * dpr).ceil()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final track = _shown;
    final size = widget.size;
    final key = ValueKey(track.id);
    return AnimatedSwitcher(
      duration: NoirEffects.of(context).motion(NoirMotion.slow),
      switchInCurve: NoirMotion.standard,
      layoutBuilder: (current, previous) =>
          Stack(alignment: Alignment.center, children: [...previous, ?current]),
      // The old cover stays opaque underneath until the new one covers it.
      transitionBuilder: (child, animation) => child.key == key
          ? FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1).animate(animation),
                child: child,
              ),
            )
          : child,
      child: KeyedSubtree(
        key: key,
        child: track.source == MediaSource.youtube
            ? YouTubeCover(videoId: track.uri, size: size)
            : Artwork(
                path: track.artwork,
                size: size,
                radius: NoirRadii.xl,
                semanticLabel: 'Artwork for ${track.album ?? track.title}',
              ),
      ),
    );
  }
}

/// Lyrics, cross-fading as a whole between songs (the view itself only
/// fades between its loading and loaded states).
class _Lyrics extends StatelessWidget {
  const _Lyrics({required this.track, this.compact = false});

  final Track track;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: NoirEffects.of(context).motion(NoirMotion.slow),
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: LyricsView(
        key: ValueKey(track.id),
        track: track,
        compact: compact,
      ),
    );
  }
}

// --------------------------------------------------------------- links --

/// A page the playing track's artist or album name leads to.
typedef _Destination = ({
  String label,
  Future<void> Function(BuildContext context, WidgetRef ref) open,
});

/// Closes Now Playing, then shows [location] in the shell beneath it.
void _leaveFor(BuildContext context, String location, {Object? extra}) {
  final router = GoRouter.of(context);
  Navigator.of(context).pop();
  router.go(location, extra: extra);
}

/// Artist pages for [track]: the local artist, or each YouTube Music artist
/// once [links] are known.
List<_Destination> _artistsOf(Track track, YtmTrackLinks? links) {
  if (track.source == MediaSource.youtube) {
    return [
      for (final a in links?.artists ?? const <YtmLink>[])
        (
          label: a.name,
          open: (context, ref) async => _leaveFor(
            context,
            '${ytmBranchBase(context)}/artist/'
            '${Uri.encodeComponent(a.browseId)}',
          ),
        ),
    ];
  }
  final artist = track.artist;
  if (artist == null) return const [];
  return [
    (
      label: artist,
      open: (context, ref) async =>
          _leaveFor(context, '/library/artist', extra: artist),
    ),
  ];
}

/// The album page for [track]: the local album, or the YouTube Music album
/// once [links] are known.
_Destination? _albumOf(Track track, YtmTrackLinks? links) {
  if (track.source == MediaSource.youtube) {
    final album = links?.album;
    if (album == null) return null;
    return (
      label: track.album ?? album.name,
      open: (context, ref) async => _leaveFor(
        context,
        '${ytmBranchBase(context)}/album/'
        '${Uri.encodeComponent(album.browseId)}',
      ),
    );
  }
  final title = track.album;
  if (title == null) return null;
  return (
    label: title,
    open: (context, ref) async {
      // The library groups albums by album artist, which a track does not
      // carry: take the library's own entry when there is one.
      final albums = await ref.read(albumsProvider.future);
      if (!context.mounted) return;
      final album =
          albums
              .where((a) => a.title == title && a.artist == track.artist)
              .firstOrNull ??
          albums.where((a) => a.title == title).firstOrNull ??
          Album(
            title: title,
            artist: track.artistOrUnknown,
            trackCount: 0,
            artworkPath: track.artworkPath,
          );
      _leaveFor(context, '/library/album', extra: album);
    },
  );
}

/// The artist name(s); each one opens its artist page once known.
class _ArtistLine extends ConsumerWidget {
  const _ArtistLine({required this.track, required this.style});

  final Track track;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = track.source == MediaSource.youtube
        ? ref.watch(ytmTrackLinksProvider(track.uri))
        : null;
    final artists = _artistsOf(track, links);
    if (artists.isEmpty) return Text(track.artistOrUnknown, style: style);
    VoidCallback go(_Destination d) =>
        () => unawaited(d.open(context, ref));

    // Link the names where they stand in the byline ("A feat. B"), else
    // list them: "A", "A & B", "A, B & C".
    final text = track.artist ?? '';
    final pieces = <_Piece>[];
    var at = 0;
    for (final a in artists) {
      final i = text.indexOf(a.label, at);
      if (i < 0) {
        pieces.clear();
        break;
      }
      if (i > at) pieces.add((text: text.substring(at, i), onTap: null));
      pieces.add((text: a.label, onTap: go(a)));
      at = i + a.label.length;
    }
    if (pieces.isEmpty) {
      for (final (i, a) in artists.indexed) {
        if (i > 0) {
          pieces.add((
            text: i == artists.length - 1 ? ' & ' : ', ',
            onTap: null,
          ));
        }
        pieces.add((text: a.label, onTap: go(a)));
      }
    } else if (at < text.length) {
      pieces.add((text: text.substring(at), onTap: null));
    }
    return _LinkedText(pieces, style: style);
  }
}

/// The album name, opening the album page once known; nothing when the
/// track names no album.
class _AlbumLine extends ConsumerWidget {
  const _AlbumLine({required this.track, required this.style});

  final Track track;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = track.source == MediaSource.youtube
        ? ref.watch(ytmTrackLinksProvider(track.uri))
        : null;
    final album = _albumOf(track, links);
    final text = album?.label ?? track.album;
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: _LinkedText([
        (
          text: text,
          onTap: album == null
              ? null
              : () => unawaited(album.open(context, ref)),
        ),
      ], style: style),
    );
  }
}

typedef _Piece = ({String text, VoidCallback? onTap});

/// Text whose tappable pieces show a pointer and an underline on hover.
class _LinkedText extends StatefulWidget {
  const _LinkedText(this.pieces, {required this.style});

  final List<_Piece> pieces;
  final TextStyle? style;

  @override
  State<_LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<_LinkedText> {
  final _recognizers = <int, TapGestureRecognizer>{};
  int? _hovered;

  @override
  void didUpdateWidget(_LinkedText old) {
    super.didUpdateWidget(old);
    _recognizers.removeWhere((i, r) {
      final gone = i >= widget.pieces.length || widget.pieces[i].onTap == null;
      if (gone) r.dispose();
      return gone;
    });
    if (!_recognizers.containsKey(_hovered)) _hovered = null;
  }

  @override
  void dispose() {
    for (final r in _recognizers.values) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          for (final (i, piece) in widget.pieces.indexed)
            if (piece.onTap case final onTap?)
              TextSpan(
                text: piece.text,
                recognizer: (_recognizers[i] ??= TapGestureRecognizer())
                  ..onTap = onTap,
                mouseCursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hovered = i),
                onExit: (_) {
                  if (_hovered == i) setState(() => _hovered = null);
                },
                style: _hovered == i
                    ? const TextStyle(decoration: TextDecoration.underline)
                    : null,
              )
            else
              TextSpan(text: piece.text),
        ],
      ),
      style: widget.style,
    );
  }
}

/// An already decoded bitmap as an [ImageProvider], so the baked blur goes
/// through [Image] like any other artwork.
class _BitmapImage extends ImageProvider<_BitmapImage> {
  const _BitmapImage(this.image);

  final ui.Image image;

  @override
  Future<_BitmapImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _BitmapImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture(ImageInfo(image: key.image.clone())),
  );
}

/// Static film grain, a few percent strong, tiled over the backdrop.
class _Grain extends StatefulWidget {
  const _Grain();

  @override
  State<_Grain> createState() => _GrainState();
}

class _GrainState extends State<_Grain> {
  static Future<ui.Image>? _tile;
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    unawaited(
      (_tile ??= _makeTile()).then((image) {
        if (mounted) setState(() => _image = image);
      }),
    );
  }

  static const _alpha = 6;

  static Future<ui.Image> _makeTile() {
    const size = 96;
    final random = Random(7);
    final pixels = Uint8List(size * size * 4);
    for (var i = 0; i < pixels.length; i += 4) {
      // Premultiplied: a grey of up to [_alpha] over a [_alpha] coverage.
      final v = random.nextInt(_alpha + 1);
      pixels
        ..[i] = v
        ..[i + 1] = v
        ..[i + 2] = v
        ..[i + 3] = _alpha;
    }
    final done = Completer<ui.Image>();
    decodeImageFromPixels(
      pixels,
      size,
      size,
      PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(painter: _GrainPainter(image), size: Size.infinite),
    );
  }
}

class _GrainPainter extends CustomPainter {
  _GrainPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ImageShader(
          image,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.identity().storage,
        ),
    );
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.image != image;
}
