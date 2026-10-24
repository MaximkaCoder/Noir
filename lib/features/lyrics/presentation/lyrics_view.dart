import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/lyrics/application/lyrics_providers.dart';
import 'package:noir/features/lyrics/domain/lrc.dart';
import 'package:noir/features/lyrics/domain/lyrics.dart';
import 'package:noir/features/lyrics/presentation/karaoke_lyrics.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

/// Lyrics for [track]: time-synced lines that follow playback (as a list,
/// or karaoke — see [LyricsMode]), plain text, or a calm state explaining
/// why there are none. Where they come from is credited after the last
/// line.
class LyricsView extends ConsumerWidget {
  const LyricsView({required this.track, this.compact = false, super.key});

  final Track track;

  /// Smaller type for narrow windows.
  final bool compact;

  /// Shown above unsynced lyrics while Karaoke is chosen.
  static const noKaraokeNote = 'Not time-synced, so no karaoke';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = LyricsRequest.fromTrack(track);
    final lyrics = ref.watch(lyricsProvider(request));
    final mode = ref.watch(settingsProvider.select((s) => s.lyricsMode));
    final fx = NoirEffects.of(context);

    final child = lyrics.when(
      skipLoadingOnRefresh: false,
      loading: () => const Center(
        key: ValueKey('loading'),
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (_, _) => ErrorState(
        key: const ValueKey('error'),
        title: "Couldn't load lyrics",
        message: 'The lyrics service could not be reached.',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(lyricsProvider(request)),
        compact: true,
      ),
      data: (data) => switch (data) {
        null => const EmptyState(
          key: ValueKey('none'),
          icon: Icons.format_quote_rounded,
          title: 'No lyrics found',
          message: 'There are no lyrics for this song yet.',
          compact: true,
        ),
        InstrumentalLyrics() => const EmptyState(
          key: ValueKey('instrumental'),
          icon: Icons.music_note_rounded,
          title: 'Instrumental',
          message: 'This song has no lyrics.',
          compact: true,
        ),
        PlainLyrics(:final text, :final source) => _PlainLyrics(
          key: ValueKey(('plain', mode)),
          text: text,
          source: source,
          note: mode == LyricsMode.karaoke ? noKaraokeNote : null,
          compact: compact,
        ),
        SyncedLyrics(:final lines, :final source) => SyncedLyricsList(
          key: ValueKey((request, mode)),
          lines: lines,
          source: source,
          compact: compact,
          karaoke: mode == LyricsMode.karaoke,
        ),
      },
    );
    return AnimatedSwitcher(
      duration: fx.motion(NoirMotion.medium),
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: child,
    );
  }
}

/// "Lyrics from …", small and dim, after the last line.
class _Credit extends StatelessWidget {
  const _Credit(this.source);

  final String source;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NoirSpacing.sm,
      NoirSpacing.xl,
      NoirSpacing.sm,
      0,
    ),
    child: Text(
      'Lyrics from $source',
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: context.noir.textTertiary),
    ),
  );
}

/// Fades lines out toward the top and bottom edges.
Widget _edgeFade(Widget child) => ShaderMask(
  blendMode: BlendMode.dstIn,
  shaderCallback: (bounds) => const LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0x00000000),
      Color(0xFF000000),
      Color(0xFF000000),
      Color(0x00000000),
    ],
    stops: [0, 0.1, 0.88, 1],
  ).createShader(bounds),
  child: child,
);

/// Lyric type size for an area of [box]: large and bold, following the
/// window, within readable bounds.
double lyricsFontSize(BoxConstraints box, {required bool compact}) {
  final byWidth = box.maxWidth * 0.046;
  final byHeight = box.maxHeight * 0.055;
  final fit = byWidth < byHeight ? byWidth : byHeight;
  return compact ? fit.clamp(20.0, 30.0) : fit.clamp(26.0, 40.0);
}

class _PlainLyrics extends StatelessWidget {
  const _PlainLyrics({
    required this.text,
    required this.source,
    required this.note,
    required this.compact,
    super.key,
  });

  final String text;
  final String source;

  /// Shown above the text.
  final String? note;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final style = lyricLineStyle(context, compact ? 18 : 24).copyWith(
      color: context.noir.textPrimary.withValues(alpha: 0.8),
      height: 1.5,
      fontWeight: FontWeight.w600,
    );
    final note = this.note;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: _edgeFade(
        SmoothScroll(
          builder: (context, scroll) => SingleChildScrollView(
            controller: scroll,
            padding: const EdgeInsets.symmetric(vertical: NoirSpacing.xxxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: NoirSpacing.lg),
                    child: Text(
                      note,
                      style: Theme.of(context).textTheme.labelMedium
                          ?.copyWith(color: context.noir.textSecondary),
                    ),
                  ),
                Text(text.trim(), style: style),
                _Credit(source),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Time-synced lines. Only this widget listens to playback position, and it
/// rebuilds only when the active line changes.
///
/// In [karaoke] mode the line being sung is [karaokeScale] times larger and
/// fills word by word ([KaraokeRow]); moving to the next line, the old one
/// shrinks back and dims while the new one grows, and the list glides so
/// the new line reaches the anchor as the sizes settle. Between position
/// ticks only the fill repaints.
class SyncedLyricsList extends ConsumerStatefulWidget {
  const SyncedLyricsList({
    required this.lines,
    required this.source,
    this.compact = false,
    this.karaoke = false,
    super.key,
  });

  final List<LyricLine> lines;

  /// Credited after the last line.
  final String source;
  final bool compact;
  final bool karaoke;

  /// Where the active line rests, as a fraction of the viewport height.
  static const anchor = 0.38;

  /// How long manual scrolling pauses auto-follow.
  static const followPause = Duration(seconds: 3);

  /// Size of the line being sung in karaoke, relative to the others.
  static const karaokeScale = 1.3;

  /// How long karaoke takes to move on to the next line.
  static const karaokeChange = Duration(milliseconds: 450);

  @override
  ConsumerState<SyncedLyricsList> createState() => _SyncedLyricsListState();
}

class _SyncedLyricsListState extends ConsumerState<SyncedLyricsList>
    with TickerProviderStateMixin {
  final _scroll = SmoothScrollController();
  late List<GlobalKey> _keys;
  int _active = -1;
  bool _following = true;
  Timer? _resume;

  /// Karaoke: the interpolated position the fill and the active line follow.
  late final KaraokeClock _clock = KaraokeClock(this);

  /// Karaoke: carries the scroll along while line sizes change.
  late final AnimationController _glide = AnimationController(vsync: this)
    ..addListener(_glideStep)
    ..addStatusListener((status) {
      if (status.isCompleted) _revealAfterFrame();
    });
  double _glideFrom = 0;

  @override
  void initState() {
    super.initState();
    _keys = [for (final _ in widget.lines) GlobalKey()];
    final position = ref.read(playbackEngineProvider).currentPosition;
    _active = activeLineIndex(widget.lines, position);
    if (widget.karaoke) {
      _clock
        ..report(position)
        ..addListener(
          () => _setActive(activeLineIndex(widget.lines, _clock.value)),
        );
      ref.listenManual(
        playbackProvider.select((s) => s.status == PlaybackStatus.playing),
        (_, playing) => _runClock(playing: playing),
      );
    }
    ref.listenManual(positionProvider, (_, next) {
      final position = next.value;
      if (position == null) return;
      if (widget.karaoke) {
        _clock.report(position);
      } else {
        _setActive(activeLineIndex(widget.lines, position));
      }
    });
    _revealAfterFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Also when animations are switched on or off.
    if (widget.karaoke) {
      _runClock(
        playing: ref.read(playbackProvider).status == PlaybackStatus.playing,
      );
    }
  }

  /// With animations off the fill steps with the engine's ticks.
  void _runClock({required bool playing}) =>
      _clock.run(smooth: playing && NoirEffects.of(context).animations);

  @override
  void didUpdateWidget(SyncedLyricsList old) {
    super.didUpdateWidget(old);
    if (old.lines != widget.lines) {
      _keys = [for (final _ in widget.lines) GlobalKey()];
      _active = -1;
    }
  }

  @override
  void dispose() {
    _resume?.cancel();
    _glide.dispose();
    _clock.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _setActive(int index) {
    if (index == _active || !mounted) return;
    setState(() => _active = index);
    if (!_following) return;
    if (widget.karaoke) {
      _glideToActive();
    } else {
      _revealAfterFrame(animate: true);
    }
  }

  void _revealAfterFrame({bool animate = false}) => WidgetsBinding.instance
      .addPostFrameCallback((_) => _reveal(animate: animate));

  /// Karaoke: moves the list along with the changing line sizes, reaching
  /// the anchor for the new line's final size as they settle.
  void _glideToActive() {
    final duration = NoirEffects.of(context)
        .motion(SyncedLyricsList.karaokeChange);
    if (duration == Duration.zero || !_scroll.hasClients) {
      _revealAfterFrame();
      return;
    }
    _glideFrom = _scroll.position.pixels;
    _glide
      ..duration = duration
      ..forward(from: 0);
  }

  void _glideStep() {
    if (!_glide.isAnimating || !_scroll.hasClients) return;
    // From the last laid-out frame: the sizes keep changing, so the target
    // moves with them; the end of the glide lands on it exactly.
    final target = _anchorOffset();
    if (target == null) return;
    final t = NoirMotion.standard.transform(_glide.value);
    _scroll.position.jumpTo(_glideFrom + (target - _glideFrom) * t);
  }

  /// The scroll offset that puts the active line at the anchor.
  double? _anchorOffset() {
    if (!_scroll.hasClients || _keys.isEmpty) return null;
    final target = _keys[_active.clamp(0, _keys.length - 1)].currentContext
        ?.findRenderObject();
    if (target == null || !target.attached) return null;
    final viewport = RenderAbstractViewport.maybeOf(target);
    if (viewport == null) return null;
    final position = _scroll.position;
    return viewport
        .getOffsetToReveal(target, SyncedLyricsList.anchor)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  /// Scrolls the active line to [SyncedLyricsList.anchor]. Only this list
  /// scrolls, never the page around it.
  void _reveal({bool animate = true}) {
    if (!mounted) return;
    final offset = _anchorOffset();
    if (offset == null) return;
    final position = _scroll.position;
    final duration = animate
        ? NoirEffects.of(context).motion(NoirMotion.slow * 2)
        : Duration.zero;
    if (duration == Duration.zero) {
      position.jumpTo(offset);
    } else {
      unawaited(
        position.animateTo(
          offset,
          duration: duration,
          curve: NoirMotion.emphasized,
        ),
      );
    }
  }

  void _pauseFollow() {
    _following = false;
    _glide.stop();
    _resume?.cancel();
    _resume = Timer(SyncedLyricsList.followPause, () {
      _following = true;
      _reveal();
    });
  }

  void _seekTo(int index) {
    _resume?.cancel();
    _following = true;
    unawaited(
      ref.read(playbackProvider.notifier).seek(widget.lines[index].time),
    );
    _setActive(index);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    final canSeek = ref.watch(
      playbackProvider.select((s) => s.capabilities.canSeek),
    );
    _scroll.smooth = fx.animations;

    Widget? karaokeRow(int i, TextStyle base) => !widget.karaoke
        ? null
        : KaraokeRow(
            text: widget.lines[i].text,
            active: i == _active,
            words: () => lineWordTimings(widget.lines, i),
            position: _clock,
            style: base,
            lit: c.textPrimary,
            unlit: c.textPrimary.withValues(alpha: _futureAlpha),
            rest: c.textPrimary.withValues(
              alpha: i < _active ? _pastAlpha : _futureAlpha,
            ),
            activeScale: SyncedLyricsList.karaokeScale,
            restScale: 1,
            duration: fx.motion(SyncedLyricsList.karaokeChange),
          );

    return LayoutBuilder(
      builder: (context, box) {
        final size = lyricsFontSize(box, compact: widget.compact);
        final base = lyricLineStyle(context, size);
        return Listener(
          // Wheel and trackpad scrolling don't send drag notifications.
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) _pauseFollow();
          },
          onPointerPanZoomStart: (_) => _pauseFollow(),
          child: NotificationListener<ScrollStartNotification>(
            onNotification: (n) {
              if (n.dragDetails != null) _pauseFollow();
              return false;
            },
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context)
                  .copyWith(scrollbars: false),
              child: _edgeFade(
                SingleChildScrollView(
                  controller: _scroll,
                  padding: EdgeInsets.only(
                    top: box.maxHeight * SyncedLyricsList.anchor,
                    bottom: box.maxHeight * 0.55,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, line) in widget.lines.indexed)
                        _Line(
                          key: _keys[i],
                          text: line.text,
                          state: i == _active
                              ? _LineState.active
                              : i < _active
                              ? _LineState.past
                              : _LineState.future,
                          style: base,
                          color: c.textPrimary,
                          gap: size * 0.3,
                          duration: fx.motion(NoirMotion.slow),
                          onTap: canSeek ? () => _seekTo(i) : null,
                          karaoke: karaokeRow(i, base),
                        ),
                      _Credit(widget.source),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _LineState { past, active, future }

/// Sung lines recede further than the ones still to come.
const _pastAlpha = 0.35;
const _futureAlpha = 0.55;

class _Line extends StatelessWidget {
  const _Line({
    required this.text,
    required this.state,
    required this.style,
    required this.color,
    required this.gap,
    required this.duration,
    required this.onTap,
    this.karaoke,
    super.key,
  });

  final String text;
  final _LineState state;
  final TextStyle style;
  final Color color;

  /// Space above and below the line.
  final double gap;
  final Duration duration;
  final VoidCallback? onTap;

  /// The line's karaoke rendering, in place of the plain one.
  final Widget? karaoke;

  @override
  Widget build(BuildContext context) {
    final active = state == _LineState.active;
    final alpha = switch (state) {
      _LineState.active => 1.0,
      _LineState.past => _pastAlpha,
      _LineState.future => _futureAlpha,
    };
    return Semantics(
      selected: active,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: NoirRadii.mdAll,
        hoverColor: context.noir.hover,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: NoirSpacing.sm,
            vertical: gap,
          ),
          child:
              karaoke ??
              AnimatedScale(
                scale: active ? 1 : 0.97,
                alignment: Alignment.centerLeft,
                duration: duration,
                curve: NoirMotion.standard,
                child: AnimatedDefaultTextStyle(
                  duration: duration,
                  curve: NoirMotion.standard,
                  style: style.copyWith(color: color.withValues(alpha: alpha)),
                  child: Text(text.isEmpty ? '♪' : text),
                ),
              ),
        ),
      ),
    );
  }
}
