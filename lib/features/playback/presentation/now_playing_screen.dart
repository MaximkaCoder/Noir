import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'dart:ui' as ui show Image;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/liquid_press.dart';
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
import 'package:noir/features/playback/presentation/now_playing_route.dart';
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
///
/// Showing lyrics doesn't swap layouts: one layout ([_Stage]) glides every
/// piece between its place with and without lyrics.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  /// Below this width lyrics replace the artwork instead of getting their
  /// own column.
  static const wideBreakpoint = 760.0;

  /// How long showing or hiding lyrics rearranges the screen.
  static const lyricsDuration = Duration(milliseconds: 450);

  /// The cover's place in the layout, for tests.
  static const coverKey = ValueKey('now-playing-cover');

  /// The lyrics' place in the layout, for tests.
  static const lyricsKey = ValueKey('now-playing-lyrics');

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen>
    with SingleTickerProviderStateMixin {
  /// 0 without lyrics, 1 with them.
  late final AnimationController _lyrics = AnimationController(
    vsync: this,
    value: ref.read(lyricsVisibleProvider) ? 1 : 0,
  )..addStatusListener((_) => setState(() {}));
  late final CurvedAnimation _lyricsCurve = CurvedAnimation(
    parent: _lyrics,
    curve: NoirMotion.emphasized,
    reverseCurve: NoirMotion.emphasized.flipped,
  );

  /// The route's own animation, eased like the morph.
  Animation<double>? _route;
  CurvedAnimation? _routeCurve;

  /// Whether the opening transition is over. Lyrics (and their lookup) wait
  /// for it, so nothing heavy competes with the morph.
  bool _settled = false;

  /// The baked backdrop on screen, which the content fades in over.
  final _backdrop = ValueNotifier<ui.Image?>(null);

  @override
  void initState() {
    super.initState();
    ref.listenManual(lyricsVisibleProvider, (_, visible) {
      final duration = NoirEffects.of(context)
          .motion(NowPlayingScreen.lyricsDuration);
      if (visible) {
        _lyrics.animateTo(1, duration: duration);
      } else {
        // Backwards, so it ends dismissed and the lyrics leave the tree.
        _lyrics.animateBack(0, duration: duration);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (route == _route) return;
    _route?.removeStatusListener(_routeStatus);
    _routeCurve?.dispose();
    _route = route;
    _routeCurve = route == null ? null : NowPlayingTransition.curve(route);
    route?.addStatusListener(_routeStatus);
    _settled = route == null || route.isCompleted;
  }

  void _routeStatus(AnimationStatus status) {
    if (status.isCompleted && !_settled) setState(() => _settled = true);
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_routeStatus);
    _routeCurve?.dispose();
    _lyricsCurve.dispose();
    _lyrics.dispose();
    _backdrop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(playbackProvider);
    final current = s.current;
    void close() => Navigator.of(context).maybePop();

    // Present while shown or on the way in or out.
    final lyrics = !_lyrics.isDismissed;
    final routeCurve = _routeCurve;

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _ArtworkBackdrop(
                source: _backdropSource(ref, current?.track),
                baked: _backdrop,
              ),
              LiquidPressScope(
                child: RepaintBoundary(
                  child: SafeArea(
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
                                        'Pick a song from your library to '
                                        'start.',
                                  )
                                : LayoutBuilder(
                                    builder: (context, box) => _Player(
                                      state: s,
                                      box: box,
                                      lyrics: _lyricsCurve,
                                      showLyrics: lyrics,
                                      lyricsReady: _settled,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // While the page morphs open (or closed) its content fades
              // in over a copy of the backdrop — no offscreen layer.
              if (routeCurve != null)
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _VeilPainter(
                        progress: routeCurve,
                        image: _backdrop,
                        scrim: _scrimColors(context),
                        fallback: context.noir.background,
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

/// The wash over the artwork backdrop, top to bottom. Text sits directly on
/// it, so it follows the theme: dark under light text, light under dark.
List<Color> _scrimColors(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final scrim = dark ? Colors.black : context.noir.background;
  return [
    scrim.withValues(alpha: dark ? 0.55 : 0.62),
    scrim.withValues(alpha: dark ? 0.72 : 0.78),
  ];
}

/// Paints the page's backdrop over its content at 1 − content opacity, so
/// the content appears to fade in without a layer of its own.
class _VeilPainter extends CustomPainter {
  _VeilPainter({
    required this.progress,
    required this.image,
    required this.scrim,
    required this.fallback,
  }) : super(repaint: Listenable.merge([progress, image]));

  final Animation<double> progress;
  final ValueListenable<ui.Image?> image;
  final List<Color> scrim;

  /// Painted when there is no artwork.
  final Color fallback;

  @override
  void paint(Canvas canvas, Size size) {
    final veil = 1 - NowPlayingTransition.contentOpacity(progress.value);
    if (veil <= 0) return;
    final rect = Offset.zero & size;
    final art = image.value;
    if (art == null) {
      canvas.drawRect(
        rect,
        Paint()..color = fallback.withValues(alpha: fallback.a * veil),
      );
      return;
    }
    paintImage(
      canvas: canvas,
      rect: rect,
      image: art,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.high,
      opacity: veil,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [for (final c in scrim) c.withValues(alpha: c.a * veil)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_VeilPainter old) =>
      old.progress != progress ||
      old.image != image ||
      !listEquals(old.scrim, scrim) ||
      old.fallback != fallback;
}

/// Full-bleed, heavily blurred artwork under a scrim, cross-fading between
/// tracks. The image is decoded tiny and blurred once per track into a
/// bitmap that is kept for the last few tracks, so reopening Now Playing
/// shows it on the very first frame. Cross-fades paint the image with an
/// alpha instead of fading a layer.
class _ArtworkBackdrop extends StatefulWidget {
  const _ArtworkBackdrop({required this.source, required this.baked});

  /// Local file path or image URL.
  final String? source;

  /// Receives the bitmap on screen.
  final ValueNotifier<ui.Image?> baked;

  @override
  State<_ArtworkBackdrop> createState() => _ArtworkBackdropState();
}

class _ArtworkBackdropState extends State<_ArtworkBackdrop>
    with SingleTickerProviderStateMixin {
  _BitmapImage? _shown;

  /// The previous image, under [_shown] while it fades in.
  _BitmapImage? _previous;
  String? _requested;
  bool _started = false;

  late final AnimationController _fade = AnimationController(
    vsync: this,
    value: 1,
  )..addStatusListener(_faded);

  /// Baked backdrops of the last few tracks, by source.
  static final _cache = <String, _BitmapImage>{};
  static const _cacheSize = 8;

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

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _faded(AnimationStatus status) {
    if (status.isCompleted && _previous != null) {
      setState(() => _previous = null);
    }
  }

  /// Swaps the image only once the next one is baked, so the cross-fade
  /// never passes through an empty frame.
  void _load() {
    final source = widget.source;
    if (_started && source == _requested) return;
    final first = !_started;
    _started = true;
    _requested = source;
    if (source == null) {
      _present(null, animate: !first);
      return;
    }
    final cached = _cache.remove(source);
    if (cached != null) {
      _cache[source] = cached;
      _present(cached, animate: !first);
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
        if (image != null) {
          _cache[source] = image;
          while (_cache.length > _cacheSize) {
            _cache.remove(_cache.keys.first);
          }
        }
        if (!mounted || _requested != source) return;
        setState(() => _present(image, animate: true));
      }),
    );
  }

  void _present(_BitmapImage? image, {required bool animate}) {
    if (image == _shown) return;
    _previous = animate ? _shown : null;
    _shown = image;
    // Published after this frame: listeners repaint, they never rebuild.
    widget.baked.value = image?.image;
    final duration = animate
        ? NoirEffects.of(context).motion(NoirMotion.slow * 3)
        : Duration.zero;
    if (duration == Duration.zero) {
      _previous = null;
      _fade.value = 1;
    } else {
      _fade
        ..duration = duration
        ..forward(from: 0);
    }
  }

  /// Decodes [provider] and bakes the blur into a tiny bitmap. Null when
  /// the image can't be loaded.
  Future<_BitmapImage?> _blurred(ImageProvider provider) async {
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

  Widget _image(_BitmapImage image, Animation<double>? opacity) => Image(
    image: image,
    fit: BoxFit.cover,
    gaplessPlayback: true,
    filterQuality: FilterQuality.high,
    excludeFromSemantics: true,
    opacity: opacity,
  );

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final previous = _previous;
    final scrim = _scrimColors(context);
    final art = shown != null || previous != null;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const NoirBackdrop(),
          if (previous != null)
            _image(previous, shown == null ? ReverseAnimation(_fade) : null),
          if (shown != null) _image(shown, previous == null ? null : _fade),
          if (art)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: scrim,
                ),
              ),
            ),
          // Fine grain breaks up 8-bit banding in the smooth gradients.
          if (art) const _Grain(),
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
              LiquidPress(
                child: PopupMenuButton<String>(
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
                      await artists[int.parse(v.substring(7))].open(
                        context,
                        ref,
                      );
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
              ),
            if (usesCustomWindowChrome) ...[
              const SizedBox(width: NoirSpacing.sm),
              // Over the artwork wash, not the shell's plain background.
              const WindowControls(onImage: true),
            ],
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- layout --

/// The player: cover, details, progress, transport and secondary controls
/// — and lyrics while [showLyrics] — placed by [_Stage] for the window
/// size and how far [lyrics] has come in.
class _Player extends ConsumerWidget {
  const _Player({
    required this.state,
    required this.box,
    required this.lyrics,
    required this.showLyrics,
    required this.lyricsReady,
  });

  final PlaybackState state;
  final BoxConstraints box;
  final Animation<double> lyrics;
  final bool showLyrics;

  /// False until the page has finished opening; lyrics wait for it.
  final bool lyricsReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidePlayer = ref.watch(
      settingsProvider.select((s) => s.hideYouTubePlayer),
    );
    final track = state.current!.track;
    final wide = box.maxWidth >= NowPlayingScreen.wideBreakpoint;
    final video = track.source == MediaSource.youtube && !hidePlayer;
    // Lyrics replace the cover on narrow windows: gone once they're in.
    final cover = wide || lyrics.value < 1 || lyrics.status.isAnimating;
    final art = _Stage.coverSize(box, wide: wide);

    Widget details(double large) => _TrackDetails(state: state, large: large);

    return SmoothScroll(
      builder: (context, scroll) => SingleChildScrollView(
        controller: scroll,
        child: _Stage(
          lyrics: lyrics,
          wide: wide,
          viewport: box.maxHeight,
          children: [
            if (cover)
              _StageSlot(
                slot: _Slot.cover,
                child: KeyedSubtree(
                  key: NowPlayingScreen.coverKey,
                  child: wide
                      ? _LargeArtwork(state: state, size: art)
                      : FadeTransition(
                          opacity: ReverseAnimation(lyrics),
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: 1,
                              end: 0.92,
                            ).animate(lyrics),
                            child: _LargeArtwork(state: state, size: art),
                          ),
                        ),
                ),
              ),
            _StageSlot(
              slot: _Slot.details,
              // Only the title's size follows the animation.
              child: wide
                  ? AnimatedBuilder(
                      animation: lyrics,
                      builder: (context, _) => details(1 - lyrics.value),
                    )
                  : details(0),
            ),
            const _StageSlot(slot: _Slot.progress, child: ProgressSlider()),
            const _StageSlot(
              slot: _Slot.transport,
              child: PlaybackControls(large: true),
            ),
            const _StageSlot(
              slot: _Slot.secondary,
              child: _SecondaryControls(),
            ),
            if (video)
              _StageSlot(
                slot: _Slot.video,
                // Rebuilt while it moves, so the player follows its slot.
                child: AnimatedBuilder(
                  animation: lyrics,
                  builder: (context, _) => const _YouTubePlayerTile(),
                ),
              ),
            if (showLyrics)
              _StageSlot(
                slot: _Slot.lyrics,
                child: KeyedSubtree(
                  key: NowPlayingScreen.lyricsKey,
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: lyrics,
                      curve: const Interval(0.3, 1),
                    ),
                    child: wide
                        ? _Lyrics(track: track, ready: lyricsReady)
                        : ScaleTransition(
                            scale: Tween<double>(
                              begin: 0.96,
                              end: 1,
                            ).animate(lyrics),
                            child: _Lyrics(
                              track: track,
                              ready: lyricsReady,
                              compact: true,
                            ),
                          ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _Slot { cover, details, progress, transport, secondary, video, lyrics }

class _StageParentData extends ContainerBoxParentData<RenderBox> {
  _Slot? slot;

  /// Paint scale (controls shrink to fit a narrow column).
  double scale = 1;
}

class _StageSlot extends ParentDataWidget<_StageParentData> {
  const _StageSlot({required this.slot, required super.child});

  final _Slot slot;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _StageParentData;
    if (data.slot == slot) return;
    data.slot = slot;
    renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _Stage;
}

/// Lays the player out without lyrics (t = 0), with them (t = 1), or
/// anywhere between: every piece's rect is interpolated between its two
/// places, so showing lyrics glides the player aside instead of swapping
/// layouts. Wide windows move the player into a left column beside the
/// lyrics; narrow ones put the lyrics where the cover was. Relayouts on
/// each animation tick without rebuilding anything.
///
/// Inside a vertical scroll view it is at least [viewport] tall, taller
/// when the content needs more (large text).
class _Stage extends MultiChildRenderObjectWidget {
  const _Stage({
    required this.lyrics,
    required this.wide,
    required this.viewport,
    required super.children,
  });

  final Animation<double> lyrics;
  final bool wide;
  final double viewport;

  /// The cover's size without lyrics (the larger of its two sizes), which
  /// its image is decoded for.
  static double coverSize(BoxConstraints box, {required bool wide}) => wide
      ? (box.maxWidth * 0.32).clamp(240.0, 420.0)
      : max<double>(160, min(box.maxWidth - 48, box.maxHeight * 0.45));

  @override
  _RenderStage createRenderObject(BuildContext context) =>
      _RenderStage(lyrics, wide: wide, viewport: viewport);

  @override
  void updateRenderObject(BuildContext context, _RenderStage renderObject) {
    if (renderObject.wide != wide || renderObject.viewport != viewport) {
      renderObject
        ..wide = wide
        ..viewport = viewport
        ..markNeedsLayout();
    }
    renderObject.lyrics = lyrics;
  }
}

class _RenderStage extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _StageParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _StageParentData> {
  _RenderStage(this._lyrics, {required this.wide, required this.viewport});

  Animation<double> get lyrics => _lyrics;
  Animation<double> _lyrics;
  set lyrics(Animation<double> value) {
    if (value == _lyrics) return;
    if (attached) _lyrics.removeListener(markNeedsLayout);
    _lyrics = value;
    if (attached) _lyrics.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  bool wide;
  double viewport;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _StageParentData) {
      child.parentData = _StageParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _lyrics.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _lyrics.removeListener(markNeedsLayout);
    super.detach();
  }

  Map<_Slot, RenderBox> _children() => {
    for (var child = firstChild; child != null; child = childAfter(child))
      (child.parentData! as _StageParentData).slot!: child,
  };

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  void performLayout() {
    final c = _children();
    final w = constraints.maxWidth;
    final h = viewport;
    final t = _lyrics.value.clamp(0.0, 1.0);

    Size measure(_Slot slot, double maxWidth) {
      final child = c[slot];
      if (child == null) return Size.zero;
      child.layout(BoxConstraints(maxWidth: maxWidth), parentUsesSize: true);
      return child.size;
    }

    void place(_Slot slot, Offset offset, {double scale = 1}) {
      final child = c[slot];
      if (child == null) return;
      (child.parentData! as _StageParentData)
        ..offset = offset
        ..scale = scale;
    }

    void placeTight(_Slot slot, Rect rect) {
      final child = c[slot];
      if (child == null) return;
      child.layout(BoxConstraints.tight(rect.size));
      place(slot, rect.topLeft);
    }

    // Controls keep their natural size, shrunk only to fit [width].
    final transport = measure(_Slot.transport, double.infinity);
    final secondary = measure(_Slot.secondary, double.infinity);

    double height;
    if (wide) {
      // Without lyrics: cover beside the details, controls centered below.
      final cwA = min<double>(w - 96, 1040);
      final xA = (w - cwA) / 2;
      final artA = (w * 0.32).clamp(240.0, 420.0);
      final dwA = max<double>(0, cwA - artA - 48);

      // With lyrics: a player column beside them.
      final cwB = min<double>(w - 96, 1280);
      final xB = (w - cwB) / 2;
      final colB = (cwB * 0.36).clamp(280.0, 400.0);
      final gapB = (cwB * 0.06).clamp(32.0, 80.0);
      final artB = min(colB, h * 0.4).clamp(160.0, 340.0);

      final dw = _lerp(dwA, colB, t);
      final details = measure(_Slot.details, dw);
      final progress = measure(_Slot.progress, dw);
      final video = measure(_Slot.video, dw);
      final hasVideo = c[_Slot.video] != null;

      // Without lyrics.
      final rightA =
          details.height +
          28 +
          progress.height +
          (hasVideo ? 20 + video.height : 0);
      final rowA = max(artA, rightA);
      final totalA = rowA + 36 + transport.height + 8 + secondary.height;
      final yA = max<double>(16, (h - totalA) / 2);
      final coverA = Rect.fromLTWH(xA, yA + (rowA - artA) / 2, artA, artA);
      final detailsA = Offset(xA + artA + 48, yA + (rowA - rightA) / 2);
      final progressA = detailsA.translate(0, details.height + 28);
      final videoA = progressA.translate(0, progress.height + 20);
      final transportA = Offset(
        xA + (cwA - transport.width) / 2,
        yA + rowA + 36,
      );
      final secondaryA = Offset(
        xA + (cwA - secondary.width) / 2,
        transportA.dy + transport.height + 8,
      );
      final heightA = yA + totalA + 16;

      // With lyrics.
      final tScale = min<double>(1, colB / max<double>(1, transport.width));
      final sScale = min<double>(1, colB / max<double>(1, secondary.width));
      final totalB =
          artB +
          24 +
          details.height +
          16 +
          progress.height +
          16 +
          transport.height * tScale +
          8 +
          secondary.height * sScale +
          (hasVideo ? 20 + video.height : 0);
      final yB = max<double>(8, (h - totalB) / 2);
      final coverB = Rect.fromLTWH(xB + (colB - artB) / 2, yB, artB, artB);
      final detailsB = Offset(xB, coverB.bottom + 24);
      final progressB = detailsB.translate(0, details.height + 16);
      final transportB = Offset(
        xB + (colB - transport.width * tScale) / 2,
        progressB.dy + progress.height + 16,
      );
      final secondaryB = Offset(
        xB + (colB - secondary.width * sScale) / 2,
        transportB.dy + transport.height * tScale + 8,
      );
      final videoB = Offset(xB, secondaryB.dy + secondary.height * sScale + 20);
      final heightB = max(h, yB + totalB + 24);

      placeTight(_Slot.cover, Rect.lerp(coverA, coverB, t)!);
      place(_Slot.details, Offset.lerp(detailsA, detailsB, t)!);
      place(_Slot.progress, Offset.lerp(progressA, progressB, t)!);
      place(_Slot.video, Offset.lerp(videoA, videoB, t)!);
      place(
        _Slot.transport,
        Offset.lerp(transportA, transportB, t)!,
        scale: _lerp(1, tScale, t),
      );
      place(
        _Slot.secondary,
        Offset.lerp(secondaryA, secondaryB, t)!,
        scale: _lerp(1, sScale, t),
      );
      // Lyrics slide in from a little to the right as they fade in.
      final lyricsLeft = xB + colB + gapB;
      placeTight(
        _Slot.lyrics,
        Rect.fromLTWH(
          lyricsLeft + (1 - t) * 48,
          8,
          max(0, cwB - colB - gapB),
          max(0, h - 32),
        ),
      );
      height = _lerp(heightA, heightB, t);
    } else {
      final cw = max<double>(0, w - 48);
      const x = 24.0;
      final art = max<double>(160, min(cw, h * 0.45));
      final lyricsHeight = (h * 0.5).clamp(220.0, 560.0);
      final details = measure(_Slot.details, cw);
      final progress = measure(_Slot.progress, cw);
      final video = measure(_Slot.video, cw);
      final hasVideo = c[_Slot.video] != null;
      final tScale = min<double>(1, cw / max<double>(1, transport.width));
      final sScale = min<double>(1, cw / max<double>(1, secondary.width));

      // The lyrics take the cover's place; everything below follows.
      const top = 16.0;
      placeTight(_Slot.cover, Rect.fromLTWH((w - art) / 2, top, art, art));
      placeTight(_Slot.lyrics, Rect.fromLTWH(x, top, cw, lyricsHeight));
      var y = top + _lerp(art, lyricsHeight, t) + _lerp(28, 16, t);
      place(_Slot.details, Offset(x, y));
      y += details.height + 20;
      place(_Slot.progress, Offset(x, y));
      y += progress.height + 20;
      place(
        _Slot.transport,
        Offset((w - transport.width * tScale) / 2, y),
        scale: tScale,
      );
      y += transport.height * tScale + 8;
      place(
        _Slot.secondary,
        Offset((w - secondary.width * sScale) / 2, y),
        scale: sScale,
      );
      y += secondary.height * sScale;
      if (hasVideo) {
        place(_Slot.video, Offset(x, y + 24));
        y += 24 + video.height;
      }
      height = y + 24;
    }
    size = constraints.constrain(Size(w, max(h, height)));
  }

  Matrix4 _transformOf(_StageParentData data) =>
      Matrix4.translationValues(data.offset.dx, data.offset.dy, 0)
        ..scaleByDouble(data.scale, data.scale, 1, 1);

  @override
  void paint(PaintingContext context, Offset offset) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _StageParentData;
      if (data.scale == 1) {
        context.paintChild(child, offset + data.offset);
      } else {
        context.pushTransform(
          needsCompositing,
          offset,
          _transformOf(data),
          (context, offset) => context.paintChild(child!, offset),
        );
      }
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (var child = lastChild; child != null; child = childBefore(child)) {
      final data = child.parentData! as _StageParentData;
      final hit = result.addWithPaintTransform(
        transform: _transformOf(data),
        position: position,
        hitTest: (result, position) =>
            child!.hitTest(result, position: position),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_transformOf(child.parentData! as _StageParentData));
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
        // PillButton has no Liquid Glass response of its own.
        LiquidPress(
          pressedScale: 0.94,
          bubbleScale: 1.06,
          child: Tooltip(
            message: lyrics ? 'Hide lyrics' : 'Show lyrics',
            child: PillButton(
              label: 'Lyrics',
              icon: Icons.format_quote_rounded,
              filled: lyrics,
              onPressed: ref.read(lyricsVisibleProvider.notifier).toggle,
            ),
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

  /// The size its image is decoded for; the layout may draw it smaller.
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

/// Title (with the save heart), artist and album. [large] runs from 0
/// (beside lyrics, narrow windows) to 1 (wide, beside the cover) and sizes
/// the title between the two.
class _TrackDetails extends ConsumerWidget {
  const _TrackDetails({required this.state, required this.large});

  final PlaybackState state;
  final double large;

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
                style: TextStyle.lerp(t.headlineSmall, t.displaySmall, large),
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
          widthFactor: 1,
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
    final switcher = AnimatedSwitcher(
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
    );
    // A zero-length AnimatedSize trips over its own relayout when the
    // details resize (the title shrinking beside lyrics).
    if (duration == Duration.zero) return switcher;
    return AnimatedSize(
      duration: duration,
      curve: NoirMotion.standard,
      alignment: Alignment.topCenter,
      child: switcher,
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
/// fades between its loading and loaded states). Nothing is shown — or
/// looked up — until [ready].
class _Lyrics extends StatelessWidget {
  const _Lyrics({
    required this.track,
    required this.ready,
    this.compact = false,
  });

  final Track track;
  final bool ready;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: NoirEffects.of(context).motion(NoirMotion.slow),
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: ready
          ? LyricsView(key: ValueKey(track.id), track: track, compact: compact)
          : const SizedBox.expand(key: ValueKey('waiting')),
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
