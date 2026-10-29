import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/widgets/artwork_flow.dart';
import 'package:noir/features/lyrics/presentation/karaoke_lyrics.dart';

// Each step of these clocks redraws the window, so they step at a set
// pace instead of at the display's refresh rate (144 Hz on some laptops).
void main() {
  testWidgets('the artwork flow steps 30 times a second', (tester) async {
    final flow = FlowClock(period: const Duration(seconds: 36));
    addTearDown(flow.dispose);
    var steps = 0;
    flow
      ..addListener(() => steps++)
      ..start();
    await tester.pump(const Duration(seconds: 1));
    expect(steps, inInclusiveRange(29, 30));
    expect(flow.value, closeTo(1 / 36, 0.002));

    // Stopped, it keeps its place and resumes from there.
    flow.stop();
    await tester.pump(const Duration(seconds: 1));
    expect(steps, inInclusiveRange(29, 30));
    flow.start();
    await tester.pump(const Duration(seconds: 1));
    expect(flow.value, closeTo(2 / 36, 0.004));
    flow.stop();
  });

  testWidgets('the karaoke clock glides about 60 times a second', (
    tester,
  ) async {
    final clock = KaraokeClock();
    addTearDown(clock.dispose);
    var steps = 0;
    clock
      ..addListener(() => steps++)
      ..report(const Duration(seconds: 10))
      ..run(smooth: true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(steps, inInclusiveRange(29, 30));
    expect(
      clock.value.inMilliseconds,
      closeTo(const Duration(milliseconds: 10500).inMilliseconds, 20),
    );
    clock.run(smooth: false);
  });
}
