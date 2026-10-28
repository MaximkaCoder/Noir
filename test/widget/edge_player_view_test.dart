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

const _playing = EdgeSnapshot(
  side: 'right',
  visible: true,
  title: 'Ash & Ember',
  artist: 'Mara Vale',
  playing: true,
  canPrevious: true,
  duration: Duration(minutes: 3),
  volume: 0.5,
  canLike: true,
);

void main() {
  late List<MethodCall> calls;

  List<Map<Object?, Object?>> regions() => [
    for (final c in calls)
      if (c.method == 'region') c.arguments as Map,
  ];
  List<Object?> commands() => [
    for (final c in calls)
      if (c.method == 'command') (c.arguments as Map)['name'],
  ];
  List<String> drags() => [
    for (final c in calls)
      if (c.method.startsWith('drag')) c.method,
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
    await tester.pump();
  }

  Future<TestGesture> hover(WidgetTester tester, Offset at) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: at);
    await mouse.moveTo(at);
    await tester.pump();
    return mouse;
  }

  testWidgets('comes out as a strip while minimized and slides away after', (
    tester,
  ) async {
    await pump(tester);
    expect(calls.first.method, 'ready');
    expect(find.text('Ash & Ember'), findsNothing);

    await deliver(tester, 'update', _playing.toMap());
    await tester.pumpAndSettle();
    expect(find.text('Ash & Ember'), findsOneWidget);
    expect(find.text('Mara Vale'), findsOneWidget);
    for (final label in ['Previous', 'Pause', 'Next', 'Like', 'More']) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    final strip = regions().last;
    expect(strip['right'], _window.width);
    expect(
      _window.width - _overhang - (strip['left']! as num),
      lessThan(60 + EdgePlayerView.shadowRoom + 1),
    );

    // NOIR opened again: it slides away, keeping the track meanwhile, and
    // only then gives up its region.
    await deliver(tester, 'update', const EdgeSnapshot(side: 'right').toMap());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Ash & Ember'), findsOneWidget);
    expect(regions().last, strip);
    await tester.pumpAndSettle();
    expect(find.text('Ash & Ember'), findsNothing);
    final away = regions().last;
    expect(away['right'], away['left']);
  });

  testWidgets('pointing at the strip for a moment opens the panel', (
    tester,
  ) async {
    await pump(tester);
    await deliver(tester, 'update', _playing.toMap());
    await tester.pumpAndSettle();
    final strip = regions().last;

    final mouse = await hover(tester, const Offset(290, 160));
    await tester.pump(EdgePlayerView.dwell);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.bySemanticsLabel('Open NOIR'), findsOneWidget);
    expect(find.bySemanticsLabel('Volume'), findsOneWidget);

    await mouse.moveTo(const Offset(-10, -10));
    await tester.pump(EdgePlayerView.grace);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Open NOIR'), findsNothing);
    expect(regions().last, strip);
  });

  testWidgets('the strip sends commands; More opens the panel', (tester) async {
    await pump(tester);
    await deliver(tester, 'update', _playing.toMap());
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.tap(find.bySemanticsLabel('Previous'));
    // No next track: the button does nothing.
    await tester.tap(find.bySemanticsLabel('Next'));
    await tester.tap(find.bySemanticsLabel('Like'));
    await tester.pump();
    expect(commands(), ['playPause', 'previous', 'like']);

    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.bySemanticsLabel('Open NOIR'));
    expect(commands().last, 'open');
  });

  testWidgets('dragging tells the runner where the pointer goes', (
    tester,
  ) async {
    await pump(tester);
    await deliver(tester, 'update', _playing.toMap());
    await tester.pumpAndSettle();

    final art = tester.getCenter(find.text('Ash & Ember'));
    final drag = await tester.startGesture(art);
    await drag.moveBy(const Offset(-40, 30));
    await drag.moveBy(const Offset(-40, 30));
    await drag.up();
    await tester.pumpAndSettle();
    expect(drags().first, 'dragStart');
    expect(drags(), contains('dragUpdate'));
    expect(drags().last, 'dragEnd');
    final end = calls.lastWhere((c) => c.method == 'dragEnd');
    expect((end.arguments as Map)['depth'], 60);
    expect(commands(), isEmpty);
  });

  testWidgets('on the left edge it sits flush with the left side', (
    tester,
  ) async {
    await pump(tester, side: 'left');
    await deliver(tester, 'update', _playing.toMap());
    await tester.pumpAndSettle();
    final strip = regions().last;
    expect(strip['left'], 0);
    expect(
      (strip['right']! as num) - _overhang,
      lessThan(60 + EdgePlayerView.shadowRoom + 1),
    );
  });
}
