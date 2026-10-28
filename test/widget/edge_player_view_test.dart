import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/edge_player/edge_player_view.dart';
import 'package:noir/features/edge_player/edge_snapshot.dart';

const _channel = MethodChannel('test/edge_view');

/// The runner's window: 360 × 520 logical pixels, 48 of them past the
/// screen edge.
const _window = Size(360, 520);
const _overhang = 48.0;

void main() {
  late List<MethodCall> calls;

  List<Map<Object?, Object?>> regions() => [
    for (final c in calls)
      if (c.method == 'region') c.arguments as Map,
  ];
  List<Map<Object?, Object?>> commands() => [
    for (final c in calls)
      if (c.method == 'command') c.arguments as Map,
  ];

  Future<void> deliver(WidgetTester tester, String method, Object args) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  Future<void> pump(WidgetTester tester, {String side = 'right'}) async {
    calls = [];
    tester.view
      ..physicalSize = _window
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(home: EdgePlayerView(channel: _channel)),
    );
    await deliver(tester, 'layout', {'side': side, 'overhang': _overhang});
    await deliver(
      tester,
      'update',
      const EdgeSnapshot(
        side: 'right',
        visible: true,
        title: 'Ash & Ember',
        artist: 'Mara Vale',
        playing: true,
        canPrevious: true,
        duration: Duration(minutes: 3),
        volume: 0.5,
        canLike: true,
      ).toMap(),
    );
    await tester.pump();
  }

  testWidgets('a thin handle opens into the capsule, then the panel', (
    tester,
  ) async {
    await pump(tester);
    expect(calls.first.method, 'ready');
    final handle = regions().last;
    expect(handle['open'], isFalse);
    expect(handle['right'], _window.width);
    // Only a few pixels on screen, to point at.
    expect(_window.width - _overhang - (handle['left']! as num), lessThan(12));
    expect(find.text('Ash & Ember'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(310, 260));
    await mouse.moveTo(const Offset(310, 260));
    await tester.pump();
    // Before the player grows, its region already has.
    expect(regions().last['open'], isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    expect(find.text('Ash & Ember'), findsNothing);

    await tester.pump(EdgePlayerView.dwell);
    await tester.pumpAndSettle();
    expect(find.text('Ash & Ember'), findsOneWidget);
    expect(find.text('Mara Vale'), findsOneWidget);
    final panel = regions().last;
    expect(panel['left']! as num, lessThan(_window.width - 264 - _overhang));

    // Leaving: back to the handle, and only then the region shrinks.
    await mouse.moveTo(const Offset(-10, -10));
    await tester.pump(EdgePlayerView.grace);
    await tester.pump(const Duration(milliseconds: 100));
    expect(regions().last, panel);
    await tester.pumpAndSettle();
    expect(regions().last['open'], isFalse);
    expect(find.text('Ash & Ember'), findsNothing);
  });

  testWidgets('the panel sends commands', (tester) async {
    await pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(310, 260));
    await mouse.moveTo(const Offset(310, 260));
    await tester.pump();
    await tester.pump(EdgePlayerView.dwell);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.tap(find.bySemanticsLabel('Previous'));
    // No next track: the button does nothing.
    await tester.tap(find.bySemanticsLabel('Next'));
    await tester.tap(find.bySemanticsLabel('Like'));
    await tester.tap(find.bySemanticsLabel('Open NOIR'));
    await tester.pump();
    expect(
      [for (final c in commands()) c['name']],
      ['playPause', 'previous', 'like', 'open'],
    );
  });

  testWidgets('on the left edge it sits flush with the left side', (
    tester,
  ) async {
    await pump(tester, side: 'left');
    final handle = regions().last;
    expect(handle['left'], 0);
    expect((handle['right']! as num) - _overhang, lessThan(12));
  });
}
