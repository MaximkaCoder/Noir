import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/app/shell/sidebar.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/liquid_glass.dart';
import 'package:noir/core/widgets/liquid_press.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/queue/presentation/queue_panel.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/widgets/track_row.dart';

import '../helpers/fake_innertube_client.dart';
import '../helpers/pump_app.dart';

/// The Liquid Glass material of the sidebar.
Finder get _sidebar => find
    .descendant(
      of: find.byType(Sidebar),
      matching: find.byType(LiquidGlassMaterial),
    )
    .first;

/// The Liquid Glass material of the open menu.
Finder get _menu => find
    .ancestor(
      of: find.text('Add to queue'),
      matching: find.byType(LiquidGlassMaterial),
    )
    .first;

/// The material's own surface color: its first filled box.
Color _surface(WidgetTester tester, Finder material) {
  final box = find
      .descendant(
        of: material,
        matching: find.byWidgetPredicate(
          (w) =>
              w is ColoredBox ||
              (w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).color != null),
        ),
      )
      .first;
  final w = tester.widget(box);
  return w is ColoredBox
      ? w.color
      : ((w as DecoratedBox).decoration as BoxDecoration).color!;
}

Finder _backdrops(Finder of) =>
    find.descendant(of: of, matching: find.byType(BackdropFilter));

String _blur(WidgetTester tester, Finder material) => tester
    .renderObject<RenderBackdropFilter>(_backdrops(material))
    .filterConfig
    .toString();

bool _refracts(WidgetTester tester, Finder material) =>
    LiquidGlassMaterial.debugRefracts(tester.element(material));

Future<void> _openMenu(WidgetTester tester, TestApp app) async {
  app.container.read(routerProvider).go('/library?tab=tracks');
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('More').first);
  await tester.pumpAndSettle();
}

Future<void> _closeMenu(WidgetTester tester) async {
  await Navigator.of(
    tester.element(find.text('Add to queue')),
    rootNavigator: true,
  ).maybePop();
  await tester.pumpAndSettle();
}

void _setGlass(TestApp app, int level) => app.container
    .read(settingsProvider.notifier)
    .update((s) => s.copyWith(glassLevel: level));

FakeInnerTubeClient _feed() => FakeInnerTubeClient()
  ..homePage = YtmHomePage(
    shelves: [
      YtmShelf(
        title: 'Quick picks',
        items: [
          for (var i = 0; i < 14; i++)
            YtmTrackItem(ytTrack('v$i', title: 'Song $i')),
        ],
      ),
    ],
  );

void main() {
  testWidgets('glass surfaces are the Liquid Glass material', (tester) async {
    final app = await TestApp.pump(tester);
    expect(_sidebar, findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PillButton),
        matching: find.byType(LiquidGlassMaterial),
      ),
      findsWidgets,
    );
    await _openMenu(tester, app);
    expect(_menu, findsOneWidget);
  });

  testWidgets('the Glass slider changes the sidebar and a menu live', (
    tester,
  ) async {
    final app = await TestApp.pump(tester);
    _setGlass(app, 0);
    await _openMenu(tester, app);
    final sidebarFrosted = _surface(tester, _sidebar);
    final menuFrosted = _surface(tester, _menu);
    final blurFrosted = _blur(tester, _menu);
    await _closeMenu(tester);

    _setGlass(app, 100);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    final sidebarClear = _surface(tester, _sidebar);
    final menuClear = _surface(tester, _menu);
    expect(sidebarClear, isNot(sidebarFrosted));
    expect(menuClear, isNot(menuFrosted));
    // Clearer: less of the dark surface color over what shows through.
    expect(
      sidebarClear.computeLuminance(),
      greaterThan(sidebarFrosted.computeLuminance()),
    );
    expect(_blur(tester, _menu), isNot(blurFrosted));
    // Text-heavy glass keeps a scrim: denser than the sidebar.
    expect(menuClear.a, greaterThan(sidebarClear.a));
  });

  testWidgets('Liquid Glass off: opaque surfaces, no backdrop', (tester) async {
    final app = await TestApp.pump(
      tester,
      settings: const AppSettings(liquidGlass: false),
    );
    expect(_surface(tester, _sidebar).a, 1);
    await _openMenu(tester, app);
    expect(_surface(tester, _menu).a, 1);
    expect(_backdrops(_menu), findsNothing);
    expect(_refracts(tester, _menu), isFalse);
  });

  testWidgets('floating glass refracts; Performance mode blurs only', (
    tester,
  ) async {
    final app = await TestApp.pump(tester);
    await _openMenu(tester, app);
    expect(_backdrops(_menu), findsOneWidget);
    expect(_refracts(tester, _menu), isTrue);
    await _closeMenu(tester);

    app.container
        .read(settingsProvider.notifier)
        .update(
          (s) => s.copyWith(performanceMode: PerformanceMode.performance),
        );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    expect(_backdrops(_menu), findsOneWidget);
    expect(_refracts(tester, _menu), isFalse);
  });

  testWidgets('no lens while the menu fades in', (tester) async {
    final app = await TestApp.pump(tester);
    app.container.read(routerProvider).go('/library?tab=tracks');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(_refracts(tester, _menu), isFalse);
    await tester.pumpAndSettle();
    expect(_refracts(tester, _menu), isTrue);
  });

  testWidgets('panels and canvas glass take no backdrop pass', (tester) async {
    final app = await TestApp.pump(tester);
    final rows = await app.db.select(app.db.tracks).get();
    await app.container.read(playbackProvider.notifier).playTracks([
      for (final r in rows) r.toTrack(),
    ]);
    app.container.read(queuePanelOpenProvider.notifier).toggle();
    await tester.pumpAndSettle();
    final queue = find.ancestor(
      of: find.text('Up next'),
      matching: find.byType(LiquidGlassMaterial),
    );
    final pill = find.descendant(
      of: find.byType(PillButton),
      matching: find.byType(LiquidGlassMaterial),
    );
    for (final material in [_sidebar, queue.first, pill.first]) {
      expect(_backdrops(material), findsNothing);
      expect(_refracts(tester, material), isFalse);
    }
  });

  testWidgets('large floating glass paints the lens band instead', (
    tester,
  ) async {
    await TestApp.pump(tester);
    final context = tester.element(find.byType(Sidebar));
    unawaited(
      showGlassDialog<void>(
        context,
        builder: (_) => const SizedBox(height: 520, child: Text('Tall')),
      ),
    );
    await tester.pumpAndSettle();
    final dialog = find
        .ancestor(
          of: find.text('Tall'),
          matching: find.byType(LiquidGlassMaterial),
        )
        .first;
    expect(_backdrops(dialog), findsOneWidget);
    expect(_refracts(tester, dialog), isFalse);
  });

  testWidgets('glass buttons answer presses with LiquidPress', (tester) async {
    final app = await TestApp.pump(tester, innerTube: _feed());
    Finder pressOf(Finder f) =>
        find.ancestor(of: f, matching: find.byType(LiquidPress));
    expect(pressOf(find.text('Create Playlist')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byTooltip('Settings & account'),
        matching: find.byType(LiquidPress),
      ),
      findsOneWidget,
    );

    // Shelf arrows appear on hover.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Song 2')));
    await tester.pumpAndSettle();
    expect(pressOf(find.byTooltip('Scroll right')), findsOneWidget);

    // Squishes on press.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Create Playlist')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final scale = tester
        .widget<Transform>(
          find.descendant(
            of: pressOf(find.text('Create Playlist')).first,
            matching: find.byKey(LiquidPress.contentKey),
          ),
        )
        .transform
        .storage[0];
    expect(scale, lessThan(1));
    // Cancelled, not tapped: no dialog in the way.
    await gesture.cancel();
    await tester.pumpAndSettle();

    // Menu items too; plain list rows never.
    await _openMenu(tester, app);
    expect(pressOf(find.text('Add to queue')), findsOneWidget);
    await _closeMenu(tester);
    expect(
      find.descendant(
        of: find.byType(TrackRow).first,
        matching: find.byType(LiquidPress),
      ),
      findsNothing,
    );
  });
}
