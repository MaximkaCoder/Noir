import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/features/lyrics/domain/lrc.dart';
import 'package:noir/features/lyrics/presentation/karaoke_lyrics.dart';
import 'package:noir/features/lyrics/presentation/lyrics_view.dart';

const _shot = ValueKey('shot');

/// The red channel at [at] in the boundary's current frame (white text on
/// black, so it is how bright the glyph shows).
Future<int> _brightness(WidgetTester tester, Offset at) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shot),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData();
    image.dispose();
    return data!;
  });
  final i = (at.dy.round() * boundary.size.width.round() + at.dx.round()) * 4;
  return bytes!.getUint8(i);
}

void main() {
  test('the fill only adds what the unlit text lacks', () {
    const white = Color(0xFFFFFFFF);
    final unlit = white.withValues(alpha: 0.55);
    // Fully lit stays fully lit.
    expect(KaraokeLine.fillOver(white, unlit).a, 1);
    // Lit no brighter than the unlit text: no fill at all.
    expect(KaraokeLine.fillOver(unlit, unlit).a, 0);
    // In between, fill over unlit composites to the lit opacity.
    final lit = white.withValues(alpha: 0.8);
    final fill = KaraokeLine.fillOver(lit, unlit).a;
    expect(fill + unlit.a * (1 - fill), moreOrLessEquals(0.8, epsilon: 1e-6));
  });

  testWidgets('the sung line fades from white to the past colour without a '
      'step as it shrinks back', (tester) async {
    tester.view
      ..physicalSize = const Size(400, 120)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Wired as the lyrics list wires the line it moves on from: shrinking
    // with the change's easing, every word long sung.
    final change = AnimationController(
      vsync: const TestVSync(),
      duration: SyncedLyricsList.karaokeChange,
      value: 0,
    );
    addTearDown(change.dispose);
    final shrink = ReverseAnimation(
      CurvedAnimation(parent: change, curve: NoirMotion.standard),
    );
    final position = ValueNotifier(const Duration(seconds: 10));
    addTearDown(position.dispose);
    const white = Color(0xFFFFFFFF);
    const past = 0.35;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: _shot,
            child: ColoredBox(
              color: const Color(0xFF000000),
              child: SizedBox(
                width: 400,
                height: 120,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: KaraokeRow(
                    text: 'Hold on',
                    grow: shrink,
                    words: () => const [
                      WordTiming(0, 4, Duration.zero, Duration(seconds: 1)),
                      WordTiming(
                        5,
                        7,
                        Duration(seconds: 1),
                        Duration(seconds: 2),
                      ),
                    ],
                    position: position,
                    style: const TextStyle(fontSize: 40, height: 1),
                    lit: white,
                    unlit: white.withValues(alpha: 0.55),
                    rest: white.withValues(alpha: past),
                    activeScale: SyncedLyricsList.karaokeScale,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Inside the first glyph at every scale the row passes through.
    const at = Offset(14, 20);
    final samples = [await _brightness(tester, at)];
    change.forward();
    while (change.isAnimating) {
      await tester.pump(const Duration(milliseconds: 16));
      samples.add(await _brightness(tester, at));
    }
    await tester.pump();
    samples.add(await _brightness(tester, at));

    expect(samples.first, greaterThanOrEqualTo(250), reason: '$samples');
    expect(
      samples.last,
      closeTo((past * 255).round(), 3),
      reason: 'rests at the past colour: $samples',
    );
    for (var i = 1; i < samples.length; i++) {
      expect(
        samples[i],
        lessThanOrEqualTo(samples[i - 1] + 1),
        reason: 'brightened again at frame $i: $samples',
      );
      // No frame-to-frame jump: the steepest step of the eased fade.
      expect(
        samples[i - 1] - samples[i],
        lessThanOrEqualTo(24),
        reason: 'stepped at frame $i: $samples',
      );
    }
    // Nor a cut once the line stops being drawn as a karaoke line.
    final end = samples.length - 1;
    expect(samples[end - 2] - samples[end], lessThanOrEqualTo(4));
  });
}
