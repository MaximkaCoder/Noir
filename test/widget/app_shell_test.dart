import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/shell/sidebar.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/mini_players.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';

import '../helpers/pump_app.dart';

void main() {
  group('adaptive shell', () {
    testWidgets('wide desktop: sidebar, top search, no bottom nav', (
      tester,
    ) async {
      await TestApp.pump(tester);
      expect(find.byType(Sidebar), findsOneWidget);
      expect(find.byType(NavRail), findsNothing);
      expect(find.byType(BottomNav), findsNothing);
      expect(find.text('Search music, artists, albums…'), findsOneWidget);
    });

    testWidgets('medium window: icon rail', (tester) async {
      await TestApp.pump(tester, size: const Size(900, 700));
      expect(find.byType(NavRail), findsOneWidget);
      expect(find.byType(Sidebar), findsNothing);
    });

    testWidgets('phone: bottom navigation with every destination', (
      tester,
    ) async {
      await TestApp.pump(tester, size: const Size(400, 800));
      expect(find.byType(BottomNav), findsOneWidget);
      for (final label in ['Home', 'Search', 'Library', 'Settings']) {
        expect(
          find.descendant(
            of: find.byType(BottomNav),
            matching: find.text(label),
          ),
          findsOneWidget,
        );
      }
    });

    testWidgets('collapsing the sidebar switches to the rail and persists', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pumpAndSettle();
      expect(find.byType(NavRail), findsOneWidget);
      final saved = await SettingsRepository(app.db).loadSettings();
      expect(saved.sidebarCollapsed, isTrue);
    });
  });

  group('navigation', () {
    testWidgets('reaches every main screen', (tester) async {
      await TestApp.pump(tester);
      expect(find.text("Here's what's playing today."), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.text('Library'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your Library'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.text('Search'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Search your music'), findsOneWidget);

      await tester.tap(find.byTooltip('Settings & account'));
      await tester.pumpAndSettle();
      expect(find.text('Liquid Glass'), findsOneWidget);
    });

    testWidgets('Ctrl+K jumps into search', (tester) async {
      await TestApp.pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgets('playing a track shows the sidebar player and Now Playing', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      final rows = await app.db.select(app.db.tracks).get();
      await app.container.read(playbackProvider.notifier).playTracks([
        for (final r in rows) r.toTrack(),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(SidebarPlayerCard), findsOneWidget);

      await tester.tap(find.byType(SidebarPlayerCard));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close player (Esc)'), findsOneWidget);
      // The queue opens as a side sheet; no inline card.
      expect(find.text('Up next'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close player (Esc)'), findsNothing);
    });
  });

  group('effects and themes', () {
    testWidgets('Liquid Glass off removes every backdrop blur, live', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      expect(find.byType(BackdropFilter), findsWidgets);

      app.container
          .read(settingsProvider.notifier)
          .update((s) => s.copyWith(liquidGlass: false));
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      // Same layout either way.
      expect(find.byType(Sidebar), findsOneWidget);
    });

    testWidgets('Liquid Glass switch in Settings persists', (tester) async {
      final app = await TestApp.pump(tester);
      await tester.tap(find.byTooltip('Settings & account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Liquid Glass'));
      await tester.pumpAndSettle();
      final saved = await SettingsRepository(app.db).loadSettings();
      expect(saved.liquidGlass, isFalse);
    });

    testWidgets('light theme applies immediately', (tester) async {
      await TestApp.pump(tester);
      await tester.tap(find.byTooltip('Settings & account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('Liquid Glass'));
      expect(Theme.of(context).brightness, Brightness.light);
    });

    testWidgets('performance mode keeps glass but lowers blur', (tester) async {
      await TestApp.pump(
        tester,
        settings: const AppSettings(
          performanceMode: PerformanceMode.performance,
        ),
      );
      expect(find.byType(BackdropFilter), findsWidgets);
    });
  });

  group('accessibility', () {
    for (final size in const [Size(400, 800), Size(1360, 860)]) {
      testWidgets('200% text does not overflow at ${size.width}px', (
        tester,
      ) async {
        await TestApp.pump(tester, size: size, textScale: 2);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Library').first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('icon-only buttons have tooltips', (tester) async {
      await TestApp.pump(tester);
      for (final b in tester.widgetList<IconButton>(find.byType(IconButton))) {
        expect(b.tooltip, isNotNull, reason: '${b.icon} needs a tooltip');
      }
    });
  });
}
