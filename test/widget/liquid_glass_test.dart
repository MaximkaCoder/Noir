import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/app/shell/sidebar.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/liquid_glass.dart';
import 'package:noir/core/widgets/liquid_press.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/mini_players.dart';
import 'package:noir/features/playback/presentation/now_playing_route.dart';
import 'package:noir/features/playback/presentation/now_playing_screen.dart';
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

Future<TestApp> _playing(
  WidgetTester tester, {
  AppSettings settings = const AppSettings(),
  Size size = const Size(1360, 860),
}) async {
  final app = await TestApp.pump(tester, settings: settings, size: size);
  await _play(app);
  await tester.pumpAndSettle();
  return app;
}

Finder _inIsland(Finder matching) =>
    find.descendant(of: find.byType(PlayerIsland), matching: matching);

/// The [LiquidPress] around the island button with [tooltip].
Finder _press(String tooltip) => find.ancestor(
  of: _inIsland(find.byTooltip(tooltip)),
  matching: find.byType(LiquidPress),
);

double _scaleOf(WidgetTester tester, String tooltip) => tester
    .widget<Transform>(
      find.descendant(
        of: _press(tooltip),
        matching: find.byKey(LiquidPress.contentKey),
      ),
    )
    .transform
    .storage[0];

Finder _bubble(String tooltip) => find.descendant(
  of: _press(tooltip),
  matching: find.byKey(LiquidPress.bubbleKey),
);

LiquidGlassStyle _islandStyle(WidgetTester tester) => LiquidGlassStyle.of(
  NoirEffects.of(tester.element(_inIsland(find.byType(LiquidGlass)))),
);

Rect _islandRect(WidgetTester tester) =>
    tester.getRect(_inIsland(find.byType(LiquidGlass)));

double _islandOpacity(WidgetTester tester) {
  var opacity = 1.0;
  for (final o in tester.widgetList<Opacity>(
    find.ancestor(
      of: find.byType(LiquidGlass),
      matching: find.byType(Opacity),
    ),
  )) {
    opacity *= o.opacity;
  }
  return opacity;
}

/// The morphing shape Now Playing is clipped to.
Rect _morphRect(WidgetTester tester) =>
    (tester
                .widget<ClipRRect>(find.byKey(NowPlayingTransition.clipKey))
                .clipper!
            as NowPlayingClipper)
        .shape
        .outerRect;

Finder _glassSlider() => find.descendant(
  of: find.ancestor(of: find.text('Glass'), matching: find.byType(Row)).first,
  matching: find.byType(Slider),
);

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings & account'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Glass'));
  await tester.pumpAndSettle();
}

void main() {
  group('LiquidPress', () {
    testWidgets('squishes on press, springs back past rest on release', (
      tester,
    ) async {
      final app = await _playing(tester);
      expect(_scaleOf(tester, 'Next'), 1);
      expect(_bubble('Next'), findsNothing);

      final gesture = await tester.startGesture(
        tester.getCenter(_inIsland(find.byTooltip('Next'))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final early = _scaleOf(tester, 'Next');
      expect(early, lessThan(1));
      expect(early, greaterThan(0.9));
      expect(_bubble('Next'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 250));
      expect(_scaleOf(tester, 'Next'), closeTo(0.9, 0.005));

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final releasing = _scaleOf(tester, 'Next');
      expect(releasing, greaterThan(0.9));
      expect(releasing, lessThan(1));

      // A slight overshoot past 1, then rest.
      var peak = 0.0;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final s = _scaleOf(tester, 'Next');
        if (s > peak) peak = s;
      }
      expect(peak, greaterThan(1.005));
      expect(peak, lessThan(1.03));

      await tester.pumpAndSettle();
      expect(_scaleOf(tester, 'Next'), closeTo(1, 0.001));
      expect(_bubble('Next'), findsNothing);
      // The press reached the button.
      expect(
        app.container.read(playbackProvider).current?.track.title,
        'Quiet Harbor',
      );
    });

    testWidgets('play/pause answers too', (tester) async {
      await _playing(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(_inIsland(find.byTooltip('Pause'))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_scaleOf(tester, 'Pause'), lessThan(0.95));
      expect(_bubble('Pause'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_inIsland(find.byTooltip('Play')), findsOneWidget);
    });

    testWidgets('with animations off it switches instantly', (tester) async {
      await _playing(tester, settings: const AppSettings(animations: false));
      final gesture = await tester.startGesture(
        tester.getCenter(_inIsland(find.byTooltip('Next'))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(_scaleOf(tester, 'Next'), closeTo(0.9, 1e-9));
      await gesture.up();
      await tester.pump();
      expect(_scaleOf(tester, 'Next'), 1);
      expect(_bubble('Next'), findsNothing);
    });

    testWidgets('performance mode keeps only the squish', (tester) async {
      await _playing(
        tester,
        settings: const AppSettings(
          performanceMode: PerformanceMode.performance,
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(_inIsland(find.byTooltip('Next'))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_scaleOf(tester, 'Next'), lessThan(0.95));
      expect(_bubble('Next'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('buttons outside the island keep their usual feedback', (
      tester,
    ) async {
      await _playing(tester);
      expect(
        find.ancestor(
          of: find.descendant(
            of: find.byType(Sidebar),
            matching: find.byTooltip('Collapse sidebar'),
          ),
          matching: find.byType(LiquidPress),
        ),
        findsNothing,
      );
    });
  });

  group('Glass slider', () {
    testWidgets('drives the glass live and persists', (tester) async {
      final app = await _playing(tester);
      final before = _islandStyle(tester);
      expect(app.container.read(settingsProvider).glassLevel, 60);

      await _openSettings(tester);
      final slider = _glassSlider();
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);
      // All the way to clear glass.
      final track = tester.getRect(slider);
      await tester.tapAt(Offset(track.right - 4, track.center.dy));
      await tester.pumpAndSettle();

      final after = _islandStyle(tester);
      expect(after.tint, lessThan(before.tint));
      expect(after.blurSigma, lessThan(before.blurSigma));
      expect(after.saturation, greaterThan(before.saturation));
      expect(after.refraction, greaterThan(before.refraction));
      final level = (await SettingsRepository(app.db).loadSettings())
          .glassLevel;
      expect(level, greaterThan(90));

      // The capsule's surface itself turned clearer.
      final fill = tester
          .widget<ColoredBox>(
            find
                .descendant(
                  of: _inIsland(find.byType(LiquidGlass)),
                  matching: find.byType(ColoredBox),
                )
                .first,
          )
          .color;
      expect(fill.a, lessThan(0.2));
    });

    testWidgets('is disabled while Liquid Glass is off', (tester) async {
      await TestApp.pump(
        tester,
        settings: const AppSettings(liquidGlass: false),
      );
      await _openSettings(tester);
      expect(tester.widget<Slider>(_glassSlider()).onChanged, isNull);

      await tester.ensureVisible(find.text('Liquid Glass'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Liquid Glass'));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(_glassSlider()).onChanged, isNotNull);
    });

    test('maps the level onto every glass parameter', () {
      LiquidGlassStyle at(int level, {bool performance = false}) =>
          LiquidGlassStyle.of(
            EffectsConfig.resolve(
              AppSettings(
                glassLevel: level,
                performanceMode: performance
                    ? PerformanceMode.performance
                    : PerformanceMode.balanced,
              ),
              systemReducedMotion: false,
            ),
          );
      final frosted = at(0);
      final clear = at(100);
      expect(clear.tint, lessThan(frosted.tint));
      expect(clear.blurSigma, lessThan(frosted.blurSigma));
      expect(clear.saturation, greaterThan(frosted.saturation));
      expect(frosted.refraction, 0);
      expect(clear.refraction, 1);
      // Performance mode: blur only.
      expect(at(100, performance: true).refraction, 0);
      expect(at(100, performance: true).saturation, 1);
    });
  });

  group('Now Playing container transform', () {
    testWidgets('grows out of the island and shrinks back into it', (
      tester,
    ) async {
      await _playing(tester);
      final island = _islandRect(tester);
      const full = Rect.fromLTWH(0, 0, 1360, 860);

      await tester.tap(_inIsland(find.byTooltip('Open player (Ctrl+P)')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final opening = _morphRect(tester);
      expect(opening.width, greaterThan(island.width));
      expect(opening.width, lessThan(full.width));
      expect(opening.top, lessThan(island.top));
      expect(opening.top, greaterThan(0));
      expect(opening.bottom, greaterThanOrEqualTo(island.bottom));
      expect(_islandOpacity(tester), lessThan(1));

      await tester.pumpAndSettle();
      expect(_morphRect(tester), full);
      expect(find.byType(NowPlayingScreen), findsOneWidget);
      // Hidden behind the page: no double image.
      expect(_islandOpacity(tester), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final closing = _morphRect(tester);
      expect(closing.width, lessThan(full.width));
      expect(closing.width, greaterThan(island.width));
      expect(closing.top, greaterThan(0));

      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingScreen), findsNothing);
      expect(_islandOpacity(tester), 1);
      expect(_islandRect(tester), island);
    });

    testWidgets('the back button closes it the same way', (tester) async {
      final app = await _playing(tester);
      unawaited(app.container.read(routerProvider).push('/now-playing'));
      await tester.pumpAndSettle();
      unawaited(app.container.read(routerProvider).routerDelegate.popRoute());
      // The pop lands a frame later (it asks each navigator in turn).
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final closing = _morphRect(tester);
      expect(closing.width, lessThan(1360));
      expect(closing.width, greaterThan(_islandRect(tester).width));
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingScreen), findsNothing);
    });

    testWidgets('with animations off it opens and closes instantly', (
      tester,
    ) async {
      await _playing(tester, settings: const AppSettings(animations: false));
      await tester.tap(_inIsland(find.byTooltip('Open player (Ctrl+P)')));
      await tester.pump();
      await tester.pump();
      expect(_morphRect(tester), const Rect.fromLTWH(0, 0, 1360, 860));
      expect(_islandOpacity(tester), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(NowPlayingScreen), findsNothing);
      expect(_islandOpacity(tester), 1);
    });

    testWidgets('without an island it fades and scales from the bottom', (
      tester,
    ) async {
      final app = await _playing(tester, size: const Size(400, 800));
      expect(find.byType(PlayerIsland), findsNothing);
      unawaited(app.container.read(routerProvider).push('/now-playing'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(_morphRect(tester), const Rect.fromLTWH(0, 0, 400, 800));
      final fade = tester.widget<Opacity>(
        find
            .descendant(
              of: find.byKey(NowPlayingTransition.clipKey),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(fade.opacity, greaterThan(0));
      expect(fade.opacity, lessThan(1));
      final grow = tester.widget<Transform>(
        find
            .descendant(
              of: find.byKey(NowPlayingTransition.clipKey),
              matching: find.byType(Transform),
            )
            .first,
      );
      expect(grow.transform.storage[0], lessThan(1));
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingScreen), findsOneWidget);
    });
  });
}
