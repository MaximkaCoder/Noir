import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';
import 'package:noir/features/home/application/pinned_playlists.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';

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
    Future<void> pumpControls(
      WidgetTester tester, {
      WindowButtons style = WindowButtons.dots,
    }) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(
            AppSettings(windowButtons: style),
          ),
        ],
        child: const MaterialApp(home: Center(child: WindowControls())),
      ),
    );

    /// The window_manager calls the buttons make.
    List<String> recordWindowCalls() {
      final calls = <String>[];
      const channel = MethodChannel('window_manager');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            ..setMockMethodCallHandler(channel, (call) async {
              calls.add(call.method);
              return false;
            });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      return calls;
    }

    testWidgets('a click near a dot edge still presses it', (tester) async {
      final calls = recordWindowCalls();
      await pumpControls(tester);
      final dot = tester.getCenter(find.byKey(WindowControls.dotKey).first);
      // Off the painted 12 px dot, inside its 20×24 target.
      await tester.tapAt(dot + const Offset(8, 9));
      await tester.pump();
      expect(calls, contains('minimize'));
    });

    testWidgets('Windows style: glyphs, a red close under the pointer', (
      tester,
    ) async {
      final calls = recordWindowCalls();
      await pumpControls(tester, style: WindowButtons.windows);
      expect(find.byKey(WindowControls.dotKey), findsNothing);
      expect(find.byKey(WindowControls.buttonKey), findsNWidgets(3));
      Color? fillOf(String tooltip) {
        final button = find.descendant(
          of: find.byTooltip(tooltip),
          matching: find.byKey(WindowControls.buttonKey),
        );
        final box = tester.widget<AnimatedContainer>(button).decoration;
        return (box! as BoxDecoration).color;
      }

      expect(fillOf('Close')!.a, 0, reason: 'no strip behind the buttons');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byTooltip('Close')));
      await tester.pumpAndSettle();
      expect(fillOf('Close'), const Color(0xFFC42B1C));
      expect(fillOf('Minimize')!.a, 0);

      await tester.tapAt(tester.getTopLeft(find.byTooltip('Maximize')));
      await tester.pump();
      expect(calls, contains('maximize'));
    });

    testWidgets('only the hovered dot lights up, then fades back', (
      tester,
    ) async {
      await pumpControls(tester);
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
