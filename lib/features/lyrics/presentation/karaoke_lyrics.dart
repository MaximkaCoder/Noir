
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:noir/features/lyrics/domain/lrc.dart';

/// The playback position the karaoke fill shows: the engine's position,
/// interpolated every frame while [run] says it is playing, so the sweep
/// glides instead of stepping with each position tick (about every 200 ms).
class KaraokeClock extends ValueNotifier<Duration> {
  KaraokeClock(TickerProvider vsync) : super(Duration.zero) {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;

  /// Last position the engine reported, and the ticker time it arrived at.
  Duration _reported = Duration.zero;
  Duration _reportedAt = Duration.zero;
  Duration _elapsed = Duration.zero;

  /// Reports stop while buffering; never run further ahead than this.
  static const _maxAhead = Duration(milliseconds: 1500);

  /// Whether it is interpolating.
  bool get running => _ticker.isActive;

  /// Interpolates while [smooth]; otherwise shows the reported position.
  void run({required bool smooth}) {
    if (smooth == _ticker.isActive) return;
    if (smooth) {
      _elapsed = Duration.zero;
      _reportedAt = Duration.zero;
      _ticker.start();
    } else {
      _ticker.stop();
      value = _reported;
    }
  }

  /// A position from the engine.
  void report(Duration position) {
    _reported = position;
    _reportedAt = _elapsed;
    if (!_ticker.isActive) value = position;
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    var ahead = elapsed - _reportedAt;
    if (ahead > _maxAhead) ahead = _maxAhead;
    final next = _reported + ahead;
    // Reports lag a little behind the interpolation; don't step back for
    // that, only for real seeks.
    if (next < value && value - next < const Duration(milliseconds: 400)) {
      return;
    }
    value = next;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// One line of the karaoke list: its plain text in [rest] while [grow] is 0;
/// [activeScale] times larger with its words filling in [KaraokeLine] at 1.
/// The list drives [grow] for the line coming in and the one going out from
/// one animation, which also carries its scroll, so size, colour and
/// position move together frame by frame.
///
/// Every row is laid out at the width it has at [activeScale], so growing
/// or shrinking never rewraps it: only a transform and the row's height
/// change.
class KaraokeRow extends StatelessWidget {
  const KaraokeRow({
    required this.text,
    required this.grow,
    required this.words,
    required this.position,
    required this.style,
    required this.lit,
    required this.unlit,
    required this.rest,
    required this.activeScale,
    super.key,
  });

  final String text;

  /// 0 at rest size, 1 sung (eased by the list).
  final Animation<double> grow;

  /// Timed pieces of [text], asked for only while the line is lit.
  final List<WordTiming> Function() words;
  final ValueListenable<Duration> position;

  /// The line's type at rest size, without colour.
  final TextStyle style;

  /// Sung words.
  final Color lit;

  /// Words still to come in the sung line.
  final Color unlit;

  /// The whole line at rest (past or upcoming).
  final Color rest;
  final double activeScale;

  @override
  Widget build(BuildContext context) {
    final shown = text.isEmpty ? '♪' : text;
    return AnimatedBuilder(
      animation: grow,
      builder: (context, _) {
        final g = grow.value.clamp(0.0, 1.0);
        final Widget content;
        if (g == 0 || text.isEmpty) {
          content = Text(
            shown,
            style: style.copyWith(color: Color.lerp(rest, lit, g)),
          );
        } else {
          content = KaraokeLine(
            text: shown,
            words: words(),
            position: position,
            style: style,
            lit: Color.lerp(rest, lit, g)!,
            unlit: Color.lerp(rest, unlit, g)!,
          );
        }
        return LyricRowScale(
          scale: 1 + (activeScale - 1) * g,
          layoutScale: activeScale,
          child: content,
        );
      },
    );
  }
}

/// Draws [child] [scale] times its size from its top left corner, and
/// takes up the scaled height. [child] is laid out [layoutScale] times
/// narrower than the space, so at that scale it fills the width exactly.
class LyricRowScale extends SingleChildRenderObjectWidget {
  const LyricRowScale({
    required this.scale,
    required this.layoutScale,
    super.child,
    super.key,
  });

  final double scale;
  final double layoutScale;

  @override
  RenderLyricRowScale createRenderObject(BuildContext context) =>
      RenderLyricRowScale(scale, layoutScale);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLyricRowScale renderObject,
  ) {
    renderObject
      ..scale = scale
      ..layoutScale = layoutScale;
  }
}

class RenderLyricRowScale extends RenderProxyBox {
  RenderLyricRowScale(this._scale, this._layoutScale);

  double get scale => _scale;
  double _scale;
  set scale(double value) {
    if (value == _scale) return;
    _scale = value;
    markNeedsLayout();
  }

  double get layoutScale => _layoutScale;
  double _layoutScale;
  set layoutScale(double value) {
    if (value == _layoutScale) return;
    _layoutScale = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    final width = constraints.maxWidth / _layoutScale;
    child.layout(
      BoxConstraints(maxWidth: width.isFinite ? width : double.infinity),
      parentUsesSize: true,
    );
    size = constraints.constrain(
      Size(constraints.maxWidth, child.size.height * _scale),
    );
  }

  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1);

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (_scale == 1) {
      context.paintChild(child, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) => context.paintChild(child, offset),
      oldLayer: layer as TransformLayer?,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, position) => child.hitTest(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_transform);
  }
}

/// Large, bold lyric type at [size].
TextStyle lyricLineStyle(BuildContext context, double size) =>
    (Theme.of(context).textTheme.headlineSmall ?? const TextStyle()).copyWith(
      fontSize: size,
      fontWeight: FontWeight.w800,
      height: 1.22,
      letterSpacing: -0.02 * size,
    );

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
