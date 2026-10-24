import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/app/shell/sidebar.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/liquid_glass.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/mini_players.dart';
import 'package:noir/features/queue/presentation/queue_panel.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';

import '../helpers/pump_app.dart';

Future<void> _play(TestApp app) async {
  final rows = await app.db.select(app.db.tracks).get();
  await app.container.read(playbackProvider.notifier).playTracks([
    for (final r in rows) r.toTrack(),
  ]);
}

Finder _inSidebar(String label) =>
    find.descendant(of: find.byType(Sidebar), matching: find.text(label));

Finder _inIsland(Finder matching) =>
    find.descendant(of: find.byType(PlayerIsland), matching: matching);

Rect _glassRect(WidgetTester tester) =>
    tester.getRect(_inIsland(find.byType(LiquidGlass)));

void main() {
  group('adaptive shell', () {
    testWidgets('wide desktop: sidebar, top search, no bottom nav', (
      tester,
    ) async {
      await TestApp.pump(tester);
      expect(tester.getSize(find.byType(Sidebar)).width, 248);
      expect(find.byType(BottomNav), findsNothing);
      expect(find.text('Search music, artists, albums…'), findsOneWidget);
    });

    testWidgets('medium window: icon rail without the expand toggle', (
      tester,
    ) async {
      await TestApp.pump(tester, size: const Size(900, 700));
      expect(tester.getSize(find.byType(Sidebar)).width, 80);
      expect(find.byTooltip('Expand sidebar'), findsNothing);
      expect(find.byTooltip('Settings'), findsOneWidget);
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

    testWidgets('collapsing the sidebar animates its width and persists', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      final sidebar = find.byType(Sidebar);
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final mid = tester.getSize(sidebar).width;
      expect(mid, greaterThan(80));
      expect(mid, lessThan(248));

      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 80);
      // Icons stay put: Home's icon is centered in the rail either way.
      expect(tester.getCenter(find.byIcon(Icons.home_rounded)).dx, 40);
      final saved = await SettingsRepository(app.db).loadSettings();
      expect(saved.sidebarCollapsed, isTrue);

      await tester.tap(find.byTooltip('Expand sidebar'));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 248);
      expect(tester.getCenter(find.byIcon(Icons.home_rounded)).dx, 40);
    });

    testWidgets('with animations off the sidebar collapses instantly', (
      tester,
    ) async {
      await TestApp.pump(
        tester,
        settings: const AppSettings(animations: false),
      );
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pump();
      expect(tester.getSize(find.byType(Sidebar)).width, 80);
    });
  });

  group('navigation', () {
    testWidgets('reaches every main screen', (tester) async {
      await TestApp.pump(tester);
      expect(find.text("Here's what's playing today."), findsOneWidget);

      await tester.tap(_inSidebar('Library'));
      await tester.pumpAndSettle();
      expect(find.text('Your Library'), findsOneWidget);

      await tester.tap(_inSidebar('Search'));
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

    testWidgets('branch switch fades through and keeps branch state', (
      tester,
    ) async {
      await TestApp.pump(tester);
      bool albumsSelected() => tester
          .widget<PillChip>(find.widgetWithText(PillChip, 'Albums'))
          .selected;

      await tester.tap(_inSidebar('Library'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();
      expect(albumsSelected(), isTrue);

      await tester.tap(_inSidebar('Search'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      // Mid-transition both pages are on stage.
      expect(find.text('Your Library'), findsOneWidget);
      expect(find.text('Search your music'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Your Library'), findsNothing);

      await tester.tap(_inSidebar('Library'));
      await tester.pumpAndSettle();
      expect(albumsSelected(), isTrue, reason: 'branch state survives');
    });

    testWidgets('with animations off branches switch instantly', (
      tester,
    ) async {
      await TestApp.pump(
        tester,
        settings: const AppSettings(animations: false),
      );
      await tester.tap(find.byTooltip('Settings & account'));
      await tester.pump();
      expect(find.text('Liquid Glass'), findsOneWidget);
      expect(find.text("Here's what's playing today."), findsNothing);
    });

    testWidgets('pushed pages fade in instead of sliding', (tester) async {
      final app = await TestApp.pump(tester);
      app.container.read(routerProvider).go('/library/favorites');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final opacities = tester
          .widgetList<Opacity>(
            find.ancestor(
              of: find.text('Favorites').last,
              matching: find.byType(Opacity),
            ),
          )
          .map((o) => o.opacity);
      expect(opacities.any((o) => o > 0 && o < 1), isTrue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('player island', () {
    testWidgets('slides in once playback starts, with full controls', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      expect(find.byTooltip('Open player (Ctrl+P)'), findsNothing);

      await _play(app);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final rising = tester.getTopLeft(_inIsland(find.text('Ash & Ember'))).dy;
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(_inIsland(find.text('Ash & Ember'))).dy,
        lessThan(rising),
      );

      for (final tooltip in [
        'Shuffle off',
        'Previous',
        'Pause',
        'Next',
        'Repeat off',
        'Queue',
        'Mute',
        'Open player (Ctrl+P)',
        'Add to favorites (this device)',
      ]) {
        expect(
          _inIsland(find.byTooltip(tooltip)),
          findsOneWidget,
          reason: tooltip,
        );
      }
      expect(_inIsland(find.text('Mara Vale')), findsOneWidget);
      expect(_inIsland(find.bySemanticsLabel('Volume')), findsOneWidget);

      // A floating capsule centered over the content, at most 900 px wide.
      final glass = _glassRect(tester);
      expect(glass.width, PlayerIsland.maxWidth);
      expect(glass.center.dx, 248 + (1360 - 248) / 2);
      expect(glass.bottom, 860 - 16);
      expect(_inSidebar('Ash & Ember'), findsNothing);
    });

    testWidgets('the capsule shrinks with the window', (tester) async {
      final app = await TestApp.pump(tester, size: const Size(900, 700));
      await _play(app);
      await tester.pumpAndSettle();
      final glass = _glassRect(tester);
      // Icon rail (80 px) + 16 px margins on both sides.
      expect(glass.left, 80 + 16);
      expect(glass.right, 900 - 16);
    });

    testWidgets('hovering the track reveals the times and thickens the line', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      await _play(app);
      await tester.pumpAndSettle();
      final line = _inIsland(find.byKey(PlayerIsland.progressKey));
      expect(tester.getSize(line).height, 2);
      expect(_inIsland(find.text('0:00')), findsNothing);
      expect(_inIsland(find.text('Mara Vale')), findsOneWidget);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(_inIsland(find.text('Ash & Ember'))));
      await tester.pumpAndSettle();
      expect(tester.getSize(line).height, 4);
      expect(_inIsland(find.text('0:00')), findsOneWidget);
      expect(_inIsland(find.text('-3:00')), findsOneWidget);
      expect(_inIsland(find.text('Mara Vale')), findsNothing);
      // The title stays readable, and still opens the player.
      expect(_inIsland(find.text('Ash & Ember')), findsOneWidget);

      await mouse.moveTo(const Offset(700, 300));
      await tester.pumpAndSettle();
      expect(tester.getSize(line).height, 2);
      expect(_inIsland(find.text('0:00')), findsNothing);
      expect(_inIsland(find.text('Mara Vale')), findsOneWidget);
    });

    testWidgets('clicking the progress line seeks; dragging scrubs', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      await _play(app);
      await tester.pumpAndSettle();
      final line = tester.getRect(
        _inIsland(find.byKey(PlayerIsland.progressKey)),
      );
      Offset at(double f) => Offset(line.left + line.width * f, line.center.dy);

      await tester.tapAt(at(0.5));
      await tester.pumpAndSettle();
      expect(app.engine.calls, contains('seek 90'));

      app.engine.calls.clear();
      final drag = await tester.startGesture(
        at(0.9),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(-30, 0));
      await drag.moveTo(at(0.5));
      await tester.pumpAndSettle();
      // The times follow the drag; nothing seeks until release.
      expect(_inIsland(find.text('1:30')), findsOneWidget);
      expect(_inIsland(find.text('-1:30')), findsOneWidget);
      expect(app.engine.calls.where((c) => c.startsWith('seek')), isEmpty);

      await drag.up();
      await tester.pumpAndSettle();
      expect(app.engine.calls.where((c) => c.startsWith('seek')), ['seek 90']);
    });

    testWidgets('hover leaves the capsule as it is', (tester) async {
      final app = await TestApp.pump(tester);
      await _play(app);
      await tester.pumpAndSettle();
      final glass = _glassRect(tester);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(glass.center);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_glassRect(tester), glass);
      await tester.pumpAndSettle();
      expect(_glassRect(tester), glass);
      // Nothing between the capsule and its content scales.
      expect(
        find.ancestor(
          of: find.byType(LiquidGlass),
          matching: find.byType(AnimatedScale),
        ),
        findsNothing,
      );
      for (final scale in tester.widgetList<AnimatedScale>(
        find.descendant(
          of: find.byType(LiquidGlass),
          matching: find.byType(AnimatedScale),
        ),
      )) {
        expect(scale.scale, 1);
      }
    });

    testWidgets('no dividers around the track block', (tester) async {
      final app = await TestApp.pump(tester);
      await _play(app);
      await tester.pumpAndSettle();
      // No vertical hairline: nothing painted 1 px wide and taller than a
      // few pixels anywhere in the capsule.
      final painted = find.descendant(
        of: find.byType(LiquidGlass),
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox || w is DecoratedBox,
        ),
      );
      expect(painted, findsWidgets);
      final hairlines = tester
          .renderObjectList<RenderBox>(painted)
          .where((b) => b.size.width <= 1 && b.size.height > 8);
      expect(hairlines, isEmpty);
    });

    testWidgets('Liquid Glass off: a solid capsule of the same geometry', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      await _play(app);
      await tester.pumpAndSettle();
      expect(_inIsland(find.byType(BackdropFilter)), findsOneWidget);
      final glass = _glassRect(tester);

      app.container
          .read(settingsProvider.notifier)
          .update((s) => s.copyWith(liquidGlass: false));
      await tester.pumpAndSettle();
      expect(_inIsland(find.byType(BackdropFilter)), findsNothing);
      expect(_glassRect(tester), glass);
      expect(_inIsland(find.byTooltip('Pause')), findsOneWidget);
    });

    testWidgets('pages get bottom padding to scroll clear of it', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      final home = find.text("Here's what's playing today.");
      expect(MediaQuery.paddingOf(tester.element(home)).bottom, 0);

      await _play(app);
      await tester.pumpAndSettle();
      final glass = _glassRect(tester);
      expect(
        MediaQuery.paddingOf(tester.element(home)).bottom,
        860 - glass.top,
      );
    });

    testWidgets('track info opens Now Playing', (tester) async {
      final app = await TestApp.pump(tester);
      await _play(app);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel(RegExp('^Now playing')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close player (Esc)'), findsOneWidget);
      // The queue opens as a side sheet; no inline card.
      expect(find.text('Up next'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close player (Esc)'), findsNothing);
    });

    testWidgets('queue button toggles the queue panel', (tester) async {
      final app = await TestApp.pump(tester);
      await _play(app);
      await tester.pumpAndSettle();
      expect(find.byType(QueuePanel), findsNothing);

      await tester.tap(find.byTooltip('Queue'));
      await tester.pumpAndSettle();
      expect(find.byType(QueuePanel), findsOneWidget);
      expect(app.container.read(queuePanelOpenProvider), isTrue);
      // The island now centers between the sidebar and the panel.
      final glass = _glassRect(tester);
      expect(glass.left, 248 + 16);
      expect(glass.right, 1360 - 360 - 16);

      await tester.tap(find.byTooltip('Hide queue'));
      await tester.pumpAndSettle();
      expect(find.byType(QueuePanel), findsNothing);
    });

    for (final (size, volume, modes) in const [
      (Size(1600, 1000), true, true),
      (Size(900, 700), false, true),
      (Size(700, 700), false, false),
    ]) {
      testWidgets('at ${size.width.toInt()} px it drops what does not fit', (
        tester,
      ) async {
        final app = await TestApp.pump(tester, size: size);
        await _play(app);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          _inIsland(find.bySemanticsLabel('Volume')),
          volume ? findsOneWidget : findsNothing,
        );
        for (final tooltip in ['Shuffle off', 'Repeat off']) {
          expect(
            _inIsland(find.byTooltip(tooltip)),
            modes ? findsOneWidget : findsNothing,
          );
        }
        expect(
          _inIsland(find.byTooltip('Add to favorites (this device)')),
          findsOneWidget,
        );
        expect(_inIsland(find.byTooltip('Mute')), findsOneWidget);
        expect(_inIsland(find.byTooltip('Next')), findsOneWidget);
      });
    }

    testWidgets('phones keep the mini player and bottom navigation', (
      tester,
    ) async {
      final app = await TestApp.pump(tester, size: const Size(400, 800));
      await _play(app);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(MobileMiniPlayer), findsOneWidget);
      expect(find.byType(PlayerIsland), findsNothing);
      expect(find.byType(BottomNav), findsOneWidget);
    });
  });

  group('effects and themes', () {
    testWidgets('Liquid Glass off removes every backdrop blur, live', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      await _play(app);
      await tester.pumpAndSettle();
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

    testWidgets('a settings toggle does not re-theme the whole app', (
      tester,
    ) async {
      await TestApp.pump(tester);
      await tester.tap(find.byTooltip('Settings & account'));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('Performance mode'));
      final before = Theme.of(context);
      await tester.tap(find.text('Performance mode'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // An unchanged theme must not start a 200 ms app-wide theme lerp,
      // which starved the switch animation of frames. AnimatedTheme only
      // lerps when the data differs (Theme.of may still hand back a fresh
      // localized copy, so identity is too strict).
      expect(Theme.of(context), before);
    });

    testWidgets('crossfade length slides in instead of popping', (
      tester,
    ) async {
      await TestApp.pump(tester);
      await tester.tap(find.byTooltip('Settings & account'));
      await tester.pumpAndSettle();
      expect(find.text('Crossfade length'), findsNothing);
      await tester.ensureVisible(find.text('Crossfade'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crossfade'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final reveal = find.ancestor(
        of: find.text('Crossfade length'),
        matching: find.byType(SizeTransition),
      );
      final mid = tester.getSize(reveal).height;
      await tester.pumpAndSettle();
      final full = tester.getSize(reveal).height;
      expect(mid, greaterThan(0));
      expect(mid, lessThan(full));
      expect(find.text('Crossfade length'), findsOneWidget);
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
      final app = await TestApp.pump(
        tester,
        settings: const AppSettings(
          performanceMode: PerformanceMode.performance,
        ),
      );
      await _play(app);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsWidgets);
    });
  });

  group('menus and toasts', () {
    testWidgets('track menu fades in, toast confirms the action', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      app.container.read(routerProvider).go('/library?tab=tracks');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final fade = tester.widget<GlassFade>(
        find
            .ancestor(
              of: find.text('Add to queue'),
              matching: find.byType(GlassFade),
            )
            .first,
      );
      expect(fade.opacity, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add to queue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Added to queue'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Added to queue'), findsNothing);
      expect(app.container.read(playbackProvider).queue, isNotEmpty);
    });
  });

  group('accessibility', () {
    for (final size in const [
      Size(400, 800),
      Size(900, 700),
      Size(1360, 860),
    ]) {
      testWidgets('200% text does not overflow at ${size.width}px', (
        tester,
      ) async {
        final app = await TestApp.pump(tester, size: size, textScale: 2);
        expect(tester.takeException(), isNull);
        // The rail shows icons with tooltips; elsewhere the label is visible.
        final rail = find.byTooltip('Library');
        await tester.tap(
          rail.evaluate().isNotEmpty ? rail : find.text('Library').first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _play(app);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('icon-only buttons have tooltips', (tester) async {
      final app = await TestApp.pump(tester);
      await _play(app);
      await tester.pumpAndSettle();
      for (final b in tester.widgetList<IconButton>(find.byType(IconButton))) {
        expect(b.tooltip, isNotNull, reason: '${b.icon} needs a tooltip');
      }
    });
  });
}
