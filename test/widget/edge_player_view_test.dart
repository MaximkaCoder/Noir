import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/edge_player/edge_player_view.dart';
import 'package:noir/features/edge_player/edge_snapshot.dart';

const _channel = MethodChannel('test/edge_view');

/// The runner's window: 380 logical pixels square, 48 of them past the
/// screen edge.
const _window = Size(380, 380);
const _overhang = 48.0;

const _playing = EdgeSnapshot(
  side: 'right',
  visible: true,
  title: 'Ash & Ember',
  artist: 'Mara Vale',
  playing: true,
  canPrevious: true,
  duration: Duration(minutes: 3),
  position: Duration(minutes: 1),
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

  /// The player minimized-and-ready on [side], showing the thin line.
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
    await deliver(tester, 'update', _playing.toMap());
    await tester.pumpAndSettle();
  }

  /// A mouse resting at [at].
  Future<TestGesture> hover(WidgetTester tester, Offset at) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: at);
    await mouse.moveTo(at);
    await tester.pump();
    return mouse;
  }

  /// Lets an animation finish. The artwork keeps flowing behind the
  /// strip, so the tree never settles.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// Points at the line on the right edge, bringing out the strip.
  Future<TestGesture> openStrip(WidgetTester tester) async {
    final mouse = await hover(tester, const Offset(330, 190));
    await settle(tester);
    return mouse;
  }

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('More'));
    await settle(tester);
  }

  testWidgets('a thin line at the edge brings out the strip when pointed at', (
    tester,
  ) async {
    await pump(tester);
    expect(calls.first.method, 'ready');
    final line = regions().last;
    expect(line['right'], _window.width);
    // Only a few pixels on screen.
    expect(_window.width - _overhang - (line['left']! as num), lessThan(12));
    expect(find.text('Ash & Ember'), findsNothing);

    final mouse = await openStrip(tester);
    expect(find.text('Ash & Ember'), findsOneWidget);
    for (final label in ['Previous', 'Pause', 'Next', 'Like', 'More']) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    // Pointing longer does not open the wider player.
    await tester.pump(const Duration(seconds: 2));
    expect(find.bySemanticsLabel('Volume'), findsNothing);

    // Off the window: the runner clips it to the player, so leaving the
    // player leaves the window.
    await mouse.moveTo(const Offset(-10, -10));
    await tester.pump(EdgePlayerView.grace);
    await settle(tester);
    expect(find.text('Ash & Ember'), findsNothing);
    expect(regions().last, line);
  });

  testWidgets('NOIR opened: the player slides away, then gives up its region', (
    tester,
  ) async {
    await pump(tester);
    await openStrip(tester);
    final strip = regions().last;

    await deliver(tester, 'update', const EdgeSnapshot(side: 'right').toMap());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Ash & Ember'), findsOneWidget);
    expect(regions().last, strip);
    await settle(tester);
    expect(find.text('Ash & Ember'), findsNothing);
    final away = regions().last;
    expect(away['right'], away['left']);
  });

  testWidgets('More opens the wider player, Less closes it', (tester) async {
    await pump(tester);
    await openStrip(tester);

    await openPanel(tester);
    expect(find.bySemanticsLabel('Volume'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Less'));
    await settle(tester);
    expect(find.bySemanticsLabel('Volume'), findsNothing);
    expect(find.bySemanticsLabel('More'), findsOneWidget);
  });

  testWidgets('the strip sends commands; the artwork and title open NOIR', (
    tester,
  ) async {
    await pump(tester);
    await openStrip(tester);

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.tap(find.bySemanticsLabel('Previous'));
    // No next track: the button does nothing.
    await tester.tap(find.bySemanticsLabel('Next'));
    await tester.tap(find.bySemanticsLabel('Like'));
    await tester.tap(find.text('Ash & Ember'));
    await tester.pump();
    expect(commands(), ['playPause', 'previous', 'like', 'open']);
  });

  testWidgets('the progress line spans the panel whatever the position', (
    tester,
  ) async {
    await pump(tester);
    await openStrip(tester);
    await openPanel(tester);

    // A third of the song played; the track still runs the full width
    // (it used to be as wide as the played part, centered).
    final lines = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_LinePainter',
    );
    final progress = tester.getRect(lines.first);
    final volume = tester.getRect(lines.last);
    expect(progress.width, greaterThan(EdgeShape.panelSize.width - 40));
    expect(volume.width, greaterThan(100));
  });

  testWidgets('dragging the strip tells the runner where it goes', (
    tester,
  ) async {
    await pump(tester);
    await openStrip(tester);

    final drag = await tester.startGesture(
      tester.getCenter(find.bySemanticsLabel('Pause')) + const Offset(0, 20),
    );
    await drag.moveBy(const Offset(-40, 30));
    await drag.moveBy(const Offset(-40, 30));
    await drag.up();
    await settle(tester);
    expect(drags().first, 'dragStart');
    expect(drags(), contains('dragUpdate'));
    expect(drags().last, 'dragEnd');
    final end = calls.lastWhere((c) => c.method == 'dragEnd').arguments as Map;
    expect(end['depth'], 60);
    // The strip's middle: 30 in from the edge, halfway down.
    expect(end['centerX'], _window.width - _overhang - 30);
    expect(end['centerY'], _window.height / 2);
    expect(commands(), isEmpty);
  });

  testWidgets('on the bottom edge the strip lies along it', (tester) async {
    await pump(tester, side: 'bottom');
    final line = regions().last;
    expect(line['bottom'], _window.height);
    expect(_window.height - _overhang - (line['top']! as num), lessThan(12));

    await hover(tester, const Offset(190, 330));
    await settle(tester);
    final title = tester.getCenter(find.text('Ash & Ember'));
    final pause = tester.getCenter(find.bySemanticsLabel('Pause'));
    expect((title.dy - pause.dy).abs(), lessThan(10));
    expect(pause.dx, greaterThan(title.dx));
  });

  testWidgets('the line turns dark over a light screen', (tester) async {
    await pump(tester);
    Color line() {
      final box = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer).first,
      );
      return (box.decoration! as BoxDecoration).color!;
    }

    expect(line().computeLuminance(), greaterThan(0.5));
    await deliver(tester, 'tone', {'luminance': 0.9});
    await tester.pumpAndSettle();
    expect(line().computeLuminance(), lessThan(0.1));
    // Mid-grey keeps it as it is; only a dark screen turns it back.
    await deliver(tester, 'tone', {'luminance': 0.5});
    await tester.pumpAndSettle();
    expect(line().computeLuminance(), lessThan(0.1));
    await deliver(tester, 'tone', {'luminance': 0.2});
    await tester.pumpAndSettle();
    expect(line().computeLuminance(), greaterThan(0.5));
  });

  group('outline', () {
    const box = Rect.fromLTWH(100, 50, 60, 276);

    test('loose, it is the box with rounded corners', () {
      const loose = EdgeOutline(box, EdgeSide.right, radius: 16, attach: 0);
      expect(loose.path.getBounds(), box);
      // A rounded corner leaves the box's corner itself outside.
      expect(loose.path.contains(box.topRight + const Offset(-1, 1)), isFalse);
    });

    test('stuck, it is flat against the edge and flares into it', () {
      const stuck = EdgeOutline(box, EdgeSide.right, radius: 16, attach: 1);
      final bounds = stuck.path.getBounds();
      expect(bounds.right, box.right);
      expect(bounds.left, box.left);
      // The flares run along the edge past both ends of the box.
      expect(bounds.top, closeTo(box.top - EdgeOutline.flare, 0.01));
      expect(bounds.bottom, closeTo(box.bottom + EdgeOutline.flare, 0.01));
      expect(stuck.path.contains(box.topRight + const Offset(-1, 1)), isTrue);
      // The inner corners stay rounded.
      expect(stuck.path.contains(box.topLeft + const Offset(1, 1)), isFalse);
    });

    test('on the left and bottom edges it flares the same way, mirrored', () {
      const left = EdgeOutline(box, EdgeSide.left, radius: 16, attach: 1);
      final l = left.path.getBounds();
      expect((l.left, l.right), (box.left, box.right));
      expect(l.top, closeTo(box.top - EdgeOutline.flare, 0.01));

      const wide = Rect.fromLTWH(40, 200, 300, 60);
      const bottom = EdgeOutline(wide, EdgeSide.bottom, radius: 16, attach: 1);
      final b = bottom.path.getBounds();
      expect((b.top, b.bottom), (wide.top, wide.bottom));
      expect(b.left, closeTo(wide.left - EdgeOutline.flare, 0.01));
      expect(b.right, closeTo(wide.right + EdgeOutline.flare, 0.01));
    });
  });
}
