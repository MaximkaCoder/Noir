import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'dart:ui' as ui show Image;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/platform/form_factor.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/artwork_flow.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/liquid_press.dart';
import 'package:noir/core/widgets/noir_backdrop.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/artwork/application/artwork_providers.dart';
import 'package:noir/features/artwork/domain/art_urls.dart';
import 'package:noir/features/discover/presentation/dislike_actions.dart';
import 'package:noir/features/discover/presentation/ytm_artist_screen.dart';
import 'package:noir/features/library/application/library_providers.dart';
import 'package:noir/features/lyrics/application/lyrics_providers.dart';
import 'package:noir/features/lyrics/presentation/lyrics_view.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/application/transition_status.dart';
import 'package:noir/features/playback/presentation/mix_mode_button.dart';
import 'package:noir/features/playback/presentation/now_playing_route.dart';
import 'package:noir/features/playback/presentation/playback_controls.dart';
import 'package:noir/features/playback/presentation/playback_shortcuts.dart';
import 'package:noir/features/playback/presentation/youtube_video_layer.dart';
import 'package:noir/features/playlists/presentation/add_to_playlist.dart';
import 'package:noir/features/queue/presentation/queue_panel.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
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

  /// The [NowPlayingVeilPainter]'s paint, for tests.
  static const veilKey = ValueKey('now-playing-veil');

  /// The flowing backdrop's paint, for tests.
  static const flowKey = ValueKey('now-playing-flow');

  /// Whether the backdrop may flow at all. Off under `flutter test`, where
  /// an endless animation would keep every page from settling; tests of
  /// the flow switch it on.
  static bool flowEnabled = !Platform.environment.containsKey('FLUTTER_TEST');

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

  /// The route's own animation, and how visible the content and how opaque
  /// the backdrop are along it.
  Animation<double>? _route;
  CurvedAnimation? _content;
  CurvedAnimation? _material;

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
    _content?.dispose();
    _material?.dispose();
    _route = route;
    _content = route == null ? null : NowPlayingTransition.contentCurve(route);
    _material = route == null
        ? null
        : NowPlayingTransition.backdropCurve(route);
    route?.addStatusListener(_routeStatus);
    _settled = route == null || route.isCompleted;
  }

  void _routeStatus(AnimationStatus status) {
    if (status.isCompleted && !_settled) setState(() => _settled = true);
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_routeStatus);
    _content?.dispose();
    _material?.dispose();
    _lyricsCurve.dispose();
    _lyrics.dispose();
    _backdrop.dispose();
    super.dispose();
  }

  /// A drag down closing the page (phones).
  NowPlayingDrag? _drag;

  void _endDrag(double velocity) {
    _drag?.end(velocity);
    _drag = null;
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(playbackProvider);
    final current = s.current;
    void close() => Navigator.of(context).maybePop();

    // Present while shown or on the way in or out.
    final lyrics = !_lyrics.isDismissed;
    final content = _content;
    final material = _material;

    // A route above the shell, so the shell's shortcuts don't reach here.
    return PlaybackShortcuts(
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // The opaque backdrop and the content are skipped while the
                // morph shows only the (possibly see-through) material.
                _ContentGate(
                  content: content,
                  child: _ArtworkBackdrop(
                    source: _backdropSource(ref, current?.track),
                    baked: _backdrop,
                  ),
                ),
                _ContentGate(
                  content: content,
                  child: LiquidPressScope(
                    child: RepaintBoundary(
                      child: SafeArea(
                        child: GestureDetector(
                          // Phones: dragged down, the page follows the
                          // finger and closes past halfway or on a flick.
                          onVerticalDragStart: FormFactor.touch
                              ? (_) => _drag = NowPlayingDrag(
                                  extent: MediaQuery.sizeOf(context).height,
                                  opening: false,
                                )
                              : null,
                          onVerticalDragUpdate: FormFactor.touch
                              ? (d) => _drag?.update(d.delta.dy)
                              : null,
                          onVerticalDragCancel: FormFactor.touch
                              ? () => _endDrag(0)
                              : null,
                          onVerticalDragEnd: (d) {
                            if (_drag != null) {
                              _endDrag(d.velocity.pixelsPerSecond.dy);
                            } else if ((d.primaryVelocity ?? 0) > 400) {
                              close();
                            }
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
                ),
                // While the page morphs open (or closed) its content fades
                // in over a copy of the backdrop, and the backdrop itself is
                // painted see-through by alpha — no offscreen layer.
                if (content != null && material != null)
                  IgnorePointer(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        key: NowPlayingScreen.veilKey,
                        size: Size.infinite,
                        painter: NowPlayingVeilPainter(
                          content: content,
                          material: material,
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

/// The page's material while it morphs. While the content shows, it paints
/// the page's backdrop over the content at 1 − content opacity, so the
/// content appears to fade without a layer of its own. Once the content is
/// gone (and [_ContentGate] skips it and the opaque backdrop), it is the
/// backdrop, painted at [backdropOpacity] so the shell shows through.
class NowPlayingVeilPainter extends CustomPainter {
  NowPlayingVeilPainter({
    required this.content,
    required this.material,
    required this.image,
    required this.scrim,
    required this.fallback,
  }) : super(repaint: Listenable.merge([content, material, image]));

  /// See [NowPlayingTransition.contentCurve].
  final Animation<double> content;

  /// See [NowPlayingTransition.backdropCurve].
  final Animation<double> material;
  final ValueListenable<ui.Image?> image;
  final List<Color> scrim;

  /// Painted when there is no artwork.
  final Color fallback;

  /// How visible the content is now.
  double get contentOpacity =>
      NowPlayingTransition.morphs ? content.value.clamp(0.0, 1.0) : 1;

  /// How opaque the page's backdrop is now: below 1 the shell shows
  /// through the morphing shape. Opaque while any content shows.
  double get backdropOpacity =>
      contentOpacity > 0 ? 1 : material.value.clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final shown = contentOpacity;
    final veil = shown > 0 ? 1 - shown : backdropOpacity;
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
  bool shouldRepaint(NowPlayingVeilPainter old) =>
      old.content != content ||
      old.material != material ||
      old.image != image ||
      !listEquals(old.scrim, scrim) ||
      old.fallback != fallback;
}

/// Paints [child] only while some of Now Playing's content shows (always
/// once the page is open). Repaints only when that flips, so the morph
/// never re-records the content or the opaque backdrop.
class _ContentGate extends SingleChildRenderObjectWidget {
  const _ContentGate({required this.content, required super.child});

  /// See [NowPlayingTransition.contentCurve]; null outside a route.
  final Animation<double>? content;

  @override
  _RenderContentGate createRenderObject(BuildContext context) =>
      _RenderContentGate(content);

  @override
  void updateRenderObject(BuildContext context, _RenderContentGate gate) =>
      gate.content = content;
}

class _RenderContentGate extends RenderProxyBox {
  _RenderContentGate(this._content);

  Animation<double>? get content => _content;
  Animation<double>? _content;
  set content(Animation<double>? value) {
    if (value == _content) return;
    if (attached) _content?.removeListener(_check);
    _content = value;
    if (attached) _content?.addListener(_check);
    _check();
  }

  bool _shown = true;

  bool get _visible {
    final content = _content;
    return content == null || content.value > 0 || !NowPlayingTransition.morphs;
  }

  void _check() {
    final visible = _visible;
    if (visible == _shown) return;
    _shown = visible;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _content?.addListener(_check);
    _shown = _visible;
  }

  @override
  void detach() {
    _content?.removeListener(_check);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_shown) super.paint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _shown && super.hitTestChildren(result, position: position);
}

/// Full-bleed, heavily blurred artwork under a scrim, cross-fading between
/// tracks. The image is decoded tiny and blurred once per track into a
/// bitmap that is kept for the last few tracks, so reopening Now Playing
/// shows it on the very first frame. Cross-fades paint the image with an
/// alpha instead of fading a layer.
///
/// The colours flow like a liquid: copies of the bitmap drift and turn
/// slowly over one another ([ArtworkFlowPainter]), on a 36 s loop. Still with
/// Animations off and while the app is hidden. It flows in Performance mode
/// too: it only redraws a tiny bitmap three times a step, at [FlowClock]'s
/// pace.
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
    with TickerProviderStateMixin {
  _BitmapImage? _shown;

  /// The previous image, under [_shown] while it fades in.
  _BitmapImage? _previous;
  String? _requested;
  bool _started = false;

  late final AnimationController _fade = AnimationController(
    vsync: this,
    value: 1,
  )..addStatusListener(_faded);

  /// One loop of the flow; every motion in it turns a whole number of
  /// times per loop, so it never jumps.
  late final _flow = FlowClock(
    period: const Duration(seconds: 36),
    // Each step repaints the whole page: a phone's GPU gets fewer. The
    // motion is slow enough not to show it.
    fps: FormFactor.touch ? 10 : 30,
  );
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: (_) => _syncFlow());
  }

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
    _syncFlow();
  }

  @override
  void didUpdateWidget(_ArtworkBackdrop old) {
    super.didUpdateWidget(old);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _flow.dispose();
    _fade.dispose();
    super.dispose();
  }

  /// Flows while there is artwork, motion is wanted and the app is shown.
  void _syncFlow() {
    final fx = NoirEffects.of(context);
    final state = SchedulerBinding.instance.lifecycleState;
    final visible =
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached;
    final run =
        NowPlayingScreen.flowEnabled &&
        fx.animations &&
        visible &&
        (_shown != null || _previous != null);
    if (run) {
      _flow.start();
    } else {
      _flow.stop();
    }
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
    _syncFlow();
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
      return _BitmapImage(
        await blurArtwork(info.image, width: _blurSize, sigma: _sigma),
      );
    } finally {
      info.dispose();
    }
  }

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
          if (art)
            // Its own layer: only the flow repaints each frame.
            RepaintBoundary(
              child: CustomPaint(
                key: NowPlayingScreen.flowKey,
                painter: ArtworkFlowPainter(
                  shown: shown?.image,
                  previous: previous?.image,
                  fade: _fade,
                  flow: _flow,
                ),
              ),
            ),
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
    final lyricsMode = ref.watch(settingsProvider.select((s) => s.lyricsMode));
    // The shell's title bar geometry, so the window dots don't move when
    // the page opens; the More button shares their line.
    return WindowDragArea(
      child: SizedBox(
        height: TitleBarMetrics.height,
        child: Padding(
          padding: TitleBarMetrics.padding.copyWith(left: 12),
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
              // Phones keep the player to playback; everything in this
              // menu is a long-press away elsewhere.
              if (track != null && !FormFactor.touch)
                LiquidPress(
                  child: PopupMenuButton<String>(
                    tooltip: 'More',
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      color: context.noir.textSecondary,
                    ),
                    onSelected: (v) async {
                      for (final mode in LyricsMode.values) {
                        if (v == 'lyrics ${mode.name}') {
                          ref
                              .read(settingsProvider.notifier)
                              .update((s) => s.copyWith(lyricsMode: mode));
                        }
                      }
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
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        enabled: false,
                        height: 32,
                        child: Text(
                          'Lyrics style',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: context.noir.textTertiary),
                        ),
                      ),
                      for (final (mode, label) in const [
                        (LyricsMode.lines, 'Lines'),
                        (LyricsMode.karaoke, 'Karaoke'),
                      ])
                        CheckedPopupMenuItem(
                          value: 'lyrics ${mode.name}',
                          checked: lyricsMode == mode,
                          child: Text(label),
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
    final video = state.showsVideoPlayer && !hidePlayer;
    // Lyrics replace the cover on narrow windows. It stays mounted under
    // them, so hiding the lyrics doesn't build and decode it again; it
    // only stops taking taps.
    final cover = wide || lyrics.value < 1 || lyrics.status.isAnimating;
    final art = _Stage.coverSize(box, wide: wide);
    final lyricFont = lyricsFontSizeFor(box.maxWidth, box.maxHeight);

    Widget details(double large) =>
        _TrackDetails(state: state, large: large, centered: large);

    return SmoothScroll(
      builder: (context, scroll) => SingleChildScrollView(
        controller: scroll,
        child: _Stage(
          lyrics: lyrics,
          wide: wide,
          viewport: box.maxHeight,
          anchorBottom: FormFactor.touch && !wide,
          detailsExtent: _TrackDetails.extentUnderCover(context, state),
          children: [
            _StageSlot(
              slot: _Slot.cover,
              // Hidden, it neither takes taps nor flies into the mini
              // player on close.
              child: HeroMode(
                enabled: cover,
                child: IgnorePointer(
                  ignoring: !cover,
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
            _StageSlot(
              slot: _Slot.controls,
              child: FormFactor.touch && !wide
                  ? TouchControls(width: max(0, box.maxWidth - 48))
                  : const ControlCapsule(),
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
                        ? _Lyrics(
                            track: track,
                            ready: lyricsReady,
                            fontSize: lyricFont,
                          )
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

enum _Slot { cover, details, progress, controls, video, lyrics }

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
    required this.detailsExtent,
    required super.children,
    this.anchorBottom = false,
  });

  final Animation<double> lyrics;
  final bool wide;
  final double viewport;

  /// Narrow layouts only: the details, progress and controls sit at the
  /// bottom of the screen, within thumb reach, as in phone music apps.
  final bool anchorBottom;

  /// The details' height under the cover (wide, without lyrics) at a
  /// width. The cover is sized from it rather than from the details as
  /// laid out, which glide with the lyrics and animate between tracks:
  /// so the cover never swells mid-glide.
  final double Function(double width) detailsExtent;

  /// The largest the cover gets, which its image is decoded for. A pixel
  /// to spare on wide windows: rounding must never make a YouTube cover's
  /// crop come out smaller than the cover drawn at its largest.
  static double coverSize(BoxConstraints box, {required bool wide}) => wide
      ? max(
              wideCoverCap(box.maxWidth, box.maxHeight),
              lyricsCoverCap(box.maxWidth, box.maxHeight),
            ) +
            1
      : max<double>(160, min(box.maxWidth - 48, box.maxHeight * 0.45));

  /// The largest the cover gets on a wide window without lyrics; the
  /// height may make it smaller.
  static double wideCoverCap(double width, double height) =>
      min(min(460, width * 0.42), max(200, height * 0.62));

  /// The largest the cover gets beside lyrics; it grows with the window,
  /// to about two thirds of its height as in Apple Music.
  static double lyricsCoverCap(double width, double height) =>
      min(width * 0.33, height * 0.64).clamp(260.0, 760.0);

  @override
  _RenderStage createRenderObject(BuildContext context) => _RenderStage(
    lyrics,
    detailsExtent,
    wide: wide,
    viewport: viewport,
    anchorBottom: anchorBottom,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderStage renderObject) {
    if (renderObject.wide != wide ||
        renderObject.viewport != viewport ||
        renderObject.anchorBottom != anchorBottom) {
      renderObject
        ..wide = wide
        ..viewport = viewport
        ..anchorBottom = anchorBottom
        ..markNeedsLayout();
    }
    renderObject
      ..lyrics = lyrics
      ..detailsExtent = detailsExtent;
  }
}

class _RenderStage extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _StageParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _StageParentData> {
  _RenderStage(
    this._lyrics,
    this._detailsExtent, {
    required this.wide,
    required this.viewport,
    required this.anchorBottom,
  });

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
  bool anchorBottom;

  double Function(double width) get detailsExtent => _detailsExtent;
  double Function(double width) _detailsExtent;
  set detailsExtent(double Function(double width) value) {
    _detailsExtent = value;
    // Only the cover without lyrics depends on it.
    if (wide) markNeedsLayout();
  }

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

    // The controls keep their natural size, shrunk only to fit a column.
    final controls = measure(_Slot.controls, double.infinity);

    double height;
    if (wide) {
      // With lyrics: the player column hugs the left edge and grows with
      // the window, its cover sizing everything in it; the lyrics take the
      // rest up to a matching right margin. Nothing is capped, so large
      // windows don't leave empty bands at the edges.
      final marginB = max<double>(40, w * 0.06);
      final hasVideo = c[_Slot.video] != null;
      // The cover shrinks only if the column wouldn't fit the height.
      final restB =
          24 +
          _detailsExtent(_Stage.lyricsCoverCap(w, h)) +
          16 +
          measure(_Slot.progress, 300).height +
          16 +
          controls.height +
          (hasVideo ? 20 + YouTubeVideoLayer.miniSize.height : 0);
      final artB = min(
        _Stage.lyricsCoverCap(w, h),
        max<double>(200, h - 32 - restB),
      );
      final colB = artB;
      // The player sits centred in the left half (nudged towards the
      // middle), the lyrics start just past it.
      final xB = max(marginB, (w / 2 - artB) / 2 + w * 0.025);

      // Without lyrics: one centered column — cover, details, progress,
      // the controls (and the video) — the cover sized so it all
      // fits the height, the progress bar as wide as the cover (within
      // readable bounds). The details are laid out at a width that depends
      // on the window only (laying them out twice would restart their
      // AnimatedSize); centered, that width doesn't show.
      final capA = _Stage.wideCoverCap(w, h);
      double columnFor(double art) =>
          min(max(art, 360), max<double>(0, w - 96));
      final textA = columnFor(capA);
      final details = measure(_Slot.details, _lerp(textA, colB, t));
      final video = measure(_Slot.video, _lerp(textA, colB, t));
      final detailsA = _detailsExtent(textA);
      final rest =
          28 +
          detailsA +
          16 +
          measure(_Slot.progress, textA).height +
          20 +
          controls.height +
          (hasVideo ? 20 + video.height : 0);
      final artA = min(capA, max(min<double>(160, capA), h - 48 - rest));
      final colA = columnFor(artA);
      final progress = measure(_Slot.progress, _lerp(colA, colB, t));

      final totalA = artA + rest - detailsA + details.height;
      final yA = max<double>(16, (h - totalA) / 2);
      final coverA = Rect.fromLTWH((w - artA) / 2, yA, artA, artA);
      final detailsAt = Offset((w - textA) / 2, coverA.bottom + 28);
      final progressA = Offset(
        (w - colA) / 2,
        detailsAt.dy + details.height + 16,
      );
      final controlsA = Offset(
        (w - controls.width) / 2,
        progressA.dy + progress.height + 20,
      );
      final videoA = Offset(
        (w - video.width) / 2,
        controlsA.dy + controls.height + 20,
      );
      final heightA = yA + totalA + 16;

      // With lyrics.
      final cScale = min<double>(1, colB / max<double>(1, controls.width));
      final totalB =
          artB +
          24 +
          details.height +
          16 +
          progress.height +
          16 +
          controls.height * cScale +
          (hasVideo ? 20 + video.height : 0);
      final yB = max<double>(8, (h - totalB) / 2);
      final coverB = Rect.fromLTWH(xB, yB, artB, artB);
      final detailsB = Offset(xB, coverB.bottom + 24);
      final progressB = detailsB.translate(0, details.height + 16);
      final controlsB = Offset(
        xB + (colB - controls.width * cScale) / 2,
        progressB.dy + progress.height + 16,
      );
      final videoB = Offset(xB, controlsB.dy + controls.height * cScale + 20);
      final heightB = max(h, yB + totalB + 24);

      placeTight(_Slot.cover, Rect.lerp(coverA, coverB, t)!);
      place(_Slot.details, Offset.lerp(detailsAt, detailsB, t)!);
      place(_Slot.progress, Offset.lerp(progressA, progressB, t)!);
      place(_Slot.video, Offset.lerp(videoA, videoB, t)!);
      place(
        _Slot.controls,
        Offset.lerp(controlsA, controlsB, t)!,
        scale: _lerp(1, cScale, t),
      );
      // The lyrics start just past the middle (further when the player
      // reaches it) and keep a wide right margin, so lines wrap at a
      // readable length.
      final lyricsFrom = max(xB + colB + max<double>(56, w * 0.06), w * 0.515);
      final lyricsTo = w - max(marginB, w * 0.1);
      // Lyrics slide in from a little to the right as they fade in.
      placeTight(
        _Slot.lyrics,
        Rect.fromLTWH(
          lyricsFrom + (1 - t) * 48,
          8,
          max(0, lyricsTo - lyricsFrom),
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
      final cScale = min<double>(1, cw / max<double>(1, controls.width));

      // The lyrics take the cover's place; everything below follows.
      const top = 16.0;
      final below =
          details.height +
          20 +
          progress.height +
          20 +
          controls.height * cScale +
          (hasVideo ? 24 + video.height : 0);
      // At the bottom when anchored; the lyrics then fill the room above.
      final lowest = anchorBottom ? h - 32 - below : 0.0;
      final lyricsTall = max(lyricsHeight, lowest - 16 - top);
      placeTight(_Slot.cover, Rect.fromLTWH((w - art) / 2, top, art, art));
      placeTight(_Slot.lyrics, Rect.fromLTWH(x, top, cw, lyricsTall));
      var y = max(top + _lerp(art, lyricsTall, t) + _lerp(28, 16, t), lowest);
      place(_Slot.details, Offset(x, y));
      y += details.height + 20;
      place(_Slot.progress, Offset(x, y));
      y += progress.height + 20;
      place(
        _Slot.controls,
        Offset((w - controls.width * cScale) / 2, y),
        scale: cScale,
      );
      y += controls.height * cScale;
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

/// The transport, lyrics and queue buttons, sized by the layout that
/// places them. A control the engine can't offer is null.
typedef _Buttons = ({
  Widget? shuffle,
  Widget? previous,
  Widget play,
  Widget? next,
  Widget? repeat,
  Widget lyrics,
  Widget queue,
});

_Buttons _buttons(
  BuildContext context,
  WidgetRef ref, {
  double icon = 20,
  double skip = 24,
  double play = 48,
}) {
  final s = ref.watch(playbackProvider);
  final ctrl = ref.read(playbackProvider.notifier);
  final caps = s.capabilities;
  final hasItem = s.current != null;
  final lyrics = ref.watch(lyricsVisibleProvider);
  final queueOpen = ref.watch(queueSheetOpenProvider);
  final c = context.noir;
  return (
    shuffle: caps.canShuffle
        ? NoirIconButton(
            icon: Icons.shuffle_rounded,
            tooltip: s.shuffle ? 'Shuffle on' : 'Shuffle off',
            size: icon,
            active: s.shuffle,
            onPressed: hasItem ? ctrl.toggleShuffle : null,
          )
        : null,
    previous: caps.canSkip
        ? NoirIconButton(
            icon: Icons.skip_previous_rounded,
            tooltip: 'Previous',
            size: skip,
            color: c.textPrimary,
            onPressed: hasItem ? () => unawaited(ctrl.previous()) : null,
          )
        : null,
    play: PrimaryPlayButton(
      playing: s.isPlaying,
      size: play,
      onPressed: hasItem ? () => unawaited(ctrl.togglePlayPause()) : null,
    ),
    next: caps.canSkip
        ? NoirIconButton(
            icon: Icons.skip_next_rounded,
            tooltip: 'Next',
            size: skip,
            color: c.textPrimary,
            onPressed: s.hasNext ? () => unawaited(ctrl.next()) : null,
          )
        : null,
    repeat: caps.canRepeat
        ? NoirIconButton(
            icon: s.repeat == RepeatMode.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            tooltip: switch (s.repeat) {
              RepeatMode.off => 'Repeat off',
              RepeatMode.all => 'Repeat all',
              RepeatMode.one => 'Repeat one',
            },
            size: icon,
            active: s.repeat != RepeatMode.off,
            onPressed: hasItem ? ctrl.cycleRepeat : null,
          )
        : null,
    lyrics: NoirIconButton(
      icon: Icons.format_quote_rounded,
      tooltip: lyrics ? 'Hide lyrics' : 'Show lyrics',
      size: icon,
      active: lyrics,
      onPressed: ref.read(lyricsVisibleProvider.notifier).toggle,
    ),
    queue: NoirIconButton(
      icon: Icons.queue_music_rounded,
      tooltip: 'Queue',
      size: icon,
      active: queueOpen,
      onPressed: () => unawaited(showQueueSheet(context, ref)),
    ),
  );
}

/// Every control in one Liquid Glass capsule: shuffle · previous ·
/// play/pause · next · repeat | lyrics · queue · volume.
class ControlCapsule extends ConsumerWidget {
  const ControlCapsule({super.key});

  /// The capsule's glass, for tests.
  static const glassKey = ValueKey('now-playing-capsule');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = _buttons(context, ref);
    final c = context.noir;
    const gap = SizedBox(width: NoirSpacing.xs);
    return GlassSurface(
      key: glassKey,
      borderRadius: NoirRadii.pillAll,
      interactive: true,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (b.shuffle case final shuffle?) ...[shuffle, gap],
          if (b.previous case final previous?) ...[previous, gap],
          b.play,
          if (b.next case final next?) ...[gap, next],
          if (b.repeat case final repeat?) ...[gap, repeat],
          gap,
          const MixModeButton(),
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: NoirSpacing.sm),
            color: c.textTertiary.withValues(alpha: 0.35),
          ),
          b.lyrics,
          gap,
          b.queue,
          gap,
          // Last, its slider always shown: a capsule that grew and shrank
          // under the pointer kept jumping.
          const VolumeControl(),
        ],
      ),
    );
  }
}

/// The controls on a phone, as phone music apps lay them out: the
/// transport spread across the column around a large play button, and
/// lyrics · mix · queue in a quieter row under it. No volume: the phone's
/// own buttons do that.
class TouchControls extends ConsumerWidget {
  const TouchControls({required this.width, super.key});

  /// The column's width; the rows spread across it.
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = _buttons(context, ref, icon: 24, skip: 38, play: 68);
    // Keeps the rest in place when the engine can't offer a control.
    const none = SizedBox.square(dimension: 40);
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              b.shuffle ?? none,
              b.previous ?? none,
              b.play,
              b.next ?? none,
              b.repeat ?? none,
            ],
          ),
          const SizedBox(height: NoirSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [b.lyrics, const MixModeButton(size: 24), b.queue],
          ),
        ],
      ),
    );
  }
}

/// The big cover. A tap plays or pauses. As in Apple Music it sits a little
/// smaller while paused and springs back to full size on play, and a tap
/// flashes the new state's glyph over it.
class _LargeArtwork extends ConsumerStatefulWidget {
  const _LargeArtwork({required this.state, required this.size});

  final PlaybackState state;

  /// The size its image is decoded for; the layout may draw it smaller.
  final double size;

  /// Cover scale while paused.
  static const pausedScale = 0.9;

  @override
  ConsumerState<_LargeArtwork> createState() => _LargeArtworkState();
}

class _LargeArtworkState extends ConsumerState<_LargeArtwork>
    with TickerProviderStateMixin {
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  /// Glyph of the state a tap switched to.
  bool _flashPlaying = false;

  /// Phones: how far the cover is dragged sideways; let go, it glides back
  /// (and the track changes if it went far or fast enough).
  final _dx = ValueNotifier<double>(0);
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  double _settleFrom = 0;

  @override
  void initState() {
    super.initState();
    _settle.addListener(
      () => _dx.value =
          _settleFrom * (1 - Curves.easeOutCubic.transform(_settle.value)),
    );
  }

  @override
  void dispose() {
    _flash.dispose();
    _settle.dispose();
    _dx.dispose();
    super.dispose();
  }

  void _dragBy(double dx) {
    _settle.stop();
    final limit = widget.size * 0.6;
    _dx.value = (_dx.value + dx).clamp(-limit, limit);
  }

  /// Left goes to the next song, right to the previous one.
  void _dragEnd(double velocity) {
    final ctrl = ref.read(playbackProvider.notifier);
    final far = widget.size * 0.25;
    if (_dx.value < -far || velocity < -600) {
      if (widget.state.hasNext) unawaited(ctrl.next());
    } else if (_dx.value > far || velocity > 600) {
      unawaited(ctrl.previous());
    }
    _settleFrom = _dx.value;
    _settle.forward(from: 0);
  }

  void _toggle() {
    final playing = widget.state.status == PlaybackStatus.playing;
    unawaited(ref.read(playbackProvider.notifier).togglePlayPause());
    setState(() => _flashPlaying = !playing);
    if (NoirEffects.of(context).animations) _flash.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.state.current!.track;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fx = NoirEffects.of(context);
    final paused = widget.state.status == PlaybackStatus.paused;
    final cover = DecoratedBox(
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
          child: _CoverSwitcher(track: track, size: widget.size),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: paused ? 'Play' : 'Pause',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _toggle,
          onHorizontalDragUpdate: FormFactor.touch
              ? (d) => _dragBy(d.delta.dx)
              : null,
          onHorizontalDragEnd: FormFactor.touch
              ? (d) => _dragEnd(d.velocity.pixelsPerSecond.dx)
              : null,
          onHorizontalDragCancel: FormFactor.touch ? () => _dragEnd(0) : null,
          child: AnimatedScale(
            scale: paused ? _LargeArtwork.pausedScale : 1,
            duration: fx.motion(const Duration(milliseconds: 550)),
            // A slight overshoot: the cover springs back when playing.
            curve: paused ? Curves.easeOutCubic : Curves.easeOutBack,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: _dx,
                  child: cover,
                  builder: (context, dx, cover) =>
                      Transform.translate(offset: Offset(dx, 0), child: cover),
                ),
                _PlayPauseFlash(
                  animation: _flash,
                  playing: _flashPlaying,
                  size: widget.size,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The play or pause glyph in a frosted disc, popping in and fading out
/// over the cover after a tap.
class _PlayPauseFlash extends StatelessWidget {
  const _PlayPauseFlash({
    required this.animation,
    required this.playing,
    required this.size,
  });

  final Animation<double> animation;
  final bool playing;
  final double size;

  @override
  Widget build(BuildContext context) {
    final disc = (size * 0.22).clamp(64.0, 120.0);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = animation.value;
          if (t == 0 || t == 1) return const SizedBox.shrink();
          // In fast, hold, then out.
          final opacity = t < 0.2
              ? t / 0.2
              : t < 0.55
              ? 1.0
              : 1 - (t - 0.55) / 0.45;
          final scale =
              0.7 + 0.3 * Curves.easeOutBack.transform(min(1, t / 0.3));
          return Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.scale(scale: scale, child: child),
          );
        },
        child: Container(
          width: disc,
          height: disc,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.38),
          ),
          child: Icon(
            playing ? Icons.play_arrow_rounded : Icons.pause_rounded,
            size: disc * 0.55,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// Title (with the save heart), artist and album. [large] runs from 0
/// (beside lyrics, narrow windows) to 1 (wide, under the cover) and sizes
/// the title between the two; [centered] runs from 0 (start-aligned) to 1
/// (centered under the cover), gliding each line between the two.
class _TrackDetails extends ConsumerWidget {
  const _TrackDetails({
    required this.state,
    required this.large,
    required this.centered,
  });

  final PlaybackState state;
  final double large;
  final double centered;

  /// About how tall the details are under the cover (large, centered) at
  /// a width, from text metrics alone.
  static double Function(double width) extentUnderCover(
    BuildContext context,
    PlaybackState state,
  ) {
    final track = state.current?.track;
    if (track == null) return (_) => 0;
    final t = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    double heightOf(
      String text,
      TextStyle? style,
      double maxWidth, {
      int? lines,
    }) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: lines,
        ellipsis: lines == null ? null : '…',
      )..layout(maxWidth: max(0, maxWidth));
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final album = track.album;
    return (width) =>
        // Room for a save button on either side of the title.
        heightOf(track.title, t.displaySmall, width - 2 * 48, lines: 2) +
        6 +
        heightOf(track.artistOrUnknown, t.titleMedium, width) +
        (album == null ? 0 : 4 + heightOf(album, t.bodyLarge, width));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    final track = state.current!.track;
    final failed =
        state.status == PlaybackStatus.error ||
        state.status == PlaybackStatus.unavailable;
    final align = Alignment.lerp(
      Alignment.centerLeft,
      Alignment.center,
      centered,
    )!;
    final textAlign = centered >= 0.5 ? TextAlign.center : TextAlign.start;
    final buttons = [
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
      if (track.source == MediaSource.youtube) ...[
        DislikeButton(track, size: 22),
        YouTubeSaveButton(track, size: 22),
      ],
    ];
    Widget line(Widget child) => Align(alignment: align, child: child);
    // While a mix blends into this track: "Mixing into" over its title,
    // then the usual details once the mix is done.
    final mixing = ref.watch(
      transitionStatusProvider.select(
        (s) =>
            s != null &&
            s.isMixing &&
            s.progress < 1 &&
            s.plan.seconds >= 1 &&
            s.from != null &&
            s.from!.id != track.id,
      ),
    );
    final title = Text(
      track.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
      style: TextStyle.lerp(t.headlineSmall, t.displaySmall, large),
    );
    final mixingDetails = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        line(
          Text(
            'MIXING INTO',
            style: t.labelSmall?.copyWith(
              color: c.textSecondary,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.6,
            ),
          ),
        ),
        const SizedBox(height: 6),
        _TitleRow(
          centered: centered,
          children: [
            title,
            Row(mainAxisSize: MainAxisSize.min, children: buttons),
          ],
        ),
      ],
    );
    final normalDetails = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _TitleRow(
          centered: centered,
          children: [
            title,
            Row(mainAxisSize: MainAxisSize.min, children: buttons),
          ],
        ),
        const SizedBox(height: 6),
        line(
          _ArtistLine(
            track: track,
            textAlign: textAlign,
            style: t.titleMedium?.copyWith(
              color: c.textSecondary,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        line(
          _AlbumLine(
            track: track,
            textAlign: textAlign,
            style: t.bodyLarge?.copyWith(color: c.textTertiary),
          ),
        ),
      ],
    );
    // While mixing, the usual details stay laid out (unseen) underneath,
    // so the block keeps its height and the cover above never moves.
    final details = mixing
        ? Stack(
            alignment: Alignment.topCenter,
            children: [
              ExcludeSemantics(
                child: Visibility.maintain(
                  visible: false,
                  child: normalDetails,
                ),
              ),
              mixingDetails,
            ],
          )
        : normalDetails;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _TrackChange(
          trackId: mixing ? 'mixing ${track.id}' : track.id,
          child: details,
        ),
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

/// The title and, after it, the save buttons. Start-aligned ([centered]
/// 0) the title starts the row and the buttons end it; centered (1) the
/// title is centered and the buttons follow it, as much space kept before
/// the title as they take after it.
class _TitleRow extends MultiChildRenderObjectWidget {
  const _TitleRow({required this.centered, required super.children});

  final double centered;

  @override
  _RenderTitleRow createRenderObject(BuildContext context) =>
      _RenderTitleRow(centered);

  @override
  void updateRenderObject(BuildContext context, _RenderTitleRow row) =>
      row.centered = centered;
}

class _RenderTitleRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, MultiChildLayoutParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, MultiChildLayoutParentData> {
  _RenderTitleRow(this._centered);

  double get centered => _centered;
  double _centered;
  set centered(double value) {
    if (value == _centered) return;
    _centered = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MultiChildLayoutParentData) {
      child.parentData = MultiChildLayoutParentData();
    }
  }

  @override
  void performLayout() {
    final title = firstChild!;
    final buttons = childAfter(title)!;
    final w = constraints.maxWidth;
    buttons.layout(BoxConstraints(maxWidth: w), parentUsesSize: true);
    final b = buttons.size.width;
    final c = _centered.clamp(0.0, 1.0);
    title.layout(
      BoxConstraints(maxWidth: max(0, w - b - b * c)),
      parentUsesSize: true,
    );
    final tw = title.size.width;
    final h = max(title.size.height, buttons.size.height);
    (title.parentData! as MultiChildLayoutParentData).offset = Offset(
      c * (w - tw) / 2,
      (h - title.size.height) / 2,
    );
    (buttons.parentData! as MultiChildLayoutParentData).offset = Offset(
      w - b + c * ((w + tw) / 2 - (w - b)),
      (h - buttons.size.height) / 2,
    );
    size = constraints.constrain(Size(w, h));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
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

  /// One key per cover on screen, so a cover moving between the switcher
  /// and a melt keeps its state and image instead of loading again.
  final _coverKeys = <String, GlobalKey>{};

  /// The cover of [track]; [copy] is a second, unkeyed one (for a melt's
  /// blurred layer) that screen readers skip.
  Widget _cover(Track track, {bool copy = false}) {
    final size = widget.size;
    final key = copy ? null : _coverKeys[track.id] ??= GlobalKey();
    final cover = track.source == MediaSource.youtube
        ? YouTubeCover(
            key: key,
            videoId: track.uri,
            size: size,
            semanticLabel: copy ? null : 'Cover art',
          )
        : Artwork(
            key: key,
            path: track.artwork,
            size: size,
            radius: NoirRadii.xl,
            semanticLabel: copy
                ? null
                : 'Artwork for ${track.album ?? track.title}',
          );
    return copy ? ExcludeSemantics(child: cover) : cover;
  }

  @override
  Widget build(BuildContext context) {
    final incoming = widget.track;
    final mix = ref.watch(
      transitionStatusProvider.select(
        (s) =>
            s != null &&
                s.isMixing &&
                s.progress < 1 &&
                s.plan.seconds >= 1 &&
                s.from != null &&
                s.from!.id != incoming.id
            ? (from: s.from!, progress: s.progress, seconds: s.plan.seconds)
            : null,
      ),
    );
    final melt = NoirEffects.of(context).animations ? mix : null;
    _coverKeys.removeWhere(
      (id, _) => id != _shown.id && id != incoming.id && id != melt?.from.id,
    );
    if (melt != null) {
      return _Melt(
        from: _cover(melt.from),
        to: _cover(incoming),
        fromBlurred: _cover(melt.from, copy: true),
        toBlurred: _cover(incoming, copy: true),
        progress: melt.progress,
        seconds: melt.seconds,
      );
    }
    final track = _shown;
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
      child: KeyedSubtree(key: key, child: _cover(track)),
    );
  }
}

/// A mix between two tracks on the cover: the outgoing one blurs, swells
/// and fades away while the incoming one comes into focus, following the
/// blend's [progress] (0–1). The player reports progress only a few times
/// a second and with some jitter, so the melt runs on at the blend's own
/// pace ([seconds] long) and the reports only steer it gently, never
/// backwards.
class _Melt extends StatefulWidget {
  const _Melt({
    required this.from,
    required this.to,
    required this.fromBlurred,
    required this.toBlurred,
    required this.progress,
    required this.seconds,
  });

  final Widget from;
  final Widget to;

  /// Second copies of the covers, for the blurred layers.
  final Widget fromBlurred;
  final Widget toBlurred;
  final double progress;
  final double seconds;

  /// The blur, as a Gaussian sigma. It never changes: a changing blur
  /// steps visibly (the renderer rounds its kernel to whole pixels), so
  /// the cover fades between itself and a blurred copy instead.
  static const sigma = 18.0;

  @override
  State<_Melt> createState() => _MeltState();
}

class _MeltState extends State<_Melt> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late double _reported = widget.progress;
  late double _shown = widget.progress;
  Duration _now = Duration.zero;
  Duration _reportedAt = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void didUpdateWidget(_Melt old) {
    super.didUpdateWidget(old);
    if (widget.progress == old.progress) return;
    if (widget.progress < _reported - 0.2) _shown = widget.progress;
    _reported = widget.progress;
    _reportedAt = _now;
  }

  /// Seconds over which a gap between the melt and the reports closes.
  static const _steer = 0.5;

  void _tick(Duration elapsed) {
    final dt = (elapsed - _now).inMicroseconds / 1e6;
    _now = elapsed;
    final rate = 1 / max(widget.seconds, 1);
    // Where the last report puts the blend by now.
    final target = min<double>(
      1,
      _reported + (elapsed - _reportedAt).inMicroseconds / 1e6 * rate,
    );
    final step = dt * rate + (target - _shown) * min<double>(1, dt / _steer);
    final next = min<double>(1, _shown + max<double>(0, step));
    if (next != _shown) setState(() => _shown = next);
    if (next >= 1) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// The melt's position at 0, 1/32, 2/32, … of the blend, measured on
  /// rendered frames so the picture changes at an even pace (easing in and
  /// out over the first and last few percent) instead of mostly early on.
  static const _evenSteps = [
    0.0, 0.0009, 0.0105, 0.0277, 0.0417, 0.0559, 0.0704, 0.0845, 0.1025, //
    0.1212, 0.1405, 0.1622, 0.186, 0.2089, 0.2306, 0.2569, 0.286, //
    0.3194, 0.3543, 0.389, 0.4308, 0.479, 0.5284, 0.5803, 0.6333, //
    0.6898, 0.7446, 0.7995, 0.8576, 0.907, 0.9492, 0.9922, 1.0,
  ];

  /// How far into the melt the picture is [t] (0–1) through the blend.
  static double _pace(double t) {
    final x = t.clamp(0.0, 1.0) * (_evenSteps.length - 1);
    final i = min(x.floor(), _evenSteps.length - 2);
    final from = _evenSteps[i];
    return from + (_evenSteps[i + 1] - from) * (x - i);
  }

  /// A cover [focus] sharp (1) to fully blurred (0): the sharp cover
  /// fades out over its blurred copy, which comes in a little ahead so
  /// the two barely thin out in between. Both stay in the tree for the
  /// whole mix.
  static Widget _layer(
    Widget sharp,
    Widget blurred, {
    required double focus,
    required double scale,
    required double opacity,
  }) => Opacity(
    opacity: opacity.clamp(0.0, 1.0),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Opacity(
          opacity: (1 - pow(focus.clamp(0.0, 1.0), 1.5)).toDouble(),
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: _Melt.sigma,
              sigmaY: _Melt.sigma,
              tileMode: TileMode.decal,
            ),
            // Scaled inside the filter, so the blur itself stays fixed.
            child: Transform.scale(scale: scale, child: blurred),
          ),
        ),
        Opacity(
          opacity: focus.clamp(0.0, 1.0),
          child: Transform.scale(scale: scale, child: sharp),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = _pace(_shown.clamp(0.0, 1.0));
    return Stack(
      alignment: Alignment.center,
      children: [
        _layer(
          widget.from,
          widget.fromBlurred,
          focus: 1 - p,
          scale: 1 + 0.06 * p,
          opacity: 1 - p * p,
        ),
        _layer(
          widget.to,
          widget.toBlurred,
          focus: p,
          scale: 0.95 + 0.05 * p,
          opacity: 1 - (1 - p) * (1 - p),
        ),
      ],
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
    this.fontSize,
  });

  final Track track;
  final bool ready;
  final bool compact;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: NoirEffects.of(context).motion(NoirMotion.slow),
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: ready
          ? LyricsView(
              key: ValueKey(track.id),
              track: track,
              compact: compact,
              fontSize: fontSize,
            )
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
  const _ArtistLine({
    required this.track,
    required this.style,
    required this.textAlign,
  });

  final Track track;
  final TextStyle? style;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = track.source == MediaSource.youtube
        ? ref.watch(ytmTrackLinksProvider(track.uri))
        : null;
    final artists = _artistsOf(track, links);
    if (artists.isEmpty) {
      return Text(track.artistOrUnknown, style: style, textAlign: textAlign);
    }
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
    return _LinkedText(pieces, style: style, textAlign: textAlign);
  }
}

/// The album name, opening the album page once known; nothing when the
/// track names no album.
class _AlbumLine extends ConsumerWidget {
  const _AlbumLine({
    required this.track,
    required this.style,
    required this.textAlign,
  });

  final Track track;
  final TextStyle? style;
  final TextAlign textAlign;

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
      child: _LinkedText(
        [
          (
            text: text,
            onTap: album == null
                ? null
                : () => unawaited(album.open(context, ref)),
          ),
        ],
        style: style,
        textAlign: textAlign,
      ),
    );
  }
}

typedef _Piece = ({String text, VoidCallback? onTap});

/// Text whose tappable pieces show a pointer and an underline on hover.
class _LinkedText extends StatefulWidget {
  const _LinkedText(this.pieces, {required this.style, this.textAlign});

  final List<_Piece> pieces;
  final TextStyle? style;
  final TextAlign? textAlign;

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
      textAlign: widget.textAlign,
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
