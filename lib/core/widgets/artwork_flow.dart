import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Blurs [src] once into a tiny bitmap [width] px wide, to be upscaled with
/// smooth filtering under [ArtworkFlowPainter]. A large-sigma blur at screen
/// size is downsampled internally and shows blocks; blurring small and
/// scaling up doesn't.
Future<ui.Image> blurArtwork(
  ui.Image src, {
  required int width,
  required double sigma,
}) {
  final h = max(1, (width * src.height / src.width).round());
  // Draw a little past the edges so the blur doesn't darken them.
  const pad = 12.0;
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    src,
    Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    Rect.fromLTWH(-pad, -pad, width + 2 * pad, h + 2 * pad),
    Paint()
      ..filterQuality = ui.FilterQuality.medium
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: ui.TileMode.clamp,
      ),
  );
  return recorder.endRecording().toImage(width, h);
}

/// Artwork as a slowly flowing liquid (Now Playing's backdrop, the edge
/// player's glass): the blurred bitmap fills the canvas, drifting a little,
/// and two larger copies turn over it in opposite directions at partial
/// opacity, so its colours swirl into one another. The previous track's
/// flow fades out under the new one.
class ArtworkFlowPainter extends CustomPainter {
  ArtworkFlowPainter({
    required this.shown,
    required this.previous,
    required this.fade,
    required this.flow,
  }) : super(repaint: Listenable.merge([fade, flow]));

  final ui.Image? shown;
  final ui.Image? previous;
  final Animation<double> fade;

  /// 0–1 over one loop.
  final Animation<double> flow;

  @override
  void paint(Canvas canvas, Size size) {
    final previous = this.previous;
    final shown = this.shown;
    if (previous != null) {
      _paintFlow(canvas, size, previous, shown == null ? 1 - fade.value : 1);
    }
    if (shown != null) {
      _paintFlow(canvas, size, shown, previous == null ? 1 : fade.value);
    }
  }

  void _paintFlow(Canvas canvas, Size size, ui.Image image, double alpha) {
    if (alpha <= 0) return;
    final a = flow.value * 2 * pi;
    final w = size.width;
    final h = size.height;
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    Paint paint(double opacity) => Paint()
      ..filterQuality = ui.FilterQuality.high
      ..color = Color.fromRGBO(0, 0, 0, alpha * opacity);

    // The whole artwork, covering the window with a little room to drift.
    final scale = max(w / src.width, h / src.height) * 1.2;
    final base = Rect.fromCenter(
      center: Offset(w / 2 + sin(a) * w * 0.08, h / 2 + cos(a * 2) * h * 0.08),
      width: src.width * scale,
      height: src.height * scale,
    );
    canvas.drawImageRect(image, src, base, paint(1));

    // Two larger copies turning over it; big enough to cover the window at
    // any angle.
    final side = sqrt(w * w + h * h) * 1.5;
    for (final (turn, drift, phase, opacity) in const [
      (1.0, 2.0, 0.0, 0.6),
      (-1.0, 3.0, pi / 2, 0.5),
    ]) {
      canvas
        ..save()
        ..translate(
          w / 2 + sin(a * drift + phase) * w * 0.22,
          h / 2 + cos(a * (drift - 1) + phase) * h * 0.22,
        )
        ..rotate(a * turn + phase)
        ..drawImageRect(
          image,
          src,
          Rect.fromCenter(center: Offset.zero, width: side, height: side),
          paint(opacity),
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(ArtworkFlowPainter old) =>
      old.shown != shown ||
      old.previous != previous ||
      old.fade != fade ||
      old.flow != flow;
}
