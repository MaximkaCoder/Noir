import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/features/lyrics/domain/lrc.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/shared/models/playback.dart';

/// Karaoke: the line being sung, large, its words lighting up one by one in
/// time with the singing; the next line below it and the previous one
/// fading out above.
///
/// Only the fill repaints between position ticks: a [Ticker] interpolates
/// the position while playing, so the sweep moves every frame instead of
/// stepping with each tick. The rest rebuilds when the line changes.
class KaraokeLyrics extends ConsumerStatefulWidget {
  const KaraokeLyrics({required this.lines, this.compact = false, super.key});

  final List<LyricLine> lines;

  /// Smaller type for narrow windows.
  final bool compact;

  /// Where the current line rests, as a fraction of the height.
  static const anchor = 0.36;

  @override
  ConsumerState<KaraokeLyrics> createState() => _KaraokeLyricsState();
}

class _KaraokeLyricsState extends ConsumerState<KaraokeLyrics>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  /// The position the fill shows.
  final _position = ValueNotifier<Duration>(Duration.zero);

  /// Last position the engine reported, and the ticker time it arrived at.
  Duration _reported = Duration.zero;
  Duration _reportedAt = Duration.zero;
  Duration _elapsed = Duration.zero;

  /// Reports stop while buffering; never run further ahead than this.
  static const _maxAhead = Duration(milliseconds: 1500);

  int _active = -1;
  final _timings = <int, List<WordTiming>>{};

  @override
  void initState() {
    super.initState();
    _report(ref.read(playbackEngineProvider).currentPosition);
    ref
      ..listenManual(positionProvider, (_, next) {
        if (next.value case final p?) _report(p);
      })
      ..listenManual(
        playbackProvider.select((s) => s.status == PlaybackStatus.playing),
        (_, playing) => _run(playing: playing),
      );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Also when animations are switched on or off.
    _run(playing: ref.read(playbackProvider).status == PlaybackStatus.playing);
  }

  @override
  void didUpdateWidget(KaraokeLyrics old) {
    super.didUpdateWidget(old);
    if (old.lines != widget.lines) {
      _timings.clear();
      _active = activeLineIndex(widget.lines, _position.value);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _position.dispose();
    super.dispose();
  }

  void _run({required bool playing}) {
    // With animations off the fill steps with the engine's ticks.
    final smooth = playing && NoirEffects.of(context).animations;
    if (smooth == _ticker.isActive) return;
    if (smooth) {
      _elapsed = Duration.zero;
      _reportedAt = Duration.zero;
      _ticker.start();
    } else {
      _ticker.stop();
      _show(_reported);
    }
  }

  void _report(Duration position) {
    _reported = position;
    _reportedAt = _elapsed;
    if (!_ticker.isActive) _show(position);
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    var ahead = elapsed - _reportedAt;
    if (ahead > _maxAhead) ahead = _maxAhead;
    final next = _reported + ahead;
    // Reports lag a little behind the interpolation; don't step back for
    // that, only for real seeks.
    final shown = _position.value;
    if (next < shown && shown - next < const Duration(milliseconds: 400)) {
      return;
    }
    _show(next);
  }

  void _show(Duration position) {
    _position.value = position;
    final index = activeLineIndex(widget.lines, position);
    if (index != _active && mounted) setState(() => _active = index);
  }

  List<WordTiming> _wordsOf(int index) =>
      _timings[index] ??= lineWordTimings(widget.lines, index);

  /// The nearest line after [index] with words in it.
  int? _nextSung(int index) {
    for (var i = index + 1; i < widget.lines.length; i++) {
      if (widget.lines[i].text.isNotEmpty) return i;
    }
    return null;
  }

  void _seek(int index) => unawaited(
    ref.read(playbackProvider.notifier).seek(widget.lines[index].time),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    final canSeek = ref.watch(
      playbackProvider.select((s) => s.capabilities.canSeek),
    );
    final lines = widget.lines;
    final active = _active;
    final current = active >= 0 ? lines[active] : null;
    final next = _nextSung(active);
    final previous = active > 0 && lines[active - 1].text.isNotEmpty
        ? active - 1
        : null;

    return LayoutBuilder(
      builder: (context, box) {
        final size = karaokeFontSize(box, compact: widget.compact);
        final base = DefaultTextStyle.of(context).style
            .merge(lyricLineStyle(context, size));
        final sung = current != null && current.text.isNotEmpty;
        final block = Column(
          key: ValueKey(active),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (previous != null)
              Padding(
                padding: EdgeInsets.only(bottom: size * 0.45),
                child: Text(
                  lines[previous].text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(
                    fontSize: size * 0.62,
                    color: c.textPrimary.withValues(alpha: 0.28),
                  ),
                ),
              ),
            if (sung)
              KaraokeLine(
                text: current.text,
                words: _wordsOf(active),
                position: _position,
                style: base,
                lit: c.textPrimary,
                unlit: c.textPrimary.withValues(alpha: 0.32),
              )
            else
              Text(
                '♪',
                style: base.copyWith(
                  color: c.textPrimary.withValues(alpha: 0.5),
                ),
              ),
            if (next != null)
              Padding(
                padding: EdgeInsets.only(top: size * 0.55),
                child: _Tappable(
                  onTap: canSeek ? () => _seek(next) : null,
                  child: Text(
                    lines[next].text,
                    style: base.copyWith(
                      fontSize: size * 0.78,
                      color: c.textPrimary.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ),
          ],
        );
        final duration = fx.motion(NoirMotion.slow);
        return ClipRect(
          child: Padding(
            padding: EdgeInsets.only(
              top: box.maxHeight * KaraokeLyrics.anchor - size * 1.6,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: AnimatedSwitcher(
                duration: duration,
                switchInCurve: NoirMotion.standard,
                switchOutCurve: NoirMotion.exit,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topLeft,
                  children: [...previous, ?current],
                ),
                transitionBuilder: (child, animation) {
                  final incoming = child.key == ValueKey(active);
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(0, incoming ? 0.12 : -0.12),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: block,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Karaoke type size for a lyrics area of [box]: large, following the
/// window, within readable bounds.
double karaokeFontSize(BoxConstraints box, {required bool compact}) {
  final fit = math.min(box.maxWidth * 0.058, box.maxHeight * 0.075);
  return compact ? fit.clamp(24.0, 38.0) : fit.clamp(30.0, 50.0);
}

/// Large, bold lyric type at [size].
TextStyle lyricLineStyle(BuildContext context, double size) =>
    (Theme.of(context).textTheme.headlineSmall ?? const TextStyle()).copyWith(
      fontSize: size,
      fontWeight: FontWeight.w800,
      height: 1.22,
      letterSpacing: -0.02 * size,
    );

class _Tappable extends StatelessWidget {
  const _Tappable({required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: child),
    );
  }
}

/// One karaoke line: [text] in [unlit], with the sung part painted over it
/// in [lit] — word by word, the current word filling with a soft edge.
class KaraokeLine extends StatelessWidget {
  const KaraokeLine({
    required this.text,
    required this.words,
    required this.position,
    required this.style,
    required this.lit,
    required this.unlit,
    super.key,
  });

  final String text;

  /// Timed pieces of [text].
  final List<WordTiming> words;

  /// Playback position; the fill repaints as it changes.
  final ValueListenable<Duration> position;
  final TextStyle style;
  final Color lit;
  final Color unlit;

  /// How much of the line (by characters) is lit at [at], 0–1.
  double litFractionAt(Duration at) {
    var total = 0;
    var done = 0.0;
    for (final w in words) {
      final chars = w.to - w.from;
      total += chars;
      done += chars * w.progressAt(at);
    }
    return total == 0 ? 0 : done / total;
  }

  @override
  Widget build(BuildContext context) {
    final defaults = DefaultTextStyle.of(context);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: CustomPaint(
        foregroundPainter: _FillPainter(
          text: text,
          words: words,
          position: position,
          style: style.copyWith(color: lit),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
          textHeightBehavior: defaults.textHeightBehavior,
        ),
        child: Text(text, style: style.copyWith(color: unlit)),
      ),
    );
  }
}

class _FillPainter extends CustomPainter {
  _FillPainter({
    required this.text,
    required this.words,
    required this.position,
    required this.style,
    required this.textScaler,
    required this.textDirection,
    required this.textHeightBehavior,
  }) : super(repaint: position);

  final String text;
  final List<WordTiming> words;
  final ValueListenable<Duration> position;
  final TextStyle style;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final TextHeightBehavior? textHeightBehavior;

  TextPainter? _painter;
  double? _width;
  late List<List<Rect>> _boxes;

  TextPainter _layout(double width) {
    final cached = _painter;
    if (cached != null && _width == width) return cached;
    _painter?.dispose();
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      textHeightBehavior: textHeightBehavior,
    )..layout(maxWidth: width);
    _width = width;
    _boxes = [
      for (final w in words)
        [
          for (final b in painter.getBoxesForSelection(
            TextSelection(baseOffset: w.from, extentOffset: w.to),
          ))
            b.toRect(),
        ],
    ];
    return _painter = painter;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final painter = _layout(size.width);
    final boxes = _boxes;
    final at = position.value;
    // Glyphs reach a little past their boxes (italics, overhangs).
    final pad = (style.fontSize ?? 14) * 0.12;

    final done = Path();
    var any = false;
    int? partial;
    for (final (i, w) in words.indexed) {
      final p = w.progressAt(at);
      if (p >= 1) {
        for (final r in boxes[i]) {
          done.addRect(r.inflate(pad));
        }
        any = true;
      } else if (p > 0) {
        partial = i;
      }
    }
    if (any) {
      canvas
        ..save()
        ..clipPath(done);
      painter.paint(canvas, Offset.zero);
      canvas.restore();
    }

    final i = partial;
    if (i == null || boxes[i].isEmpty) return;
    // The word being sung: lit up to its progress with a soft edge.
    final rects = boxes[i];
    final span = rects.fold<double>(0, (a, r) => a + r.width);
    var reach = span * words[i].progressAt(at);
    final feather = (style.fontSize ?? 14) * 0.5;
    for (final r in rects) {
      final bounds = r.inflate(pad);
      final x = r.left + reach;
      reach -= r.width;
      if (x <= r.left - feather) break;
      canvas
        ..saveLayer(bounds, Paint())
        ..clipRect(bounds);
      painter.paint(canvas, Offset.zero);
      final edge = (x - bounds.left) / bounds.width;
      final soft = feather / bounds.width;
      canvas
        ..drawRect(
          bounds,
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = LinearGradient(
              colors: const [
                Color(0xFFFFFFFF),
                Color(0xFFFFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: [
                0,
                (edge - soft / 2).clamp(0.0, 1.0),
                (edge + soft / 2).clamp(0.0, 1.0),
              ],
            ).createShader(bounds),
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_FillPainter old) =>
      old.text != text ||
      old.words != words ||
      old.position != position ||
      old.style != style ||
      old.textScaler != textScaler ||
      old.textDirection != textDirection;
}
