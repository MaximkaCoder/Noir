import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';
import 'package:noir/features/home/application/pinned_playlists.dart';

import '../helpers/test_database.dart';

void main() {
  group('smooth wheel scrolling', () {
    Future<ScrollController> pumpList(
      WidgetTester tester, {
      bool smooth = true,
    }) async {
      final controller = SmoothScrollController(smooth: smooth);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListView.builder(
            controller: controller,
            itemCount: 100,
            itemExtent: 50,
            itemBuilder: (_, i) => Text('$i'),
          ),
        ),
      );
      return controller;
    }

    Future<void> wheel(WidgetTester tester, double dy) async {
      final center = tester.getCenter(find.byType(ListView));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: Offset(0, dy)),
      );
    }

    testWidgets('a wheel notch glides to its target', (tester) async {
      final c = await pumpList(tester);
      await wheel(tester, 100);
      await tester.pump();
      expect(c.offset, lessThan(100), reason: 'not an instant jump');
      await tester.pump(const Duration(milliseconds: 120));
      expect(c.offset, greaterThan(0));
      await tester.pumpAndSettle();
      expect(c.offset, 100);
    });

    testWidgets('notches during a glide add up', (tester) async {
      final c = await pumpList(tester);
      await wheel(tester, 100);
      await tester.pump(const Duration(milliseconds: 50));
      await wheel(tester, 100);
      await tester.pumpAndSettle();
      expect(c.offset, 200);
    });

    testWidgets('with animations off the wheel jumps', (tester) async {
      final c = await pumpList(tester, smooth: false);
      await wheel(tester, 100);
      await tester.pump();
      expect(c.offset, 100);
    });
  });

  group('window dots', () {
    testWidgets('only the hovered dot lights up, then fades back', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: WindowControls())),
      );
      Color? colorOf(String tooltip) {
        final dot = find.descendant(
          of: find.byTooltip(tooltip),
          matching: find.byType(AnimatedContainer),
        );
        final box = tester.widget<AnimatedContainer>(dot).decoration;
        return (box! as BoxDecoration).color;
      }

      final idle = colorOf('Close');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byTooltip('Close')));
      await tester.pumpAndSettle();

      expect(colorOf('Close'), const Color(0xFFFF5F57));
      expect(colorOf('Minimize'), idle);
      expect(colorOf('Maximize'), idle);

      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(colorOf('Close'), idle);
    });
  });

  group('pinned collections', () {
    test('toggle pins newest first and persists', () async {
      final db = inMemoryDatabase();
      addTearDown(db.close);
      ProviderContainer open() {
        final c = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(db)],
        )..listen(pinnedProvider, (_, _) {});
        addTearDown(c.dispose);
        return c;
      }

      final c = open();
      final pins = c.read(pinnedProvider.notifier);
      const a = PinnedRef(PinKind.youtube, 'PLa');
      const b = PinnedRef(PinKind.local, '7');
      expect(pins.toggle(a), isTrue);
      expect(pins.toggle(b), isTrue);
      expect(pins.toggle(PinnedRef.favorites), isTrue);
      expect(pins.toggle(b), isFalse);
      expect(c.read(pinnedProvider), [PinnedRef.favorites, a]);
      await pumpEventQueue();

      final restarted = open();
      await pumpEventQueue();
      expect(restarted.read(pinnedProvider), [PinnedRef.favorites, a]);
      expect(a.location, '/library/youtube/PLa');
    });
  });
}
